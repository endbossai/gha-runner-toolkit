# Architecture

Design rationale for `gha-runner-toolkit`: why this shape, what alternatives were considered, what trade-offs land where.

## Context

GitHub-hosted Actions runners are convenient but expensive at scale. Private repos on the free tier hit billable usage quickly once a project moves past hobby pace — `docker build` + Trivy + a real test suite are easily 8–12 minutes per PR. At ~6 PRs/day, that's $40-60/month per service module, scaling with team size and code volume.

For teams that already operate a small VPS (a few dollars a month, sunk cost), routing CI to a self-hosted runner there is the standard cost-management move. GitHub Actions supports self-hosted runners as a first-class feature; the rough edges are operational rather than functional.

This toolkit packages the operational answer: a containerised runner, daily-recycled, with the known docker-out-of-docker gotchas pre-solved.

## Decision

Run a self-hosted GitHub Actions runner on a Linux host, packaged as a single Docker container we own end-to-end, declared via `docker compose`, and recycled daily at 03:00 UTC via a systemd timer that drains the runner agent before replacing the container.

- **Image** — `Dockerfile` builds from a pinned `ubuntu:24.04` base. Includes the `actions/runner` binary at a SHA256-pinned version, Docker CLI (talks to the mounted host socket), Node ≥ 20 (for any npm-shaped CI tooling), git, curl, jq, ca-certificates. No SSH server, no extra services. JDK is not baked in — `actions/setup-java` in workflows handles version selection and caches downloads inside the container.
- **Deployment** — `docker-compose.yml` declares a single `runner` service. Restart policy `unless-stopped`. Mounts the host's `/var/run/docker.sock` so the runner can call Docker for image builds and Testcontainers. Registration PAT comes from a gitignored `.env` file alongside the compose file.
- **Recycle** — `recycle.sh` drains the runner agent (uses the GitHub API's `runners[].busy` field as the canonical idle signal, with a log-grep fallback; waits up to a 10-minute ceiling), then `docker compose down && docker compose pull && docker compose up -d`. A systemd timer (`recycle.timer`) fires the matching one-shot service (`recycle.service`) at 03:00 UTC daily.
- **Caching** — Gradle, Maven, npm, and Docker layer caches live INSIDE the container, dying with it at the daily recycle. Builds within the day see a warm cache (typically 2-4× faster than ephemeral GitHub-hosted runners); first build after recycle is cold. Bounded disk growth: at most one day's worth of artifacts accumulate before the volume is wiped.
- **Routing** — workflows use `runs-on: [self-hosted, linux, <your-label>]`. The label is set per-deployment via `RUNNER_LABELS` in `.env`. Multiple hosts can share a label (round-robin distribution) or use distinct labels (deliberate routing).

## Consequences

### Positive

- **Cost** — GitHub Actions billing for the heavy workflows drops to zero. A $5-6/month VPS replaces $40-60/month of GHA charges. Net savings scale with the number of repos/services using the runner.
- **Build speed within a day** — persistent Gradle, Maven, Docker layer caches give 2-4× faster builds vs ephemeral GitHub-hosted runners. Typical PR re-runs become 1-2 min instead of 5-7 min.
- **Daily clean slate** — bounded disk growth, no long-tail cache-poisoning risk, no "the runner has been up for 6 months and accumulated mysterious state" debugging.
- **Image updates land predictably** — the daily recycle's `docker compose pull` refreshes the image tag (for pinned versions this is a no-op; for `latest`-style consumption it picks up the newest published image automatically).
- **Image is the single source of truth for the CI environment** — reproducible from `Dockerfile` + the `.env`. A second host gets the same env by running the same compose.

### Negative

- **Single point of failure** — one host, one runner. If it goes down (host reboot, kernel panic, disk full, recycle script fails), jobs queue until it comes back. Mitigate by running a second runner with the same label.
- **Mid-job recycle interruptions** — if the 03:00 UTC timer fires while a job is running, the drain logic waits up to 10 minutes for the in-flight job; a job that exceeds that ceiling gets a hard stop. 03:00 UTC is off-peak for most timezones; tune if yours isn't.
- **Operational burden** — the host now has CI-relevant state. OS updates, runner-agent updates (handled by Dockerfile bumps + image rebuild), disk monitoring, log rotation. Documented in the runbook.
- **First build after recycle is cold** — pays the deps-download cost once per day (~3-4 min penalty). Schedule recycle for a low-traffic hour so the cold build lands on a "no-one's-pushing-yet" PR.
- **Docker socket = root on host** — a workflow with effective socket access can pwn the host. Acceptable on **private repos** where committers are trusted; **unsafe on public repos** where any forker can submit a PR. Public-repo use requires further hardening (rootless Docker, sandboxed runners) that this toolkit doesn't currently provide.

### Neutral

- **PAT-based registration** — the runner mints short-lived registration tokens at startup using a long-lived PAT. Rotation: replace `GITHUB_PAT` in `.env` and recycle the container. Documented in the runbook.
- **Two CI environments** — workflows running on self-hosted need to assume the container's tooling; workflows running on GitHub-hosted need to assume `ubuntu-latest`. Today the typical split is along clean lines (heavy workflows vs trivial ones) and there's no overlap creating tooling drift.

## Alternatives considered

- **Path-filter the heavy workflows so they only run on relevant PRs.** Cheaper to implement (~10 lines of YAML), zero infra. Cuts burn but doesn't eliminate it, and the underlying cost trajectory still climbs with project size. Worth doing in combination with self-hosted but doesn't replace it.
- **Ephemeral container per job** (`--ephemeral` flag, scripted loop). Cleanest isolation — every job starts in a fresh container, no cache poisoning possible. Trade-off: cold cache every job, making builds ~3-4× slower than persistent self-hosted. The daily-recycle pattern in this toolkit keeps within-day warmth while inheriting most of the ephemeral isolation benefits.
- **Persistent container with no recycle.** Simplest setup; faster builds because cache never invalidates. Trade-off: disk-growth blackhole, no automatic security-patch cadence, harder mental model for "what state is the runner in." Daily recycle adds ~30 lines of script and eliminates these.
- **Multiple runners for HA.** Doubles the cost (or splits compute on one host) and the operational burden. Not justified at small-team pace; trivially added later by deploying a second host with the same label.
- **Host-installed runner (no container).** Slightly simpler setup. Trade-off: every job's state lands on the host filesystem; updates to the runner agent are manual; environment drift accumulates. Containerization gives daily-recycle bounded state for one extra Dockerfile.
- **Kubernetes-native runner orchestration** (`actions-runner-controller`). The right shape for ten-runner-plus deployments with autoscaling and HA. Way too heavy for the small-team / single-VPS case this toolkit targets.

## References

- GitHub docs: [Self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners)
- GitHub docs: [Security hardening](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)
- `actions/runner` releases: <https://github.com/actions/runner/releases>
