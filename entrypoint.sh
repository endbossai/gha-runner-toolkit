#!/usr/bin/env bash
# gha-runner-toolkit entrypoint.
#
# Per-start dance:
#   1. Mint a fresh registration token from the GitHub API using the
#      long-lived PAT in $GITHUB_PAT.
#   2. Run ./config.sh to register the runner.
#   3. Stash the PAT in a 0400 file readable only by us, then UNSET
#      the env var so workflow steps inheriting the agent's env can't
#      read it (and so it's not in /proc/<pid>/environ).
#   4. exec ./run.sh. SIGTERM trap re-reads the stashed PAT to mint a
#      removal token for clean deregister on `docker stop`.

set -euo pipefail

: "${GITHUB_PAT:?GITHUB_PAT must be set (classic PAT with 'repo' scope, or fine-grained with 'Administration: write')}"
: "${GITHUB_OWNER:?GITHUB_OWNER must be set (e.g. your-org)}"
: "${GITHUB_REPO:?GITHUB_REPO must be set (e.g. your-repo)}"
: "${RUNNER_NAME:?RUNNER_NAME must be set (e.g. vps-1)}"
: "${RUNNER_LABELS:?RUNNER_LABELS must be set (e.g. self-hosted-pool)}"

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
