#!/usr/bin/env bash
# gha-runner-toolkit entrypoint.
#
# Two-phase boot:
#
#   Phase 1 (root) — runs only when EUID is 0:
#     - Auto-detect the host docker socket's GID by stat'ing the
#       bind-mounted /var/run/docker.sock. Fallback to DOCKER_GID
#       from .env with a warning if detection fails.
#     - Populate RUNNER_HOME (tmpfs at runtime) from RUNNER_DIST
#       (image-baked, immutable). chown to the runner user.
#     - setpriv re-exec into Phase 2 as `runner`, with the detected
#       docker GID added to the supplementary group set. This is
#       what gives workflow steps inside the container permission
#       to talk to the mounted docker socket.
#
#   Phase 2 (runner) — runs only when EUID is NOT 0:
#     - Mint a fresh registration token from the GitHub API using
#       the long-lived PAT in $GITHUB_PAT.
#     - Run ./config.sh to register the runner.
#     - Stash the PAT in a 0400 file readable only by us, then UNSET
#       the env var so workflow steps inheriting the agent's env
#       can't read it (and it's not in /proc/<pid>/environ).
#     - exec ./run.sh. SIGTERM trap re-reads the stashed PAT to mint
#       a removal token for clean deregister on `docker stop`.
#
# The two phases share this file: the EUID check at the top picks
# the right one. Phase 1 setpriv re-exec passes the same script,
# preserving the entire env (-PROOT), so secrets in $GITHUB_PAT etc
# survive the drop. Without `--preserve-environment`, setpriv strips
# the env by default.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# Phase 1 — root
# ─────────────────────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
    RUNNER_HOME="${RUNNER_HOME:-/runner}"
    RUNNER_DIST="${RUNNER_DIST:-/opt/runner-dist}"
    DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"

    log_root() { echo "[entrypoint:root] $*"; }

    # Auto-detect docker socket GID. `stat -c %g` returns the numeric
    # GID even when no matching group name exists inside the container
    # — important, because the host's docker group typically isn't
    # mirrored in /etc/group inside the runner image.
    detected_gid=""
    if [ -S "${DOCKER_SOCKET}" ]; then
        detected_gid=$(stat -c '%g' "${DOCKER_SOCKET}" 2>/dev/null || true)
    fi

    # Validate: must be a non-empty positive integer.
    if [[ "${detected_gid}" =~ ^[0-9]+$ ]]; then
        DOCKER_GID="${detected_gid}"
        log_root "auto-detected docker socket GID: ${DOCKER_GID}"
    else
        # Fallback to operator-supplied value with a clear warning.
        # Empty fallback is allowed for the no-docker-socket case —
        # workflows that don't need docker still work.
        if [ -n "${DOCKER_GID:-}" ]; then
            log_root "WARN: could not auto-detect docker socket GID (socket not found or stat failed); falling back to DOCKER_GID=${DOCKER_GID} from env"
        else
            log_root "WARN: docker socket not present and no DOCKER_GID set; docker CLI in workflows will fail"
            DOCKER_GID=""
        fi
    fi

    # Populate RUNNER_HOME from the image-baked dist. /runner is a
    # tmpfs at runtime (compose mount), starts empty on every container
    # start, so we need a fresh copy each boot.
    #
    # `--preserve=mode,timestamps,links` (NOT `-a` / NOT `--preserve=all`):
    # we deliberately do NOT preserve ownership during the copy, then
    # chown -R as a separate single pass at the end. Reason: `cp -a`
    # chowns each destination file to runner:runner inline as it's
    # written, which means subsequent chmod calls (for mode preservation)
    # happen on files no longer owned by EUID 0. Without CAP_FOWNER
    # (dropped under cap_drop: ALL), that chmod fails with EPERM. Doing
    # chown in a separate trailing step avoids the problem: every cp
    # operation runs on root-owned destinations (which root can chmod
    # freely), and the chown -R only needs CAP_CHOWN (which we keep).
    #
    # `.` source-suffix copies the *contents* of RUNNER_DIST rather
    # than the dir itself.
    log_root "populating ${RUNNER_HOME} from ${RUNNER_DIST}"
    cp -R --preserve=mode,timestamps,links "${RUNNER_DIST}/." "${RUNNER_HOME}/"
    chown -R runner:runner "${RUNNER_HOME}"

    # Build the supplementary group list for the runner user. The
    # runner's primary group is gid 1001 (matches the uid from the
    # Dockerfile useradd). We add the docker GID on top if detected.
    runner_gid=$(id -g runner)
    if [ -n "${DOCKER_GID}" ] && [ "${DOCKER_GID}" != "${runner_gid}" ]; then
        groups_arg="${runner_gid},${DOCKER_GID}"
    else
        groups_arg="${runner_gid}"
    fi

    log_root "dropping privileges to runner (uid=$(id -u runner), groups=${groups_arg})"

    # `setpriv --reuid=runner --regid=runner --groups=...` performs a
    # clean credential drop: changes ruid/euid/suid, rgid/egid/sgid,
    # and the supplementary group set in one call. It does NOT clear
    # capabilities by itself, but the compose-level cap_drop: ALL +
    # cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE] handles that —
    # at this point the container only has those four caps anyway.
    #
    # --preserve-environment: keep GITHUB_PAT, GITHUB_OWNER,
    # GITHUB_REPO, RUNNER_NAME, RUNNER_LABELS etc. through the re-exec.
    exec setpriv \
        --reuid=runner \
        --regid=runner \
        --groups="${groups_arg}" \
        --inh-caps=-all \
        -- \
        /bin/bash "$0" "$@"
fi

# ─────────────────────────────────────────────────────────────────
# Phase 2 — runner user
# ─────────────────────────────────────────────────────────────────

: "${GITHUB_PAT:?GITHUB_PAT must be set (classic PAT with 'repo' scope, or fine-grained with 'Administration: write')}"
: "${GITHUB_OWNER:?GITHUB_OWNER must be set (e.g. your-org)}"
: "${GITHUB_REPO:?GITHUB_REPO must be set (e.g. your-repo)}"
: "${RUNNER_NAME:?RUNNER_NAME must be set (e.g. vps-1)}"
: "${RUNNER_LABELS:?RUNNER_LABELS must be set (e.g. self-hosted-pool)}"

# setpriv preserves env but NOT HOME (it doesn't inherit from runner's
# /etc/passwd entry unless we ask it to). Make sure HOME points at
# RUNNER_HOME so PAT_FILE lands in the writable tmpfs.
export HOME="${RUNNER_HOME:-/runner}"
cd "${HOME}"

REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
API_BASE="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners"

# Stash the PAT in a file the agent's child processes can't read.
# The runner user (UID 1001) is the only one in the container who
# can read /runner; locking the file to 0400 is belt + braces.
#
# rm -f before write so a stale PAT from a previous crashed boot
# doesn't survive a credential rotation (operator updated .env →
# new value wins).
PAT_FILE="${HOME}/.pat"
rm -f "${PAT_FILE}"
umask 077
printf '%s' "${GITHUB_PAT}" > "${PAT_FILE}"
chmod 0400 "${PAT_FILE}"

echo "[entrypoint] minting registration token for ${REPO_URL}"
REG_TOKEN=$(curl -fsSL \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_BASE}/registration-token" \
    | jq -r .token)

if [ -z "${REG_TOKEN}" ] || [ "${REG_TOKEN}" = "null" ]; then
    echo "[entrypoint] FATAL: failed to mint registration token (verify PAT scopes: classic 'repo', fine-grained 'Administration: write')" >&2
    exit 1
fi

# --replace handles re-registration after a recycle.
# --disableupdate freezes the runner agent to the version we baked
# in; upgrades happen via Dockerfile bump + image rebuild, not at
# runtime. (Supply-chain hygiene; trade-off accepted in README.)
echo "[entrypoint] registering runner ${RUNNER_NAME} (labels: ${RUNNER_LABELS})"
./config.sh \
    --unattended \
    --replace \
    --disableupdate \
    --url "${REPO_URL}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work _work

# Drop the registration token + PAT from the shell's env. The trap
# re-reads the PAT from PAT_FILE when needed.
unset REG_TOKEN GITHUB_PAT

deregister() {
    echo "[entrypoint] deregistering runner ${RUNNER_NAME}"
    local pat
    pat=$(cat "${PAT_FILE}" 2>/dev/null || true)
    if [ -z "${pat}" ]; then
        echo "[entrypoint] WARN: PAT file gone; runner will show as offline in GH UI until manually removed" >&2
        return 0
    fi
    local REMOVE_TOKEN
    REMOVE_TOKEN=$(curl -fsSL \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${pat}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API_BASE}/remove-token" \
        | jq -r .token) || true
    if [ -n "${REMOVE_TOKEN:-}" ] && [ "${REMOVE_TOKEN}" != "null" ]; then
        ./config.sh remove --token "${REMOVE_TOKEN}" || true
    fi
}
trap deregister SIGTERM SIGINT

echo "[entrypoint] starting runner agent"
./run.sh &
RUNNER_PID=$!

# `wait` is interruptible by signal traps in bash 5.x (Ubuntu 24.04
# ships 5.2). The trap above fires, deregisters cleanly, then wait
# returns and entrypoint exits.
wait "${RUNNER_PID}"
