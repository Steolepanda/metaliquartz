---
id: DEC-0014
status: accepted
date: 2026-09-25
---

# Quartz Composer colour definitions are generated from a captured framework probe

## Context

The `Utility > Color` patch set has exact port keys, display names, defaults, menu entries and
number ranges that Quartz Composer defines. Transcribing them by hand invites silent drift, and the
project already has a probe harness (`Documentation/qcgather/`) that reads the real port signature
off a live instance.

## Decision

Generate `Sources/Graph/QuartzComposerColorPatches.swift` with
`Scripts/generate-swift-color-patches.py` from the public six-patch subset
`docs/verification/fixtures/qc-color-generation-schema.json`. The original provenance remains
`Documentation/qc-reference/meta/builtin-ports.json`; its probe harness stays local:

- Generated: names, summaries, port keys, display names, defaults, menu entries, number ranges.
- Not generated: behaviour. Each generated patch names a `PatchExecutorKind` case implemented by
  hand in `GraphRuntime` on top of `QCColorMath`, because the framework publishes a patch's shape
  but not its arithmetic.
- `Scripts/verify.sh` runs the generator with `--check`, so a hand edit or a stale capture fails
  the gate rather than drifting silently.

## Consequences

- Port fidelity is mechanical; the Swift file must not be hand-edited, and a change to it belongs
  in the generator or the capture.
- Behaviour can still drift from Quartz Composer even when the ports match; `QCColorMath` is
  validated against framework probes by `Tests/QCColorPatchTests.swift`.
- Since 2026-10-03, the public hash-guarded schema and generator reproduce the exact existing
  Swift bytes without the private full capture; generated headers retain historical provenance.
- Python 3 is required; the verification gate fails if it is unavailable.
