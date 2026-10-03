---
id: DEC-0006
status: accepted
date: 2026-09-25
---

# Ad hoc signing and hardened runtime for the personal alpha

## Context

Metaliquartz is developed as a personal instrument. Requiring a paid Developer ID certificate and a
notarization round trip for every local build would slow the edit-run loop, and the alpha is not
intended for general distribution yet. Release builds should still be hardened.

## Decision

- Development and Release builds sign ad hoc (`CODE_SIGN_IDENTITY = -`,
  `CODE_SIGN_STYLE = Manual`), with **no** `DEVELOPMENT_TEAM` in the repository.
- Release builds enable the hardened runtime (`ENABLE_HARDENED_RUNTIME = YES`).
- `Scripts/archive-alpha.sh` produces an archive, verifies the signature with
  `codesign --verify --deep --strict`, and emits a ZIP plus SHA-256.
- Developer ID signing and notarization are explicitly out of scope; distributing beyond the
  author's machine requires a new decision record and the corresponding certificate, team,
  entitlements and notarization run.

## Consequences

- Local builds need no Apple account and no provisioning profile.
- Anyone else opening the ZIP sees a Gatekeeper warning, because the app is not notarized. This is
  expected and must not be described as a bug or as "signed for distribution".
- `Scripts/public-preflight.sh` fails the publishing gate if a development team or personal email
  appears in the tree or in reachable history.
- Platform updates that require entitlements cannot ship until the signing story changes.
