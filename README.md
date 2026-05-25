# gha-runner-toolkit

A production-grade self-hosted GitHub Actions runner, packaged for the small-team / single-VPS case.

Built so you can replace ~$50/month of GitHub-hosted Actions billing with a $5 VPS and have it just work. Daily container recycle keeps state bounded. The non-obvious gotchas — libicu74 on Ubuntu 24.04, Testcontainers Ryuk + host networking, docker.sock GID discovery, stale-session recovery — are already solved.

## Quick start

On any Linux host with Docker installed:

```sh
# 1. Pull the compose + scripts.
git clone https://github.com/endbossai/gha-runner-toolkit /opt/gha-runner-toolkit
cd /opt/gha-runner-toolkit

# 2. Configure.
cp .env.example .env
nano .env   # set GITHUB_PAT, GITHUB_OWNER, GITHUB_REPO, RUNNER_NAME

# 3. Discover the host's Docker GID and set DOCKER_GID in .env.
#    Usually 999 on Linux; 0 on Docker Desktop (Mac/Win).
getent group docker | cut -d: -f3

# 4. Start the runner.
docker compose up -d
docker compose logs -f runner   # wait for "Listening for Jobs"; Ctrl-C when seen

# 5. Install the daily-recycle systemd timer.
sudo cp recycle.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now recycle.timer
systemctl list-timers recycle.timer   # confirm next 03:00 UTC trigger
```

Your repo's Settings → Actions → Runners should show the registered runner as **Idle**. Workflows that say `runs-on: [self-hosted, linux, <your-label>]` will land on it.

## What you get

- **Containerised** — runner agent lives in a Docker container. The container's filesystem dies daily; no long-tail state accumulates.
- **Daily recycle at 03:00 UTC** — systemd timer drains the runner (waits for any in-flight job up to 10 min), then `docker compose down && build --pull && up -d`. Picks up base-image security patches without manual intervention.
- **Drain-then-replace** — GitHub-API-based busy check makes the drain unforgeable; a malicious workflow can't fake "idle" via its stdout. Log-grep fallback if the API is unreachable.
- **Bounded state** — Gradle / Maven / Docker layer caches live inside the container, die with it. Worst case: one day's worth of caches.
- **Supply-chain pinned** — `ubuntu:24.04` by digest, `actions/runner` by version + SHA256 verification on the tarball. Bumps ride a `Dockerfile` edit, not a runtime auto-update.
- **Pre-installed**: Docker CLI (talks to mounted host socket), Node ≥ 20, git, curl, jq. JDKs aren't baked — `actions/setup-java` in workflows handles version selection and caches inside the container's day-long lifetime.

## What you trade off

- **Single point of failure** — one runner, one host. If the VPS reboots, jobs queue. Mitigate by running a second runner with the same label (`docker compose -p runner-2 …`).
- **Mid-job recycle ceiling** — a job that runs longer than 10 minutes past 03:00 UTC gets hard-stopped. 03:00 UTC = quiet for most teams; if yours isn't, tune `recycle.sh` or change the timer.
- **Docker socket mount = root on the host** — a workflow with effective socket access can pwn the VPS. This is acceptable on **private repos** where you trust the committers. **Do not use this on a public repo without further hardening** — anyone who can submit a PR can run arbitrary code on your VPS.
- **No auto-update** — runner-agent version is pinned in the Dockerfile. GitHub deprecates old agent versions periodically; bump it via PR + image rebuild. Trade-off accepted in exchange for supply-chain hygiene.

## Where to go next

- **[docs/architecture.md](docs/architecture.md)** — design rationale: why container, why daily recycle, what alternatives were considered.
- **[docs/runbook.md](docs/runbook.md)** — operating manual: lifecycle, troubleshooting (Docker GID, ghost sessions, wedged recycles), recovery procedures.
- **[Dockerfile](Dockerfile)** — every supply-chain pin documented inline; bump runner version + SHA256 to update the agent.

## Versioning

Semantic versioning. Images are published to `ghcr.io/endbossai/gha-runner-toolkit:vMAJOR.MINOR.PATCH` on every tag.

- `vMAJOR` — breaking changes to the container interface (env vars, volume mounts, healthcheck contract)
- `vMINOR` — new features (multi-runner support, new env vars, additional tooling baked in)
- `vPATCH` — bug fixes, security patches, runner-agent version bumps

Pin a specific tag in production. `latest` exists but isn't recommended for any environment you care about.

## Contributing

Issues and PRs welcome. The project's posture is "opinionated tool for the small-team / single-VPS case" — feature requests that pull toward Kubernetes-scale runners (`actions-runner-controller` territory) are out of scope; that's a different tool.

## License

Apache 2.0. See [LICENSE](LICENSE).
