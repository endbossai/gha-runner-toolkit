# gha-runner-toolkit

A production-grade self-hosted GitHub Actions runner, packaged for the small-team / single-VPS case.

Built so you can replace ~$50/month of GitHub-hosted Actions billing with a $5 VPS and have it just work. Daily container recycle keeps state bounded. The non-obvious gotchas — libicu74 on Ubuntu 24.04, Testcontainers Ryuk + host networking, docker.sock GID discovery, stale-session recovery — are already solved.

> **Latest release**: `ghcr.io/endbossai/gha-runner-toolkit:1.1.0`
>
> See [Versioning](#versioning) for the tagging scheme; [Upgrading](#upgrading) for the bump procedure.

## Contents

- [Quick start](#quick-start)
- [Deployment in detail](#deployment-in-detail)
  - [Compose deploy](#compose-deploy)
  - [Systemd timer for daily recycle](#systemd-timer-for-daily-recycle)
  - [Multi-runner on one host](#multi-runner-on-one-host)
  - [Multi-runner across hosts](#multi-runner-across-hosts)
- [Configuration reference](#configuration-reference)
- [Verifying the deployment](#verifying-the-deployment)
- [What you get](#what-you-get) / [What you trade off](#what-you-trade-off)
- [Versioning](#versioning) + [Upgrading](#upgrading)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing) / [License](#license)

## Quick start

```sh
git clone https://github.com/endbossai/gha-runner-toolkit /opt/gha-runner-toolkit
cd /opt/gha-runner-toolkit
cp .env.example .env && nano .env       # PAT, repo coords, RUNNER_NAME
echo "DOCKER_GID=$(getent group docker | cut -d: -f3)" >> .env
docker compose up -d
docker compose logs -f runner            # wait for "Listening for Jobs"
sudo cp recycle.{service,timer} /etc/systemd/system/ && sudo systemctl enable --now recycle.timer
```

Your repo's **Settings → Actions → Runners** should now show the runner as **Idle**. Workflows with `runs-on: [self-hosted, linux, <your-label>]` will land on it.

---

## Deployment in detail

### Compose deploy

1. **Clone into a stable path.** The systemd unit files reference `/opt/gha-runner-toolkit`. If you put the checkout elsewhere, edit `recycle.service`'s `WorkingDirectory` and `ExecStart` paths to match.

   ```sh
   sudo git clone https://github.com/endbossai/gha-runner-toolkit /opt/gha-runner-toolkit
   cd /opt/gha-runner-toolkit
   ```

2. **Configure `.env`.** Copy the template and fill it in. The required values are `GITHUB_PAT`, `GITHUB_OWNER`, `GITHUB_REPO`, `RUNNER_NAME`, `RUNNER_LABELS`, `DOCKER_GID`. See [Configuration reference](#configuration-reference) for what each does + the optional knobs.

   ```sh
   cp .env.example .env
   nano .env
   ```

3. **Discover the host's docker group GID** and pin it as `DOCKER_GID` in `.env`. This is the #1 install-time gotcha — without it, the runner gets "permission denied" on the docker socket and restart-loops.

   | Host | Typical `DOCKER_GID` |
   |---|---|
   | Ubuntu / Debian VPS | `999` (sometimes `998`) |
   | Docker Desktop on macOS / Windows | `0` (root-owned socket in the VM) |

   Discover the actual value:

   ```sh
   getent group docker | cut -d: -f3        # on the host
   # — OR after a failed first start: —
   docker exec gha-runner stat -c '%g' /var/run/docker.sock
   ```

4. **Start the runner.** First start pulls the image (~500MB compressed); subsequent recycles reuse the local cache.

   ```sh
   docker compose up -d
   docker compose logs -f runner
   ```

   Ctrl-C the log tail once you see `Listening for Jobs`. The container stays up in the background.

### Systemd timer for daily recycle

The runner works without recycle, but you'll accumulate disk state and miss base-image security patches. The recycle is a couple of files away:

```sh
sudo cp recycle.service /etc/systemd/system/
sudo cp recycle.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now recycle.timer
systemctl list-timers recycle.timer       # confirms next fire at 03:00 UTC
```

`recycle.sh` does drain-then-replace: it polls the GitHub API for the runner's `busy` state, waits up to `RECYCLE_DRAIN_TIMEOUT_SECONDS` (default 600), then `docker compose down && compose pull && compose up -d`, then `docker container prune` to clear orphan testcontainers. Output goes to `journalctl -u recycle.service`.

### Multi-runner on one host

Each runner needs unique `RUNNER_NAME` and `CONTAINER_NAME`. Use compose project names to keep the deployments isolated:

```sh
# First runner — uses /opt/gha-runner-toolkit/.env (RUNNER_NAME=vps1-runner-1, CONTAINER_NAME default)
cd /opt/gha-runner-toolkit
docker compose -p runner-1 up -d

# Second runner — duplicate the dir, edit .env, run with a different project name
sudo cp -r /opt/gha-runner-toolkit /opt/gha-runner-toolkit-2
cd /opt/gha-runner-toolkit-2
sed -i 's/^RUNNER_NAME=.*/RUNNER_NAME=vps1-runner-2/' .env
echo 'CONTAINER_NAME=gha-runner-2' >> .env
docker compose -p runner-2 up -d
```

Both runners register against the same repo with the same label, so GitHub round-robins jobs between them. If you want deliberate routing (e.g. one for builds, one for docker work), give them different `RUNNER_LABELS`.

For the recycle timer with multiple runners on one host, copy each compose dir's `recycle.service` to a unique name (`recycle-runner-2.service`) and create matching timers. Or write one wrapper script that recycles all of them in sequence.

### Multi-runner across hosts

Trivially supported — each host runs the toolkit independently, with its own `.env` and `RUNNER_NAME`. Same label across hosts → load-balanced.

```sh
# On each VPS:
sudo git clone https://github.com/endbossai/gha-runner-toolkit /opt/gha-runner-toolkit
cd /opt/gha-runner-toolkit
cp .env.example .env
# set RUNNER_NAME=<hostname>-1 (unique per host), same RUNNER_LABELS everywhere
docker compose up -d
```

Hosts don't need to talk to each other. They only talk to github.com.

---

## Configuration reference

All settings live in `.env` next to the compose file. `.env.example` carries the same fields with inline comments.

### Required

| Variable | What it does |
|---|---|
| `GITHUB_PAT` | Classic PAT with `repo` scope, or fine-grained with `Administration: write`. Used to mint short-lived registration + removal tokens at runtime. **Don't commit this.** |
| `GITHUB_OWNER` | Repo owner (org or user). |
| `GITHUB_REPO` | Repo name (without the owner prefix). |
| `RUNNER_NAME` | Stable identifier shown in the repo's Actions → Runners settings. Unique per registered instance. |
| `RUNNER_LABELS` | Comma-separated labels workflows can target via `runs-on: [self-hosted, linux, <label>]`. `self-hosted`, `Linux`, `X64` are added automatically. |
| `DOCKER_GID` | Host's docker group GID. See [Compose deploy](#compose-deploy) step 3. |

### Optional knobs

| Variable | Default | What it does |
|---|---|---|
| `CONTAINER_NAME` | `gha-runner` | Override when running multiple instances on one host (each must be unique). Must match the compose file's `container_name`. |
| `RECYCLE_DRAIN_TIMEOUT_SECONDS` | `600` | Hard ceiling for waiting on an in-flight job before forcing recycle. Bump if your jobs routinely exceed 10 min. |
| `RECYCLE_DRAIN_POLL_SECONDS` | `30` | How often we re-query the GitHub API for busy-state during drain. |
| `RECYCLE_PRUNE_FILTER` | `until=24h` | Filter for the post-recycle `docker container prune`. Set `until=0` to skip prune entirely; tighten on disk-pressure hosts. |

---

## Verifying the deployment

Three places to check after `docker compose up -d`:

1. **GitHub UI** — Settings → Actions → Runners. Your `RUNNER_NAME` should be there with a green **Idle** badge.
2. **Container state** — `docker compose ps` shows `Up X minutes (healthy)`. Healthcheck is `pgrep -x Runner.Listener` against the runner agent process.
3. **Logs** — `docker compose logs --tail 30 runner` ends with `Listening for Jobs` and no recent stack traces.

If any of these are off, jump to [Troubleshooting](#troubleshooting).

---

## What you get

- **Containerised** — runner agent lives in a Docker container. The container's filesystem dies daily; no long-tail state accumulates.
- **Daily recycle** — systemd timer drains (≤10 min waiting on in-flight job, via the GitHub API's `busy` field) then `docker compose down && compose pull && compose up -d`. Bounds disk growth and picks up the latest published image automatically.
- **Drain-then-replace** — GitHub-API-based busy check is unforgeable; a malicious workflow can't fake "idle" via its stdout. Log-grep fallback if the API is unreachable.
- **Bounded state** — Gradle / Maven / Docker layer caches live inside the container, die with it. Worst case: one day's worth of caches.
- **Supply-chain pinned** — `ubuntu:24.04` by digest, `actions/runner` by version + SHA256 verification on the tarball. Bumps ride a deliberate Dockerfile edit, not a runtime auto-update.
- **Pre-installed**: Docker CLI (talks to mounted host socket), Node ≥ 20, git, curl, jq. JDKs aren't baked — `actions/setup-java` in workflows handles version selection and caches inside the container's day-long lifetime.

## What you trade off

- **Single point of failure** — one runner, one host. If the VPS reboots, jobs queue. Mitigate by running a second runner with the same label (see [Multi-runner](#multi-runner-on-one-host)).
- **Mid-job recycle ceiling** — a job that exceeds `RECYCLE_DRAIN_TIMEOUT_SECONDS` past the recycle window gets hard-stopped. 03:00 UTC is off-peak for most teams; tune the timer / timeout if not.
- **Docker socket mount = root on the host** — a workflow with effective socket access can pwn the host. Acceptable on **private repos** where you trust the committers. **Do not use this on a public repo without further hardening** — anyone who can submit a PR can run arbitrary code on your VPS.
- **No auto-update** — runner-agent version is pinned in the image. GitHub deprecates old agents periodically; we bump via release. Trade-off accepted in exchange for supply-chain hygiene.

---

## Versioning

Semantic versioning. Images publish to `ghcr.io/endbossai/gha-runner-toolkit:MAJOR.MINOR.PATCH` on every git tag (the `v` prefix from git tags is stripped per Docker conventions). Rolling tags `:MAJOR.MINOR`, `:MAJOR`, and `:latest` also publish.

| Tier | Meaning |
|---|---|
| `MAJOR` | Breaking changes to the container interface (env vars, volume mounts, healthcheck contract) |
| `MINOR` | New features (multi-runner support, new env vars, additional tooling baked in) |
| `PATCH` | Bug fixes, security patches, runner-agent version bumps |

**Pin a specific tag in production.** `latest` exists but isn't recommended for any environment you care about.

## Upgrading

```sh
cd /opt/gha-runner-toolkit
git pull                                  # gets the new compose.yml + scripts
nano docker-compose.yml                   # change the image: tag to the new version
docker compose pull
sudo systemctl start recycle.service      # graceful drain + replace
```

Or just wait for the next 03:00 UTC recycle — it'll pull the new image automatically on a floating tag, or you can edit the pinned tag and let the next cycle do the swap.

---

## Troubleshooting

Quick triage:

- **Restart loop / "permission denied" on socket** → `DOCKER_GID` mismatch. See [docs/runbook.md](docs/runbook.md#setting-docker_gid-correctly).
- **"A session for this runner already exists"** → ghost session from a previous container. See [docs/runbook.md](docs/runbook.md#ghost-session-recovery).
- **Workflows queue forever** → runner is offline OR labels don't match. See [docs/runbook.md](docs/runbook.md#diagnosing-a-stuck-job).
- **Recycle never fires / fails halfway** → `journalctl -u recycle.service`. See [docs/runbook.md](docs/runbook.md#diagnosing-a-wedged-recycle).

Full operator manual: [docs/runbook.md](docs/runbook.md). Design rationale: [docs/architecture.md](docs/architecture.md).

---

## Contributing

Issues and PRs welcome. The project's posture is **opinionated tool for the small-team / single-VPS case** — feature requests that pull toward Kubernetes-scale runner orchestration (`actions-runner-controller` territory) are out of scope; that's a different tool.

## License

Apache 2.0. See [LICENSE](LICENSE).
