# Runbook

Day-2 operations for the `gha-runner-toolkit` self-hosted runner. Use this when something's wrong or you're tuning behaviour.

Install + design context: [README](../README.md) + [architecture.md](architecture.md).

## Lifecycle in one diagram

```
┌──────────────────────────────────────────────────────────┐
│ Host (your-host)                                         │
│                                                          │
│  systemd: recycle.timer ─── daily 03:00 UTC ───┐         │
│                                                ▼         │
│                                          recycle.service │
│                                                │         │
│                                                ▼         │
│                                          recycle.sh      │
│                                          ┌─────┴─────┐   │
│                                          │ drain     │   │
│                                          │ (≤10 min) │   │
│                                          └─────┬─────┘   │
│                                                ▼         │
│  docker compose ─── runner container ──── compose down   │
│                       ├─ entrypoint.sh                   │
│                       ├─ ./config.sh    ◄── pull + up    │
│                       └─ ./run.sh       ◄── new agent    │
│                            │                             │
│                            ▼                             │
│                     long-poll GH API                     │
└────────────────────────────────────────────────────────┬─┘
                                                         │
                              ┌──────────────────────────┘
                              ▼
                         github.com
                         (jobs queue here)
```

## Daily routine

Nothing. The timer fires the recycle at 03:00 UTC every day.

**Once a week**: glance at `journalctl -u recycle.service --since="1 week ago"` to confirm seven clean recycles. Each entry should end with `recycle complete`.

## Diagnosing a stuck job

A workflow assigned to your runner label is sitting in "Queued" forever. Walk the chain:

1. **Is a runner registered + idle?**

   GitHub UI → repo Settings → Actions → Runners. Your runner (the name you set in `RUNNER_NAME`) should show "Idle". If it shows "Offline", the container isn't running on the host.

2. **Is the container alive on the host?**

   ```sh
   ssh host
   cd /opt/gha-runner-toolkit
   docker compose ps
   ```

   Should show `Up X (healthy)`. If "Restarting" loop, see step 4. If absent, see step 5.

3. **Is the agent process inside the container alive?**

   ```sh
   docker compose exec runner pgrep -x Runner.Listener
   ```

   Should print a PID. Because `entrypoint.sh` `wait`s on the agent PID and the compose service is `restart: unless-stopped`, the container exits when the agent dies and Docker brings it right back — usually inside a few seconds. If you catch the gap mid-flight, `docker compose ps` shows `Restarting`. If the loop persists, see step 4.

4. **Restart loop**

   ```sh
   docker compose logs --tail 100 runner
   ```

   Most common causes:
   - **Bad PAT** → log says `failed to mint registration token`. Generate a new PAT, update `.env`, `docker compose up -d`.
   - **Docker socket GID mismatch** → log says `permission denied` on `/var/run/docker.sock`. Re-discover the host's docker GID (see next section), pin it in `.env`, redeploy.
   - **Image pull failure** → `docker compose pull` shows the error. Network issue or the registry is rate-limiting you.

5. **Container is just gone**

   ```sh
   docker compose up -d
   ```

   Comes back from the registered state via entrypoint's `--replace` flag.

## Setting `DOCKER_GID` correctly

The runner container needs to be in the same Unix group as `/var/run/docker.sock` on the host, or it gets "permission denied" trying to talk to Docker. The right GID depends on the host:

| Host | Typical `DOCKER_GID` |
|---|---|
| Ubuntu / Debian VPS | `999` (sometimes `998`) |
| Docker Desktop on macOS | `0` (root-owned socket inside the Mac VM) |
| Docker Desktop on Windows | `0` (root-owned socket inside the WSL VM) |

Discover it from inside the container after a first failed start:

```sh
docker exec gha-runner stat -c '%g' /var/run/docker.sock
```

Set that number as `DOCKER_GID=` in `.env`, then `docker compose up -d --force-recreate`. Verify with `docker exec gha-runner docker ps` — should list containers, not fail with "permission denied".

## Ghost-session recovery

Symptom: container logs show `A session for this runner already exists. Runner connect error: Error: Conflict. Retrying until reconnected.` in a loop.

Cause: the previous container died (crash, force-kill, mid-job recycle) without acking GitHub-side. GitHub still tracks an active session for the runner name. `config.sh --replace` re-registers but doesn't break the existing session.

Recovery:

```sh
# 1. Find the orphan runner ID. GH UI shows it as the entry stuck at
#    "Online" + busy.
gh api repos/<owner>/<repo>/actions/runners \
    --jq '.runners[] | "\(.id) \(.name) \(.status) busy=\(.busy)"'

# 2. If busy=true and the local container is down, the runner is
#    "executing" a workflow run that no longer has a runner. Find the
#    in-flight run and cancel it — that frees the session.
gh run list --branch=<your-branch> --limit=10 --json databaseId,status \
    --jq '.[] | select(.status=="in_progress") | .databaseId' \
    | xargs -I{} gh run cancel {}

# 3. Wait ~30-60s for GH to ack the cancellation. The runner's
#    busy=true clears.

# 4. Once busy=false, delete the stale registration.
gh api -X DELETE repos/<owner>/<repo>/actions/runners/<id>

# 5. Bring the runner back up; entrypoint registers fresh.
docker compose up -d
```

If a runner is genuinely stuck `busy=true` for >5 minutes with no actual job to cancel, it's an orphan from GitHub's side. They time out after ~6 hours by default; if you can't wait, rename the runner (`RUNNER_NAME=<something-new>` in `.env`) and recreate — fresh registration bypasses the stuck name.

## Diagnosing a wedged recycle

Symptoms: `journalctl -u recycle.service` shows the last recycle didn't complete cleanly, or the container has been up for >24 hours.

```sh
# What happened last recycle?
journalctl -u recycle.service --since="36 hours ago"

# Is the timer armed?
systemctl list-timers recycle.timer

# Force a recycle now (won't fire again until next 03:00 UTC after this).
sudo systemctl start recycle.service
```

**Common recycle failures:**

- **Drain timeout** (`drain timeout reached after 600s`) — a job ran longer than the 10-minute drain ceiling. Recycle proceeded anyway and probably killed the job mid-flight. The job's PR shows a "cancelled" check. Re-run from the GitHub UI. Long-term: investigate why the job runs >10 min and tighten OR raise the drain timeout in `recycle.sh`.
- **`pull failed`** — recycle.sh logs this but continues with the cached image. Not fatal; just delays image-update cadence by one cycle.
- **`compose down` hangs** — container ignored SIGTERM. Manual: `docker kill gha-runner && docker compose up -d`.

## Adding a second runner

When a single runner becomes a uptime / queueing pain point:

1. Provision a second host (or use the same one with a different compose project).
2. Repeat the install with `RUNNER_NAME=<different-name>` in `.env`.
3. Same label — workflows distribute across both automatically.

Same-host second runner:

```sh
mkdir -p /opt/gha-runner-toolkit-2
cp /opt/gha-runner-toolkit/{docker-compose.yml,.env.example,recycle.sh} /opt/gha-runner-toolkit-2/
cd /opt/gha-runner-toolkit-2
cp .env.example .env
# edit .env: RUNNER_NAME=runner-2 (must be unique)
# edit docker-compose.yml: container_name: gha-runner-2 (must be unique)
docker compose -p runner-2 up -d
```

Two runner instances on one host. Cheap, but the SPOF-on-host concern stays.

## Adding tooling to the runner

A workflow needs a tool we didn't bake in (Rust, Python ≥ 3.12, custom CLI). Two paths:

1. **Quick & dirty** — install in the workflow step (`apt-get install ...` or use a setup-X action). Fine for one-off needs.
2. **Bake it in** — fork the toolkit's `Dockerfile`, add your tool, push the resulting image to your own registry, change your `docker-compose.yml`'s `image:` to point at it. Faster jobs (no per-run install) at the cost of growing the image and maintaining a fork.

Rule of thumb: if a tool is used by ≥3 jobs or runs ≥1×/day, bake it in.

## Security model — quick refresher

The container runs workflows with access to the host's Docker socket. **A bad workflow has effective root on the host via Docker.** The mitigation is the private-repo posture: only authorized committers can push PRs. If the repo ever goes public, the runner must be retired or restricted first (see architecture.md's negative consequences).

## Recovering from a compromised runner

If you have reason to believe the runner has been tampered with:

```sh
# 1. Take it offline immediately
docker compose down

# 2. Remove from GitHub (UI: Settings → Actions → Runners → ... → Remove)

# 3. Wipe state (host directory containing the runner, plus any caches)
sudo rm -rf /var/lib/docker/volumes/gha-runner-*  # if you bound any
docker system prune -af

# 4. Rotate the PAT (GitHub settings → Tokens → revoke the old one,
#    generate new)

# 5. Rebuild + re-register from a known-clean checkout
git fetch && git reset --hard origin/main
docker compose pull
docker compose up -d
```

Then file an incident note in your project tracker; consider whether any in-flight builds (and the artefacts they produced) need to be invalidated.

## See also

- [architecture.md](architecture.md) — foundational design and trade-offs
- [README.md](../README.md) — install + feature overview
- `actions/runner` upstream: <https://github.com/actions/runner>
