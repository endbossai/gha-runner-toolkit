# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| `1.x.y` (latest minor) | ✅ |
| `1.x` rolling tag | ✅ (resolves to latest 1.x.y) |
| `latest` rolling tag | ⚠️ Tracks `main`; no stability guarantees |
| Older than 1 minor behind | ❌ Please upgrade |

We typically backport security fixes to the latest minor only. Older minors get fixes if the upgrade path is materially broken; otherwise the upgrade itself is the fix.

## Reporting a vulnerability

**Do not open a public GitHub issue for security reports.**

Use GitHub's [private vulnerability reporting](https://github.com/endbossai/gha-runner-toolkit/security/advisories/new) — it lands in our security advisories inbox with no public disclosure.

What to include:

- Affected version (e.g. `1.0.0`)
- Reproduction steps or PoC if possible
- Impact assessment (what an attacker could do)
- Suggested mitigation if you have one

What to expect:

- Acknowledgement within ~3 business days
- Triage decision (accept / out-of-scope / dup) within ~7 business days
- For accepted reports: a coordinated disclosure timeline, typically ≤30 days for a fix release

We'll credit you in the release notes unless you'd rather stay anonymous.

## Threat model (what this toolkit is + isn't designed to defend against)

**In scope:**

- Supply-chain attacks on the base image, runner agent tarball, or bundled tooling. Mitigated by SHA-pinned base image digest + SHA256-verified runner tarball + SHA-pinned GitHub Actions in our own workflows + Trivy scan gate on publish.
- Stale-credential leaks via process env. Mitigated by `entrypoint.sh` unsetting `GITHUB_PAT` from the agent's env after registration; PAT stashed in a 0400 file readable only by the runner user.
- Drain-detection spoofing by a malicious workflow. Mitigated by `recycle.sh` using the GitHub API's `busy` field as the canonical signal (unforgeable from inside the workload); log-grep only as a fallback when the API is unreachable.

**Explicitly out of scope:**

- Workflows on **public repositories**. The Docker socket mount gives a workflow effective root on the host; on a public repo, anyone who can submit a PR can run code on your runner. This toolkit is for **private repos** where committers are trusted. Public-repo use requires additional hardening (rootless Docker, sandboxed containers, etc.) that this toolkit does not currently provide.
- Tenants on the same host. Multiple repos / multiple tenants sharing one runner is not a hardened isolation boundary. Use one runner per trust boundary.
- Host kernel exploits via Docker. Standard Docker-on-Linux security model applies; if you need stronger isolation, use a hypervisor-isolated host or look at gVisor / Kata.

## Disclosure history

No public advisories yet. See [advisories](https://github.com/endbossai/gha-runner-toolkit/security/advisories) for the canonical list when issued.
