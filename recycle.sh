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
#   RECYCLE_PRUNE_FILTER            — `docker container prune` filter
#                                     for orphan testcontainers.
#                                     Default `until=24h`. Set
#                                     "until=0" to skip prune; set
#                                     a shorter window for hosts
#                                     with disk pressure.
CONTAINER="${CONTAINER_NAME:-gha-runner}"
DRAIN_TIMEOUT_SECONDS="${RECYCLE_DRAIN_TIMEOUT_SECONDS:-600}"
DRAIN_POLL_SECONDS="${RECYCLE_DRAIN_POLL_SECONDS:-30}"
PRUNE_FILTER="${RECYCLE_PRUNE_FILTER:-until=24h}"

log() {
    echo "[recycle $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# Query the GitHub API for this runner's busy state. Returns 0 if
# idle, 1 if busy, 2 if the API call itself failed (caller decides
# how to handle).
runner_busy_state() {
    # `Authorization: Bearer <pat>` is passed via -H literal rather than
    # an Authorization=$VAR env so curl's child process env doesn't
    # carry the PAT. Same reason we sourced .env above without -a.
    local response
    response=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_PAT:-}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${GITHUB_OWNER:-}/${GITHUB_REPO:-}/actions/runners" 2>/dev/null) \
        || return 2
    local busy
    busy=$(echo "${response}" \
        | jq -r --arg name "${RUNNER_NAME:-}" '.runners[] | select(.name == $name) | .busy' 2>/dev/null)
    case "${busy}" in
        true)  return 1 ;;
        false) return 0 ;;
        *)     return 2 ;;  # runner not found, malformed response
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
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if runner_busy_state; then
            log "runner idle (per GH API); proceeding"
            return 0
        fi
        local api_rc=$?
        if [ "${api_rc}" -eq 2 ]; then
            log "GH API unreachable for busy-check; falling back to log scan"
            if runner_busy_state_via_log; then
                log "runner idle (per log fallback); proceeding"
                return 0
            fi
        fi
        log "runner busy; waiting ${DRAIN_POLL_SECONDS}s"
        sleep "${DRAIN_POLL_SECONDS}"
    done
    log "drain timeout reached after ${DRAIN_TIMEOUT_SECONDS}s; forcing recycle"
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
docker compose pull 2>&1 || log "pull failed; continuing with cached image"

log "compose up -d"
docker compose up -d

# Clear orphan testcontainers. With Ryuk disabled (see docker-compose
# environment block), a crashed test run can leave Postgres / Kafka
# / Trivy-scan sidecars behind. The default filter prunes containers
# stopped for >24h so an in-flight job on another runner instance
# isn't affected. Set RECYCLE_PRUNE_FILTER=until=0 in .env to skip.
if [ "${PRUNE_FILTER}" = "until=0" ]; then
    log "docker container prune skipped (RECYCLE_PRUNE_FILTER=until=0)"
else
    log "docker container prune --filter ${PRUNE_FILTER}"
    docker container prune -f --filter "${PRUNE_FILTER}" 2>&1 || log "container prune failed; continuing"
fi

log "recycle complete"
