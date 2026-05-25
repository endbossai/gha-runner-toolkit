# Contributing

Thanks for considering a contribution. This is a small, opinionated tool — happy to take improvements that fit the scope, candid about feature requests that don't.

## Scope

This toolkit targets the **small-team / single-VPS** case. Concretely that means:

- 1–3 self-hosted runners per repo, one or two repos per host
- Operators who can edit a `.env`, run `docker compose up -d`, and read a `journalctl` log
- Trade-offs that favour clarity + transparency over feature breadth (`--disableupdate`, no auto-magic image bumps, single Dockerfile, etc.)

**Out of scope:**

- Kubernetes-native runner orchestration ([`actions-runner-controller`](https://github.com/actions/actions-runner-controller) is the right tool)
- Autoscaling, ephemeral-per-job runner pools (same)
- GUI configuration, web dashboards
- Anything that requires the toolkit to know about the host's package manager beyond what's documented

If a feature request would push us toward those areas, we'll close the issue with a pointer rather than absorb the complexity.

## Reporting an issue

[Open an issue](https://github.com/endbossai/gha-runner-toolkit/issues/new/choose). The templates ask for what we typically need to triage — toolkit version, host OS, container logs, what you tried. Skip fields that don't apply, but more context = faster turnaround.

**Security issues**: do **not** open a public issue. See [SECURITY.md](SECURITY.md) for the disclosure process.

## Proposing a change

Small, focused PRs are easiest to land. If the change is non-trivial, open an issue first to align on the approach — saves both sides time on a rejected PR.

### Code conventions

- **Shell scripts** use `bash` and pass `shellcheck` (the PR workflow enforces this).
- **Dockerfile** passes `hadolint` (ditto).
- **Markdown** passes `markdownlint-cli2` against `.markdownlint.json` if present, or the defaults.
- **GitHub Actions** in this repo's own workflows are SHA-pinned with a trailing `# vX.Y.Z` comment, per the supply-chain hygiene the toolkit itself preaches. Dependabot handles bumps.
- **Comments** explain *why*, not *what*. The diff shows what; the comment should justify a non-obvious choice or warn about a footgun.

### Local testing

```sh
# Validate the compose file
echo 'GITHUB_PAT=x
GITHUB_OWNER=x
GITHUB_REPO=x
RUNNER_NAME=x
RUNNER_LABELS=x
DOCKER_GID=999' > .env
docker compose config --quiet

# Lint everything the PR CI lints
docker run --rm -i hadolint/hadolint < Dockerfile
docker run --rm -v "$PWD":/mnt koalaman/shellcheck *.sh
npx --yes markdownlint-cli2@0.22.1 '**/*.md' '!**/node_modules'

# Smoke build
docker compose build
```

### Commit + PR convention

- Title: `<type>: <imperative subject>` — `feat`, `fix`, `chore`, `docs`, `ci`, `refactor`, `test`.
- Body: explain *why* the change is happening, what trade-offs were considered, what tests prove it works.
- Squash-merge to `main`. PRs auto-rebase if you want; we prefer a clean linear history.

## Release process

Maintainers only:

1. Land changes on `main` via PR.
2. Decide the version bump (semver per [README §Versioning](README.md#versioning)).
3. `git tag vMAJOR.MINOR.PATCH && git push --tags`.
4. The publish workflow fires: builds, Trivy-scans, publishes to GHCR.
5. Verify pull works against the new tag.
6. Create a GitHub Release if the change warrants release notes (most do).

## License

By contributing, you agree your contribution will be licensed under [Apache 2.0](LICENSE) — same as the rest of the project.
