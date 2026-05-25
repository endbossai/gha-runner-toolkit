<!--
Thanks for the PR! Keep the body short — what + why + tests. Link
issues with "Closes #N" or "Refs #N" as appropriate.
-->

## Summary

<!-- 1–3 sentences. What does this change, and why? -->

## Type of change

- [ ] `feat:` — new feature
- [ ] `fix:` — bug fix
- [ ] `chore:` / `ci:` — tooling, deps, internal cleanup
- [ ] `docs:` — documentation only
- [ ] `refactor:` — code restructure, no behaviour change
- [ ] Breaking change (consumer must update their `image:` tag carefully — major bump)

## Test plan

- [ ] PR CI green (`hadolint`, `shellcheck`, `markdownlint`, `compose-validate`, `docker-build`)
- [ ] Manual smoke: `docker compose up -d` + `docker compose logs runner` reaches "Listening for Jobs"
- [ ] If changing `recycle.sh`: ran `sudo systemctl start recycle.service` against a real runner and verified `journalctl -u recycle.service` shows `recycle complete`

## Anything reviewers should pay extra attention to

<!-- Edge cases, things you considered then ruled out, places where the
reviewer should push back if they disagree with the approach. -->
