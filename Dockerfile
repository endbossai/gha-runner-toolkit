# Self-hosted GitHub Actions runner image.
#
# Built from a pinned Ubuntu LTS base; bakes in the toolchain typical
# CI jobs need (Docker CLI for testcontainers + docker-publish-style
# workflows, Node ≥ 20 for npm-shaped tooling, plus the usual git/
# curl/jq suspects). JDK is intentionally NOT baked — let
# `actions/setup-java` handle version selection in the workflow.
# It caches the downloaded JDK inside the container, which survives
# until the next daily recycle (~24h), so first build of the day
# pays ~30s for the JDK fetch and every subsequent build hits the
# cache.
#
# Daily-recycle posture: caches (Gradle, Maven, Docker layers) live
# inside the container and die with it; bounded growth, OS-patch
# cadence via `docker compose build --pull` on recycle.
#
# Pin discipline: runner version + SHA256 are ARGs at the top of
# the file so a Dependabot-style bumper or a human reading the
# file can see and verify every supply-chain entry. The base
# image is also pinned by digest below; when you bump it, replace
# the digest with the current published one from Docker Hub.

# ubuntu:26.04 LTS. Pinned by digest for reproducibility.
# To bump:
#   docker pull ubuntu:26.04
#   docker inspect ubuntu:26.04 --format='{{index .RepoDigests 0}}'
FROM ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64

# actions/runner pinned to a specific release. To bump:
#   1. Pick the desired version from https://github.com/actions/runner/releases
#   2. Find the linux-x64 SHA256 in the release notes (look for
#      "BEGIN SHA linux-x64" comment markers)
#   3. Update both ARGs below
#
# GitHub deprecates old agent versions periodically (the agent
# starts but immediately exits with "Runner version vX.Y.Z is
# deprecated and cannot receive messages"). Bump at least quarterly,
# or wire Dependabot to do it.
ARG RUNNER_VERSION=2.334.0
ARG RUNNER_SHA256=048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271

# Tooling versions documented as ARGs so a contributor can see at a
# glance what the image bakes in.
ARG NODE_MAJOR=20

# RUNNER_HOME is the runtime work directory. Under v1.2 it's a tmpfs
# mount populated from RUNNER_DIST at container start (see entrypoint).
# RUNNER_DIST holds the immutable image-baked copy of the agent
# binaries — root-readable, owned by `runner`, copied into the tmpfs
# at start so the agent's mutable state (.runner, .credentials,
# _diag/, _work/) lives on an ephemeral filesystem.
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_HOME=/runner \
    RUNNER_DIST=/opt/runner-dist

# Ubuntu's /bin/sh is `dash`, which doesn't support `set -o pipefail`.
# Switching SHELL to bash for the build-time RUNs lets the install
# scripts use `set -euo pipefail` (fail-fast on apt errors AND on
# upstream pipeline failures like `curl | gpg --dearmor`). The
# `-o pipefail` in the SHELL directive itself also satisfies
# hadolint DL4006 (RUN with a pipe in it must have pipefail set).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base packages + Docker CLI repo + NodeSource repo, all in one RUN
# to keep the layer count small and apt cache out of the final image.
RUN set -euo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        sudo \
        unzip \
        zip \
        lsb-release; \
    # Docker CLI (just the client; daemon stays on the host via socket
    # mount). Using the official Docker apt repo per their install docs.
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    chmod a+r /etc/apt/keyrings/docker.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list; \
    # NodeSource repo for Node ${NODE_MAJOR}.
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        nodejs \
        libicu78; \
    # libicu78 is the version Ubuntu 26.04 ships. The actions/runner
    # agent's installdependencies.sh probes for libicu52–72 only and
    # silently no-ops on anything newer. Without an explicit install
    # the runner crashes at startup with "Libicu's dependencies is
    # missing for Dotnet Core 6.0". When upstream installdependencies.sh
    # learns about ≥73, this line can move. (24.04 needed libicu74 for
    # the same reason — kept that pattern.)
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Non-root user. actions/runner refuses to run as root and the daily
# recycle should not change that. UID 1001 stays out of the way of
# the default ubuntu user (UID 1000).
#
# `--no-create-home` because RUNNER_HOME is a tmpfs mount at runtime;
# entrypoint creates the actual directory tree fresh on each start
# from RUNNER_DIST. Useradd still needs --home-dir set so the runner
# user's $HOME is RUNNER_HOME (the agent reads $HOME for diag/work
# paths).
#
# Docker socket access is granted by the entrypoint at start time:
# it stat's /var/run/docker.sock for the host's docker GID and uses
# setpriv to drop to the runner user with that GID added as a
# supplementary group. No `group_add` in compose, no usermod at
# runtime — keeps /etc/group read-only under read_only: true.
RUN useradd --no-create-home --home-dir ${RUNNER_HOME} --shell /bin/bash --uid 1001 runner

# Stage the actions/runner tarball into RUNNER_DIST (immutable, image-
# baked). At runtime the entrypoint copies this to RUNNER_HOME, which
# is a tmpfs mount so the agent's mutable state files (.runner,
# .credentials, _work/, _diag/) live on an ephemeral filesystem rather
# than the container's writable layer (which is read-only under v1.2).
#
# hadolint DL3003: prefer WORKDIR over `cd` in RUN — switch here for
# the extraction, then switch back to RUNNER_HOME at the bottom of
# the file so the runtime cwd is the tmpfs mount point. WORKDIR
# creates the directory if it doesn't exist, so no `mkdir -p`
# needed (and a separate RUN would trip DL3059 anyway).
WORKDIR ${RUNNER_DIST}

# Download + verify the actions/runner tarball. The SHA256 check is
# the supply-chain seatbelt — a compromised release at the URL would
# fail the check rather than land silently.
RUN set -euo pipefail; \
    curl -fsSL -o actions-runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    echo "${RUNNER_SHA256}  actions-runner.tar.gz" | sha256sum -c -; \
    tar xzf actions-runner.tar.gz; \
    rm actions-runner.tar.gz; \
    chown -R runner:runner ${RUNNER_DIST}; \
    # The runner's installdependencies.sh installs system deps it
    # needs at runtime. Run it once at build time so the recycled
    # container starts cleanly. (libicu74 was already installed
    # above to work around the Noble gap.)
    bash ./bin/installdependencies.sh

# Entrypoint script handles the per-start dance:
#   1. (root phase) auto-detect host docker GID from the mounted socket,
#      populate RUNNER_HOME tmpfs from RUNNER_DIST, chown, then drop
#      privileges to the `runner` user via setpriv with the docker GID
#      added as a supplementary group.
#   2. (runner phase) mint a fresh registration token via the GitHub
#      API (using the PAT from .env), configure the runner under the
#      configured name + labels, then exec ./run.sh. On SIGTERM
#      (from `docker stop` during recycle), the trap calls
#      config.sh remove so the runner deregisters cleanly.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# NOTE: NO `USER runner` directive — the entrypoint starts as root so
# it can stat the docker socket for the host GID and use setpriv to
# drop to `runner` with that GID added to the supplementary group set.
# Doing this in entrypoint rather than the Dockerfile means the GID
# is discovered fresh each start, removing the need for a manually-
# tuned DOCKER_GID in .env (it stays as a documented fallback).
#
# The container is still locked down at runtime via the compose
# file's `cap_drop: [ALL]` + minimal cap_add + `no-new-privileges` +
# `read_only: true`. setpriv only needs CAP_SETUID and CAP_SETGID,
# both of which are in the cap_add list.
WORKDIR ${RUNNER_HOME}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
