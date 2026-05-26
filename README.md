# gha-runner-toolkit

A production-grade self-hosted GitHub Actions runner, packaged for the small-team / single-VPS case.

Built so you can replace ~$50/month of GitHub-hosted Actions billing with a $5 VPS and have it just work. Daily container recycle keeps state bounded. The non-obvious gotchas — libicu version skew on Ubuntu LTS, Testcontainers Ryuk + host networking, docker.sock GID discovery, stale-session recovery — are already solved.

> **Latest release**: `ghcr.io/endbossai/gha-runner-toolkit:1.2.0` — adds Python 3.12 + 3.13 baked into the image so `actions/setup-python` works on Ubuntu 26.04 without falling off the python-versions manifest (issue #11). See [Pre-installed Python](#pre-installed-python).
>
> See [Versioning](#versioning) for the tagging scheme; [Upgrading](#upgrading) for the bump procedure.

## Contents

- [Quick start](#quick-start)
- [Which scope: repo, org, or enterprise?](#which-scope-repo-org-or-enterprise)
- [Deployment in detail](#deployment-in-detail)
  - [Compose deploy](#compose-deploy)
  - [Systemd timer for daily recycle](#systemd-timer-for-daily-recycle)
  - [Multi-runner on one host](#multi-runner-on-one-host)
  - [Multi-runner across hosts](#multi-runner-across-hosts)
- [Configuration reference](#configuration-reference)
- [Verifying the deployment](#verifying-the-deployment)
- [Security posture](#security-posture)
- [Pre-installed Python](#pre-installed-python)
- [What you get](#what-you-get) / [What you trade off](#what-you-trade-off)
- [Versioning](#versioning) + [Upgrading](#upgrading)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing) / [License](#license)

## Quick start

```sh
git clone https://github.com/endbossai/gha-runner-toolkit /opt/gha-runner-toolkit
cd /opt/gha-runner-toolkit
cp .env.example .env && nano .env       # PAT, repo coords, RUNNER_NAME
docker compose up -d
docker compose logs -f runner            # wait for "Listening for Jobs"
sudo cp recycle.{service,timer} /etc/systemd/system/ && sudo systemctl enable --now recycle.timer
```

> **Upgrading from 1.1?** `DOCKER_GID` is now auto-detected from the mounted socket on every container start — you can delete that line from `.env`. It stays as a documented fallback if you ever need it (see [Configuration reference](#optional-knobs)).

Your repo's **Settings → Actions → Runners** should now show the runner as **Idle**. Workflows with `runs-on: [self-hosted, linux, <your-label>]` will land on it.

---

## Which scope: repo, org, or enterprise?

`RUNNER_SCOPE` controls where GitHub registers the runner. Pick the smallest scope that fits your workload — broader scopes ask for broader PAT grants.

| Scope | Use when | Required `.env` vars | PAT requirement |
|---|---|---|---|
| **`repo`** _(default)_ | One repo, or a few repos each happy with their own runner. Simplest blast radius — a PAT leak only registers runners on that one repo. | `GITHUB_OWNER` + `GITHUB_REPO` | Classic: `repo`. Fine-grained: `Administration: write` on the target repo. |
| **`org`** | Multiple repos in one org sharing a single runner pool. One VPS, one runner, picks up jobs from any repo in the org. | `GITHUB_OWNER` _(the org login)_ | Classic: `admin:org`. Fine-grained: org-level `Self-hosted runners: write`. |
| **`enterprise`** | Cross-org runner pool on GHEC / GHES enterprise. Rare outside of large GH Enterprise customers. | `GITHUB_ENTERPRISE` _(the slug from `github.com/enterprises/<slug>`)_ | Enterprise admin PAT with `manage_runners:enterprise`. |

Default behaviour (RUNNER_SCOPE unset or `repo`) is byte-identical to v1.1 — existing deployments keep working without `.env` edits.

### Picking between repo and org

If you currently run one toolkit instance per repo, switching to `RUNNER_SCOPE=org` collapses N runners → 1. Trade-off: a compromised workflow in **any** org repo can pwn the host via the docker socket (still the headline risk; see [What you trade off](#what-you-trade-off)). Org scope amortises that risk across more code paths — fine for trusted internal orgs, bad for orgs with public-facing repos that take outside PRs.

### Picking between org and enterprise

Enterprise scope is mostly for very large GHEC / GHES customers who need a single runner pool serving multiple orgs. For everyone else, prefer `org` — the PAT requirements are less invasive.

### Runner groups (out of scope here)

If you need to restrict which repos in an org are allowed to use a given runner, GitHub's **runner groups** are the right primitive. Configure on the GitHub side (Settings → Actions → Runner groups). The toolkit doesn't need to know — `actions/runner` picks up the org's default group at registration.

---

## Deployment in detail

### Compose deploy

1. **Clone into a stable path.** The systemd unit files reference `/opt/gha-runner-toolkit`. If you put the checkout elsewhere, edit `recycle.service`'s `WorkingDirectory` and `ExecStart` paths to match.

   ```sh
   sudo git clone https://github.com/endbossai/gha-runner-toolkit /opt/gha-runner-toolkit
   cd /opt/gha-runner-toolkit
   ```

2. **Configure `.env`.** Copy the template and fill it in. Required values are `GITHUB_PAT`, `RUNNER_NAME`, `RUNNER_LABELS`, plus the coordinate vars for your chosen `RUNNER_SCOPE` (default `repo` needs `GITHUB_OWNER` + `GITHUB_REPO`; see [Which scope?](#which-scope-repo-org-or-enterprise) for `org` / `enterprise`). Everything else is optional with sensible defaults (including `DOCKER_GID` — auto-detected since v1.2). [Configuration reference](#configuration-reference) lists the optional knobs.

   ```sh
   cp .env.example .env
   nano .env
   ```

3. **Start the runner.** First start pulls the image (~500MB compressed); subsequent recycles reuse the local cache.

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
| `GITHUB_PAT` | Used to mint short-lived registration + removal tokens at runtime. Required PAT scope depends on `RUNNER_SCOPE` — see [Which scope?](#which-scope-repo-org-or-enterprise). **Don't commit this.** |
| `RUNNER_NAME` | Stable identifier shown in the GitHub Actions → Runners settings. Unique per registered instance. |
| `RUNNER_LABELS` | Comma-separated labels workflows can target via `runs-on: [self-hosted, linux, <label>]`. `self-hosted`, `Linux`, `X64` are added automatically. |

Additionally, **one of** the following coordinate sets based on `RUNNER_SCOPE`:

| `RUNNER_SCOPE` | Required coordinate vars |
|---|---|
| `repo` _(default)_ | `GITHUB_OWNER` + `GITHUB_REPO` |
| `org` | `GITHUB_OWNER` _(the org login)_ |
| `enterprise` | `GITHUB_ENTERPRISE` _(slug from `github.com/enterprises/<slug>`)_ |

### Optional knobs

| Variable | Default | What it does |
|---|---|---|
| `RUNNER_SCOPE` | `repo` | Which GitHub API endpoint the runner registers against. `repo` / `org` / `enterprise`. See [Which scope?](#which-scope-repo-org-or-enterprise) for the trade-offs. |
| `DOCKER_GID` | _auto-detected_ | Host's docker group GID. Auto-detected from the mounted socket at start time (v1.2+); set this only if auto-detect fails. Discover via `getent group docker \| cut -d: -f3` on the host. Typical: `999` on Linux, `0` on Docker Desktop. |
| `CONTAINER_NAME` | `gha-runner` | Override when running multiple instances on one host (each must be unique). Must match the compose file's `container_name`. |
| `RECYCLE_DRAIN_TIMEOUT_SECONDS` | `600` | Hard ceiling for waiting on an in-flight job before forcing recycle. Bump if your jobs routinely exceed 10 min. |
| `RECYCLE_DRAIN_POLL_SECONDS` | `30` | How often we re-query the GitHub API for busy-state during drain. |
| `RECYCLE_PRUNE_FILTER` | `until=24h` | Filter for the post-recycle `docker container prune`. Set `until=0` to skip prune entirely; tighten on disk-pressure hosts. |
| `RECYCLE_NOTIFY_WEBHOOK` | _unset_ | If set, POST a JSON payload to this URL when the daily drain exceeds `RECYCLE_DRAIN_TIMEOUT_SECONDS` (i.e. a long-running job got force-stopped). Body: `{event, summary, runner, repo, container, timeout_seconds, timestamp}`. Wire into Slack/Discord/Teams inbound webhooks. |
| `RECYCLE_API_MAX_FAILURES` | `3` | How many consecutive GitHub API failures during drain before we stop trusting the API for this recycle and fall back to log-grep. Bump on flaky links; lower for fail-fast posture. |

---

## Verifying the deployment

Three places to check after `docker compose up -d`:

1. **GitHub UI** — Settings → Actions → Runners. Your `RUNNER_NAME` should be there with a green **Idle** badge.
2. **Container state** — `docker compose ps` shows `Up X minutes (healthy)`. Healthcheck is `pgrep -x Runner.Listener` against the runner agent process.
3. **Logs** — `docker compose logs --tail 30 runner` ends with `Listening for Jobs` and no recent stack traces.

If any of these are off, jump to [Troubleshooting](#troubleshooting).

---

## Security posture

v1.2 ships container hardening that collapses the blast radius of a compromised workflow step. The four primitives, all set in `docker-compose.yml`:

| Hardening | What it does |
|---|---|
| `read_only: true` | Container's writable layer is sealed. Anything a workflow writes outside the declared tmpfs mounts (`/runner`, `/tmp`, `/home/runner`) hits a read-only filesystem and fails immediately. |
| `no-new-privileges: true` | Prevents `execve` from granting any new privilege bits. Setuid binaries can't elevate. |
| `cap_drop: [ALL]` | Drops every Linux capability the kernel grants by default. |
| `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]` | Re-adds only the four caps the entrypoint and typical workflow steps need (privilege drop via `setpriv`, `chown` of the populated `/runner` tmpfs, `tar -p` extraction during `actions/setup-java` & friends). |

The agent's mutable state (`.runner`, `.credentials`, `_work/`, `_diag/`) lives on the `/runner` tmpfs — populated from the image-baked `/opt/runner-dist` by the entrypoint on each container start. Daily recycle wipes the tmpfs along with everything else.

### What this does NOT fix

**The Docker socket is still mounted.** A workflow with effective socket access can spawn a privileged sibling container and pwn the host. No amount of capability dropping inside _this_ container changes that.

The socket mount is non-negotiable for the use case: workflows that build/push docker images, plus Testcontainers in a docker-out-of-docker setup, both require it.

### Public repositories: don't

This toolkit is built for **private repos where committers are trusted**. On a public repo, anyone who can submit a PR can run arbitrary code on your VPS via the docker socket. The hardening above does not change that calculus.

If you must run self-hosted on a public repo:

- Require approval for first-time contributors' workflow runs (Settings → Actions → General → "Require approval for first-time contributors" or stricter).
- Restrict the runner to a label that only your trusted workflows use; do NOT add it as a default in `runs-on`.
- Consider an ephemeral-runner pattern (one container per job, container destroyed on completion) — out of scope for this toolkit; see [actions-runner-controller](https://github.com/actions/actions-runner-controller).
- Audit the workflow YAML in every PR before you let CI touch it.

The author runs this on private repos only. Use on public repos at your own risk.

### Auto-detected `DOCKER_GID`

The entrypoint stats `/var/run/docker.sock` at start time to discover the host's docker group GID, then uses `setpriv` to drop to the `runner` user with that GID added as a supplementary group. No `usermod`, no writable `/etc/group`, no operator-tuned `DOCKER_GID` in `.env` for the common case.

If auto-detection fails (socket not mounted, exotic stat failures), the entrypoint logs a warning and falls back to `DOCKER_GID` from `.env`. With nothing set, the docker CLI inside workflows won't have access to the socket and will fail loudly.

---

## Pre-installed Python

`actions/setup-python` on Ubuntu 26.04 hits a dead end out of the box: the action queries the `actions/python-versions` manifest for a prebuilt interpreter matching the runner's reported OS, and the manifest doesn't yet list 26.04 — so every `setup-python` step fails with `The version 'X.Y' with architecture 'x64' was not found for Ubuntu 26.04`.

v1.2 fixes this by baking two portable interpreters into the image at the exact path `setup-python`'s tool-cache lookup expects:

| Version | Source | Tool-cache path |
|---|---|---|
| 3.12.13 | `python-build-standalone` (SHA256-pinned) | `/opt/hostedtoolcache/Python/3.12.13/x64/` |
| 3.13.13 | `python-build-standalone` (SHA256-pinned) | `/opt/hostedtoolcache/Python/3.13.13/x64/` |

`setup-python` finds the cache entry, skips the failing download path, and uses the baked interpreter directly. `RUNNER_TOOL_CACHE` and `AGENT_TOOLSDIRECTORY` env vars are both set to `/opt/hostedtoolcache` so the action's lookup hits.

Workflows requesting `3.12` or `3.13` get the exact patch versions above; requesting a minor that isn't baked (e.g. `3.11`) falls through to the download path and currently fails — bake more versions if you need them. To bump or add interpreters, edit the `PYTHON_*_VERSION` / `PYTHON_*_SHA256` ARGs in the [Dockerfile](Dockerfile) using the recipe documented inline.

**Tool cache is writable.** It's mounted as a tmpfs (size 1G) so `pip install -r requirements.txt` against the cached interpreter works without `--user` gymnastics. Like the `/runner` and `/home/runner` tmpfs mounts, the cache dies with the daily recycle — pip caches lasting at most ~24h.

---

## What you get

- **Containerised** — runner agent lives in a Docker container. The container's filesystem dies daily; no long-tail state accumulates.
- **Hardened by default** — `read_only: true`, `cap_drop: ALL` with a four-cap allowlist, `no-new-privileges`, agent state on tmpfs. See [Security posture](#security-posture).
- **Auto-labelled by version** — every registered runner gets a `runner-toolkit-<version>` label (e.g. `runner-toolkit-1.1.2`) baked in at image-build time. The GitHub Actions Runners page tells you which image each runner is on without SSHing into the VPS.
- **Daily recycle** — systemd timer drains (≤10 min waiting on in-flight job, via the GitHub API's `busy` field) then `docker compose down && compose pull && compose up -d`. Bounds disk growth and picks up the latest published image automatically. Optional webhook fires on drain-timeout.
- **Drain-then-replace** — GitHub-API-based busy check is unforgeable; a malicious workflow can't fake "idle" via its stdout. Per-status error classification (401, 403, 5xx, etc.); log-grep fallback after `RECYCLE_API_MAX_FAILURES` API errors.
- **Bounded state** — Gradle / Maven / Docker layer caches live inside the container, die with it. Worst case: one day's worth of caches.
- **Supply-chain pinned** — `ubuntu:26.04` by digest, `actions/runner` by version + SHA256 verification on the tarball. Bumps ride a deliberate Dockerfile edit, not a runtime auto-update.
- **Pre-installed**: Docker CLI (talks to mounted host socket), Node ≥ 22, Python 3.12 + 3.13 (in the `actions/setup-python` tool cache), git, curl, jq. JDKs aren't baked — `actions/setup-java` in workflows handles version selection and caches inside the container's day-long lifetime.

## What you trade off

- **Single point of failure** — one runner, one host. If the VPS reboots, jobs queue. Mitigate by running a second runner with the same label (see [Multi-runner](#multi-runner-on-one-host)).
- **Mid-job recycle ceiling** — a job that exceeds `RECYCLE_DRAIN_TIMEOUT_SECONDS` past the recycle window gets hard-stopped. 03:00 UTC is off-peak for most teams; tune the timer / timeout if not. Wire up `RECYCLE_NOTIFY_WEBHOOK` to get pinged when this happens.
- **Docker socket mount = root on the host** — a workflow with effective socket access can pwn the host, regardless of any in-container hardening. Acceptable on **private repos** where you trust the committers. **Do not use this on a public repo without further hardening** — anyone who can submit a PR can run arbitrary code on your VPS. See [Security posture → Public repositories: don't](#public-repositories-dont).
- **Tmpfs sizing** — the agent's writable paths live in RAM-backed tmpfs (collapses cleanly with the daily recycle). Workflows that check out very large repos or generate multi-GB build artifacts may run into OOM before they hit disk. Bump container `mem_limit` (in compose) and the tmpfs sizes together if you need more headroom.
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
