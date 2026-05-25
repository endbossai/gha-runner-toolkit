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

# ubuntu:24.04 LTS (Noble Numbat). Pinned by digest for reproducibility.
# To bump:
#   docker pull ubuntu:24.04
#   docker inspect ubuntu:24.04 --format='{{index .RepoDigests 0}}'
FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

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

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_HOME=/runner

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
        libicu74; \
    # libicu74 is the version Ubuntu 24.04 (Noble) ships, and the
    # actions/runner agent's installdependencies.sh probes for
    # libicu52–72 only — silently no-ops on Noble. The runner then
    # crashes at startup with "Libicu's dependencies is missing for
    # Dotnet Core 6.0". Installing it explicitly here closes that
    # gap. When upstream installdependencies.sh learns about
    # libicu74, this line can move.
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Non-root user. actions/runner refuses to run as root and the daily
# recycle should not change that. UID 1001 stays out of the way of
# the default ubuntu user (UID 1000).
#
# Docker socket access is granted at compose-up time via `group_add`
# (the host's docker GID is added as a supplementary group). No sudo
# rule is needed — workflow steps that need `docker` invoke it
# directly and the kernel's group check accepts the call. An earlier
# draft also had a `NOPASSWD: /usr/bin/docker` sudoers rule; dropped
# because it's redundant with group_add and would add an unnecessary
# escalation surface (`sudo docker run --privileged …`).
RUN useradd --create-home --home-dir ${RUNNER_HOME} --shell /bin/bash --uid 1001 runner

# Set the workdir BEFORE the runner-extraction RUN so we can drop the
# `cd ${RUNNER_HOME}` inside it (hadolint DL3003: prefer WORKDIR over
# `cd` in RUN). USER is set further down — we stay root for the
# extraction so chown can apply.
WORKDIR ${RUNNER_HOME}

# Download + verify the actions/runner tarball. The SHA256 check is
# the supply-chain seatbelt — a compromised release at the URL would
# fail the check rather than land silently.
RUN set -euo pipefail; \
    curl -fsSL -o actions-runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    echo "${RUNNER_SHA256}  actions-runner.tar.gz" | sha256sum -c -; \
    tar xzf actions-runner.tar.gz; \
    rm actions-runner.tar.gz; \
    chown -R runner:runner ${RUNNER_HOME}; \
    # The runner's installdependencies.sh installs system deps it
    # needs at runtime. Run it once at build time so the recycled
    # container starts cleanly. (libicu74 was already installed
    # above to work around the Noble gap.)
    bash ./bin/installdependencies.sh

# Entrypoint script handles the per-start dance: mint a fresh
# registration token via the GitHub API (using the PAT from .env),
# configure the runner under the configured name + labels, then
# exec ./run.sh. On SIGTERM (from `docker stop` during recycle),
# the trap calls config.sh remove so the runner deregisters cleanly.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER runner
# WORKDIR already set above; restating is a no-op but documents the
# expected runtime cwd at the bottom of the file.
WORKDIR ${RUNNER_HOME}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
