# Changelog

History of changes to Metaliquartz and its documentation. Newest first. Verification detail lives
in `../evidence/`; this page records *what changed*, not *what passed*.

## 2026-10-03 — public GitHub source package

- Added an allowlist-based source ZIP preparer, SHA-256 and per-file hash manifest under ignored
  `dist/github/`; no upload, index mutation or history rewrite occurs.
- Expanded the privacy gate to prospective untracked files, staged contents, reachable blobs and commit metadata,
  with redacted findings, credential/signing/path checks and PNG metadata review. Removed the
  personal contact address from the scanner source. Added nine synthetic privacy regressions.
- Ignored local reference captures, signing files and Python caches; preserved the local inputs.
- Copied the generator into maintained `Scripts/` and added a hash-guarded six-patch schema fixture.
  The generated Swift bytes and runtime behavior are unchanged; a clean source export needs no
  private capture to check them. Python 3 is now required by the code gate.
- GitHub's workflow fetches full history and runs the publishing gate before the docs check.
- Recorded the source snapshot boundary in DEC-0017. The original repository still fails the
  publishing gate; prepare a fresh repository from the ZIP instead of pushing old history.

## 2026-09-25 — documentation-first reorganization

Process and documentation change; **no product behaviour was altered.**

### Added

- `AGENTS.md` — engineering constraints by domain, the 4-step handoff loop, sources-of-truth and
  documentation-obligations tables, and the verification commands.
- `wiki/` — `README.md`, `CURRENT_STATE.md`, `PROJECT_MAP.md`, and `architecture/`, `systems/`,
  `manual/`, `roadmap/`, `changelog/`, `decisions/`, `evidence/` trees.
- `docs/verification/` — evidence classes, the evidence template, and `fixtures.json`.
- `Scripts/verify-docs` — a stdlib-only structural checker for maintained Markdown (links,
  anchors, decision registry, fixture hashes).
- `.github/workflows/docs.yml` — runs the docs gate on push and pull request.

### Changed

- `README.md` trimmed to a short entry point plus a documentation map; the architecture,
  MIDI/OSC, alpha-hardening, archive/soak and distribution sections moved to `wiki/manual/` and
  `wiki/systems/` with links back.
- `Scripts/verify.sh` documented as the single code gate in `AGENTS.md` and
  `docs/verification/README.md`; the script itself was not modified by this change.

### Documented corrections

- The test inventory is recorded as **enumerated and run-confirmed** counts: 118 unit test methods
  in 19 files (all passing) plus 2 UI test methods (120 total), not a prose approximation.
- `Tests/QuartzComposerMilestoneTests.swift` declares **five** `XCTestCase` classes, so `xcodebuild`
  reports five suites for one file. A first draft of `PROJECT_MAP.md` named a suite
  `QuartzComposerMilestoneTests`, which does not exist; the inventory and the owning system pages
  were corrected. `AGENTS.md` now warns that suite names do not map one-to-one to file names.
- The README's "graph/audio" wording is corrected: there is no audio engine.
- The catalog is documented as a reconstructed reference library with `catalogOnly` and
  deprecated rows, not a full QC runtime.
- `PROJECT_STATUS.md` is superseded as the operational handoff by `wiki/CURRENT_STATE.md`. It is
  kept for history and marked as such; its `PORTFOLIO_CONFIG.md` source does not exist in this
  repository, so the portfolio YAML it contains cannot be regenerated here.
- Documented that the advertised "fullscreen" output is a borderless window, not native
  fullscreen (D15).

### Verified in this change

- `swift-format lint --strict` and the generated-definition check pass; the Debug build succeeds;
  all **118 unit tests pass** (`Executed 118 tests, with 0 failures`).
- The two golden UI journeys fail in the non-GUI session with six wait-for-element timeouts
  (`XCTWaiterResult.timedOut`); they are recorded as unverified, not as a product failure (D18).
- `Scripts/verify-docs --strict` passes with 0 errors and 0 warnings across 38 Markdown files,
  16 decisions and 3 fixtures.

### Recorded (not fixed)

Sixteen defects and four risks, listed in `../CURRENT_STATE.md`. Each needs its own bounded
change; none were fixed in this reorganization.

## Before 2026-09-25

The repository history before this date is the feature log, not a maintained changelog. Use
`git log --oneline` for it. Highlights as of the reorganization baseline commit:

- `Add Quartz Composer fidelity milestone` — reconstructed catalog, colour patches, generated
  definitions.
- `Add legacy editor workspace and image import` — dual interface, drag-and-drop assets.
- `Harden the live-use alpha` — recovery snapshots, health log, diagnostics export.
- `Add MIDI and OSC live control` — CoreMIDI and OSC 1.0 inbound.
- `Add Metal-only Syphon integration`, `Add nested reusable graph macros`,
  `Add live-session performance workflow`, `Add deterministic frame feedback`,
  `Add GPU geometry renderers`, `Add live Metal effects and custom shaders`,
  `Add movie and camera Metal sources`, `Render embedded image graphs with Metal`,
  `Add deterministic control graph runtime`, `Build editable graph canvas`,
  `Add versioned composition documents`, `Bootstrap Metaliquartz macOS project`.
