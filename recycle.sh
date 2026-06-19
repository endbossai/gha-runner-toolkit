#!/usr/bin/env bash
# Daily container recycle for the gha-runner-toolkit runner.
#
# Drain detection uses the GitHub API as the canonical signal:
#   GET /repos/{owner}/{repo}/actions/runners → find this runner →
#   read `busy: true|false`. Unforgeable from inside the workload
#   (a malicious workflow can't print "idle" to its own stdout and
#   trick us). Log grep is kept ONLY as a fallback if the API call
#   itself fails (offline, GH API outage, rate-limited, etc.).
#
# Steps:
#   1. Wait for the runner to be idle (≤10 min) per the GitHub API.
#   2. `docker compose down` — SIGTERM, entrypoint trap deregisters.
#   3. `docker compose pull` — fetch the pinned image's latest manifest
#      (in case the tag floats, e.g. you used `latest` or a SHA-pinned
#      moved). For a fully version-pinned `image: ...:1.0.0` this is
#      a no-op, which is fine.
#   4. `docker compose up -d` — new container, fresh registration.
#
# Intended to be invoked by recycle.timer (systemd) at 03:00 UTC.

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "${COMPOSE_DIR}"

# Source .env to get the PAT + repo coords + any optional knobs.
# recycle.sh is invoked by systemd outside any container, so it
# needs its own copy of the credentials. .env is gitignored and
# lives next to this script.
#
# Read into local-only vars (no `set -a` / no `export`) so the PAT
# doesn't propagate into curl/jq/docker child processes' env, and a
# `ps eww`-style host-side process-tree dump doesn't capture it.
if [ -f "${COMPOSE_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    . "${COMPOSE_DIR}/.env"
fi

# Tunables — env override (typically via .env), with sensible
# defaults. Any of these can stay unset and you get reasonable
# behaviour for the small-team / single-VPS case.
#
#   CONTAINER_NAME                  — must match docker-compose.yml's
#                                     container_name. Defaults to
#                                     `gha-runner`. Override when
#                                     running multiple instances on
#                                     one host.
#   RECYCLE_DRAIN_TIMEOUT_SECONDS   — hard ceiling on how long we
#                                     wait for an in-flight job to
#                                     finish before forcing recycle.
#                                     Default 600 (10 min). Bump if
#                                     your jobs routinely run longer
#                                     than that and you'd rather wait
#                                     than kill them.
#   RECYCLE_DRAIN_POLL_SECONDS      — how often we re-query the
#                                     GitHub API for busy-state.
#                                     Default 30s. Tighten only if
#                                     you have very short jobs.
#   RECYCLE_PRUNE_FILTER            — age window for the post-recycle
#                                     reclaim pass (containers, orphan
#                                     networks, dangling images).
#                                     Default `until=24h`. Set
#                                     "until=0" to skip reclaim
#                                     entirely; set a shorter window
#                                     for hosts with disk pressure.
#   RECYCLE_REAP_TESTCONTAINERS     — whether to stop+remove RUNNING
#                                     orphan Testcontainers sidecars
#                                     (Postgres/Kafka/etc.) left behind
#                                     by crashed test runs. Default
#                                     `true`. Only targets containers
#                                     carrying the `org.testcontainers`
#                                     label, and only those older than
#                                     the PRUNE_FILTER window, so a
#                                     concurrent runner's in-flight job
#                                     is never killed. Set "false" if
#                                     you run non-runner Testcontainers
#                                     workloads on the same host.
CONTAINER="${CONTAINER_NAME:-gha-runner}"
DRAIN_TIMEOUT_SECONDS="${RECYCLE_DRAIN_TIMEOUT_SECONDS:-600}"
DRAIN_POLL_SECONDS="${RECYCLE_DRAIN_POLL_SECONDS:-30}"
PRUNE_FILTER="${RECYCLE_PRUNE_FILTER:-until=24h}"
REAP_TESTCONTAINERS="${RECYCLE_REAP_TESTCONTAINERS:-true}"
NOTIFY_WEBHOOK="${RECYCLE_NOTIFY_WEBHOOK:-}"

# Retry budget for transient GitHub API failures during the drain
# loop. Each busy-check that returns "API error" counts against
# this; once exhausted we stop trusting the API for the rest of
# this recycle and switch to log-grep fallback.
API_MAX_FAILURES="${RECYCLE_API_MAX_FAILURES:-3}"

# Resolve the busy-check API endpoint based on RUNNER_SCOPE. Must
# match the scope used by entrypoint.sh — recycle.sh queries the
# same `actions/runners` collection that the agent registered into.
# Default `repo` keeps behaviour identical for pre-RUNNER_SCOPE
# .env files.
RUNNER_SCOPE="${RUNNER_SCOPE:-repo}"
case "${RUNNER_SCOPE}" in
    repo)
        RUNNERS_API="https://api.github.com/repos/${GITHUB_OWNER:-}/${GITHUB_REPO:-}/actions/runners" ;;
    org)
        RUNNERS_API="https://api.github.com/orgs/${GITHUB_OWNER:-}/actions/runners" ;;
    enterprise)
        RUNNERS_API="https://api.github.com/enterprises/${GITHUB_ENTERPRISE:-}/actions/runners" ;;
    *)
        echo "[recycle $(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: invalid RUNNER_SCOPE='${RUNNER_SCOPE}' (must be one of: repo, org, enterprise)" >&2
        exit 1 ;;
esac

log() {
    echo "[recycle $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# Severity-prefixed log lines so journalctl / log aggregators can
# filter on "warning" or "error". structured logs > free-text.
log_warn()  { log "WARN: $*";  }
log_error() { log "ERROR: $*"; }

# Convert a `docker prune` until-duration (e.g. `24h`, `30m`, `7d`, a
# bare `0`) into seconds. Echoes the seconds on success; echoes nothing
# and returns 1 on a value we don't understand (caller falls back to a
# conservative default rather than reaping something in-flight).
duration_to_seconds() {
    local spec="$1" num unit
    num="${spec%[smhd]}"
    unit="${spec##*[0-9]}"
    [[ "${num}" =~ ^[0-9]+$ ]] || { return 1; }
    case "${unit}" in
        ""|s) echo "${num}" ;;
        m)    echo "$(( num * 60 ))" ;;
        h)    echo "$(( num * 3600 ))" ;;
        d)    echo "$(( num * 86400 ))" ;;
        *)    return 1 ;;
    esac
}

# Stop + remove RUNNING orphan Testcontainers sidecars.
#
# Why this exists: docker-compose disables Testcontainers Ryuk (its
# watchdog) because Ryuk's host→container TCP probe can't reach a test
# process living inside our runner container. The documented trade-off
# is that a crashed test run leaves its sidecars (Postgres, Kafka, …)
# behind. `docker container prune` only reaps *stopped* containers, so
# those still-RUNNING orphans survive every recycle — holding host
# memory, ports, and network connections until the box is rebooted.
# That accumulation is the "connections + memory build up over time"
# symptom this function fixes.
#
# Safety: we match ONLY the standard `org.testcontainers=true` label
# (so the runner itself and unrelated host workloads are never touched)
# AND only containers older than the reclaim window (so a sibling
# runner's in-flight test job — whose sidecars are younger than the
# window — is left alone, mirroring the container-prune contract).
#   $1 — age threshold in seconds; containers created before
#        (now - threshold) are reaped.
reap_orphan_testcontainers() {
    local age_seconds="$1"
    local now cutoff id created created_epoch reaped=0
    now=$(date +%s)
    cutoff=$(( now - age_seconds ))
    while IFS= read -r id; do
        [ -n "${id}" ] || continue
        created=$(docker inspect -f '{{.Created}}' "${id}" 2>/dev/null) || continue
        created_epoch=$(date -d "${created}" +%s 2>/dev/null) || continue
        if [ "${created_epoch}" -lt "${cutoff}" ]; then
            log "reaping orphan testcontainer ${id} (running, older than reclaim window)"
            docker stop "${id}" >/dev/null 2>&1 || log_warn "stop ${id} failed"
            docker rm -f "${id}" >/dev/null 2>&1 || log_warn "rm ${id} failed"
            reaped=$(( reaped + 1 ))
        fi
    done < <(docker ps -q --filter "label=org.testcontainers=true" 2>/dev/null)
    log "reaped ${reaped} running orphan testcontainer(s)"
}

# Notify a webhook (Slack/Discord/Teams/anything-JSON). Best-effort:
# a failed webhook does NOT abort the recycle. The body is a small
# structured payload — operators wire it into whatever escalation
# channel they want.
#
#   $1 — event slug (e.g. "drain_timeout", "recycle_failed")
#   $2 — human-readable summary
notify() {
    local event="$1"
    local summary="$2"
    if [ -z "${NOTIFY_WEBHOOK}" ]; then
        return 0
    fi
    local payload
    payload=$(jq -nc \
        --arg event "${event}" \
        --arg summary "${summary}" \
        --arg runner "${RUNNER_NAME:-unknown}" \
        --arg repo "${GITHUB_OWNER:-unknown}/${GITHUB_REPO:-unknown}" \
        --arg container "${CONTAINER}" \
        --argjson timeout "${DRAIN_TIMEOUT_SECONDS}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event: $event, summary: $summary, runner: $runner, repo: $repo, container: $container, timeout_seconds: $timeout, timestamp: $ts}') \
        || { log_warn "notify: failed to assemble JSON payload"; return 0; }
    # 5s connect timeout, 10s total. We don't want a hung webhook to
    # delay the recycle further. -f makes curl exit non-zero on 4xx/5xx.
    if ! curl -fsS \
            --connect-timeout 5 \
            --max-time 10 \
            -X POST \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${NOTIFY_WEBHOOK}" >/dev/null 2>&1; then
        log_warn "notify: webhook POST failed (event=${event})"
    fi
}

# Query the GitHub API for this runner's busy state. Returns 0 if
# idle, 1 if busy, 2 if the API call itself failed (caller decides
# how to handle).
#
# Error handling discipline:
#   - HTTP status is captured separately from the body so we can
#     classify the failure (401 PAT bad, 403 rate-limited, 5xx
#     transient, anything else).
#   - We log the *kind* of failure but never the body (the response
#     can include runner metadata that's noise in the log).
#   - PAT bad (401) is a hard failure to log loudly — the rest of
#     the drain is going to keep falling back to log-grep silently
#     unless an operator notices.
runner_busy_state() {
    local response status body
    # `Authorization: Bearer <pat>` is passed via -H literal rather than
    # an Authorization=$VAR env so curl's child process env doesn't
    # carry the PAT. Same reason we sourced .env above without -a.
    #
    # -w writes the HTTP status to stdout AFTER the body; -o sends
    # the body to stdout normally. We split them with a sentinel.
    response=$(curl -sS \
        --connect-timeout 5 \
        --max-time 15 \
        -w '\n%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_PAT:-}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${RUNNERS_API}" 2>/dev/null) \
        || { log_warn "GH API: curl failed (network/timeout)"; return 2; }
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    case "${status}" in
        200)
            ;;
        401)
            log_error "GH API: 401 unauthorized — PAT invalid or expired"
            return 2 ;;
        403)
            log_warn  "GH API: 403 — likely rate-limited or PAT scopes insufficient"
            return 2 ;;
        404)
            log_error "GH API: 404 — registration target not found or PAT can't see it (scope=${RUNNER_SCOPE}, url=${RUNNERS_API})"
            return 2 ;;
        5*)
            log_warn  "GH API: ${status} server error (transient)"
            return 2 ;;
        *)
            log_warn  "GH API: unexpected status ${status}"
            return 2 ;;
    esac
    local busy
    busy=$(echo "${body}" \
        | jq -r --arg name "${RUNNER_NAME:-}" '.runners[] | select(.name == $name) | .busy' 2>/dev/null)
    case "${busy}" in
        true)  return 1 ;;
        false) return 0 ;;
        *)
            log_warn "GH API: runner '${RUNNER_NAME:-}' not in response (race with re-registration?)"
            return 2 ;;
    esac
}

# Fallback: agent log scan. Less reliable (the runner's log format
# isn't a stable contract and a workflow can write to its own stdout)
# but better than nothing if the API is unreachable.
runner_busy_state_via_log() {
    local last_state
    last_state=$(docker logs --tail 50 "${CONTAINER}" 2>&1 \
        | grep -oE 'Running job:|Job .* completed|Listening for Jobs' \
        | tail -1 || true)
    case "${last_state}" in
        "Running job:") return 1 ;;
        *)              return 0 ;;
    esac
}

wait_for_idle() {
    local deadline=$(( $(date +%s) + DRAIN_TIMEOUT_SECONDS ))
    local api_failures=0
    local trust_api=1
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if [ "${trust_api}" -eq 1 ]; then
            if runner_busy_state; then
                log "runner idle (per GH API); proceeding"
                return 0
            fi
            local api_rc=$?
            if [ "${api_rc}" -eq 2 ]; then
                api_failures=$(( api_failures + 1 ))
                if [ "${api_failures}" -ge "${API_MAX_FAILURES}" ]; then
                    log_warn "GH API failed ${api_failures} times; giving up on API for this drain, using log fallback"
                    trust_api=0
                fi
            fi
        fi
        if [ "${trust_api}" -eq 0 ]; then
            if runner_busy_state_via_log; then
                log "runner idle (per log fallback); proceeding"
                return 0
            fi
        fi
        log "runner busy; waiting ${DRAIN_POLL_SECONDS}s"
        sleep "${DRAIN_POLL_SECONDS}"
    done
    # Drain budget exhausted — log it loudly + notify any webhook
    # so operators can correlate this with workflow runs that died.
    # The recycle still proceeds (better to force-stop one job than
    # leave the runner stuck holding the lock for everyone else).
    log_warn "drain timeout reached after ${DRAIN_TIMEOUT_SECONDS}s; forcing recycle (in-flight job will be terminated)"
    notify "drain_timeout" "runner ${RUNNER_NAME:-?} still busy after ${DRAIN_TIMEOUT_SECONDS}s; recycle forced"
    return 0
}

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    log "container ${CONTAINER} not running; skipping drain"
else
    wait_for_idle
fi

log "compose down"
docker compose down --remove-orphans

log "compose pull (refresh image)"
docker compose pull 2>&1 || log_warn "pull failed; continuing with cached image"

log "compose up -d"
if ! docker compose up -d; then
    log_error "compose up failed; runner is DOWN"
    notify "recycle_failed" "compose up failed for ${CONTAINER} on $(hostname); runner is offline"
    exit 1
fi

# Reclaim what a day of CI leaks. With Ryuk disabled (see docker-compose
# environment block), a crashed test run leaves Postgres / Kafka /
# Trivy-scan sidecars — plus their networks, anonymous volumes, and the
# dangling images the daily `compose pull` sheds — orphaned on the host.
# Left alone these accumulate across recycles into the "connections +
# memory + cache keep growing" failure mode. This pass clears all of it,
# scoped to the same age window so an in-flight job on another runner
# instance isn't affected. Set RECYCLE_PRUNE_FILTER=until=0 to skip.
if [ "${PRUNE_FILTER}" = "until=0" ]; then
    log "reclaim skipped (RECYCLE_PRUNE_FILTER=until=0)"
else
    # Reap RUNNING orphan testcontainers first — `container prune` below
    # only touches stopped ones, so without this their sidecars survive
    # forever. Derive the age threshold from PRUNE_FILTER's until=<dur>;
    # fall back to 24h if it's malformed so we never reap aggressively.
    if [ "${REAP_TESTCONTAINERS}" = "true" ]; then
        reap_age=$(duration_to_seconds "${PRUNE_FILTER#until=}") \
            || { log_warn "could not parse PRUNE_FILTER='${PRUNE_FILTER}'; using 24h window for testcontainer reap"; reap_age=86400; }
        reap_orphan_testcontainers "${reap_age}"
    else
        log "testcontainer reap skipped (RECYCLE_REAP_TESTCONTAINERS=${REAP_TESTCONTAINERS})"
    fi

    log "docker container prune --filter ${PRUNE_FILTER}"
    docker container prune -f --filter "${PRUNE_FILTER}" 2>&1 \
        || log_warn "container prune failed; continuing"

    # Orphan networks left by removed testcontainers sessions — these are
    # the lingering "connections". `network prune` honours the until filter.
    log "docker network prune --filter ${PRUNE_FILTER}"
    docker network prune -f --filter "${PRUNE_FILTER}" 2>&1 \
        || log_warn "network prune failed; continuing"

    # Dangling images shed by the daily `compose pull` (old layers of the
    # floating tag). until-filtered so a just-pulled image isn't removed.
    log "docker image prune --filter ${PRUNE_FILTER}"
    docker image prune -f --filter "${PRUNE_FILTER}" 2>&1 \
        || log_warn "image prune failed; continuing"

    # Anonymous volumes from reaped sidecars. `volume prune` skips any
    # volume still attached to a live container, so a concurrent runner's
    # in-use data is safe; only genuinely-orphaned anonymous volumes go.
    log "docker volume prune (anonymous, unused)"
    docker volume prune -f 2>&1 \
        || log_warn "volume prune failed; continuing"
fi

log "recycle complete"
