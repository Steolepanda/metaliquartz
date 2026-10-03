# Documentation-first reorganization and audit

- **Date:** 2026-09-25
- **Commit:** `8e45c05` (baseline) with a dirty working tree — see the "Tree state" section below
- **Machine:** Apple silicon Mac (`arm64`), macOS 27.0 (build 26A428), Xcode 27.0 (27A266a),
  Apple metal 32023.921, Python 3.9.6, `swift-format` main
- **Class:** automated
- **Scope:** build the maintained documentation tree, its structural gate, and the CI wiring; audit
  the docs against source; record defects without fixing them.

## What this run covers

This was a documentation and process change. **No product behaviour was altered**; the only
non-documentation edit was adding the documentation gate step to `Scripts/verify.sh` (which
preserves the pre-existing uncommitted changes to that file).

## Commands and results

| Command | Result |
| --- | --- |
| `xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests UITests` | exit 0, no findings |
| `python3 Documentation/qcgather/generate-swift-color-patches.py --check` | `up to date: Sources/Graph/QuartzComposerColorPatches.swift` |
| `Scripts/verify-docs` (before fixes) | exit 1 — 16 errors: registry rows used repo-root-relative paths the checker could not resolve |
| `Scripts/verify-docs --strict` (after fixes) | exit 0 — 0 errors, 0 warnings |
| `Scripts/verify-docs --json` | `{"markdownFiles": 37, "links": 24, "anchors": 2, "decisions": 16, "fixtures": 3, "errors": 0, "warnings": 0}`, `ok: true` |
| `Scripts/verify-docs` on the throwaway failure tree | exit 1, every required failure class reported (see `2026-09-25-docs-checker-proof.md`) |
| `Scripts/verify.sh` (full access) | Metal toolchain OK; lint OK; generated definitions "up to date"; **Debug build succeeded**; unit tests **`Executed 118 tests, with 0 failures`**; the 2 UI journeys failed; `** TEST FAILED **`, so the Release build step did not run |
| `xcodebuild … -only-testing:MetaliquartzTests test` (full access) | `** TEST SUCCEEDED **`, `Executed 118 tests, with 0 failures (0 unexpected) in 7.591 (7.705) seconds` |

The per-suite result of the unit run, quoted:

```
AlphaHardeningTests                 6 tests, 0 failures
CompositionModelTests               7 tests, 0 failures
FeedbackTests                       6 tests, 0 failures
GeometryRendererTests               4 tests, 0 failures
GraphEditingTests                   3 tests, 0 failures
GraphRuntimeTests                   6 tests, 0 failures
ImageEffectsTests                   6 tests, 0 failures
LegacyInterfaceAndImportTests       8 tests, 0 failures
LiveControlIntegrationTests         5 tests, 0 failures
LiveSessionTests                    8 tests, 0 failures
MIDIIntegrationTests                3 tests, 0 failures
MacroGraphTests                     7 tests, 0 failures
MediaSourcesTests                   3 tests, 0 failures
MetalImageRendererTests             6 tests, 0 failures
MetalPreviewRendererTests           3 tests, 0 failures
OSCIntegrationTests                 5 tests, 0 failures
QCColorPatchTests                  16 tests, 0 failures
QuartzComposerCatalogTests          3 tests, 0 failures
QuartzComposerNestedGraphTests      3 tests, 0 failures
QuartzComposerPreferenceTests       2 tests, 0 failures
QuartzComposerRuntimeTests          4 tests, 0 failures
SyphonIntegrationTests              3 tests, 0 failures
SyphonVendorModificationTests       1 test,  0 failures
MetaliquartzTests.xctest          118 tests, 0 failures
** TEST SUCCEEDED **
```

### The two UI journeys failed

`Scripts/verify.sh` reported:

```
Failing tests:
	GoldenAuthoringJourneyUITests.testLegacyGoldenAuthoringJourney()
	GoldenAuthoringJourneyUITests.testModernGoldenAuthoringJourney()
** TEST FAILED **
```

The overall test action reported `Executed 118 tests, with 0 failures` for the unit bundle and
`Executed 2 tests, with 6 failures (0 unexpected) in 320.320 seconds` for the UI bundle. Extracting
the result bundle (`/tmp/mq-final.xcresult`) gave the exact failure — the same assertion three
times per journey:

```
Test Case | testLegacyGoldenAuthoringJourney()
  Failure Message | XCTAssertEqual failed: ("XCTWaiterResult(rawValue: 2)") is not equal to ("XCTWaiterResult(rawValue: 1)")
Test Case | testModernGoldenAuthoringJourney()
  Failure Message | XCTAssertEqual failed: ("XCTWaiterResult(rawValue: 2)") is not equal to ("XCTWaiterResult(rawValue: 1)")
```

`rawValue 2` is `XCTWaiterResult.timedOut` and `rawValue 1` is `.completed`, so all six failures are
wait-for-UI-element timeouts (each journey waits up to 5–10 s for identifiers such as
`mq.preview.status` and never sees them). There is no assertion about wrong values. Both journeys
require an unlocked, logged-in GUI desktop session with WindowServer access and developer tool
automation; they drive real keystrokes and system Save/Open panels. This session is not an
interactive GUI session, so the failure is attributed to the environment, not the product, **but it
was not confirmed either way against a real desktop session**. The two journeys therefore remain
unverified (finding D18), and the Release step of `Scripts/verify.sh` did not run because the script
stops on the first failure.

The result bundle also records one device/configuration: `My Mac`, MacBook Air, arm64, macOS 27.0
(build 26A428).

### The code gate was initially blocked

Inside the file-sandboxed session, `Scripts/verify.sh` failed at the Debug build:

```
error: unable to open output file '/var/folders/.../C/clang/ModuleCache/.../metal_types-....pcm': 'Operation not permitted'
<built-in>:1:10: fatal error: could not build module 'metal_types'
** BUILD FAILED **
```

The Metal compiler writes its clang module cache to `/var/folders/.../ModuleCache`, outside the
workspace, which the sandbox denies. `CLANG_MODULE_CACHE_PATH`, `MODULE_CACHE_DIR` and a `TMPDIR`
override were each tried and the compiler still targeted that path. A direct
`xcrun -sdk macosx metal -fmodules-cache-path=/tmp/... -c` succeeded, confirming the module cache
is the sole blocker. The same command then succeeded with full filesystem access, which also
triggered `swift-plugin-server` macro failures (`ObservationMacros`, `SwiftUIMacros`) until full
access was granted. Both blockers are environmental.

## Observations

- Documentation tree created: `AGENTS.md`, `wiki/` (README, CURRENT_STATE, PROJECT_MAP,
  architecture, 5 system pages, 2 manual pages, roadmap, changelog, 16 decisions, evidence),
  `docs/verification/` (README, fixtures manifest, one derived fixture), and
  `Scripts/verify-docs`.
- Documentation corrections made: the test inventory is enumerated (118 unit + 2 UI = 120); the
  "graph/audio" claim is corrected to "no audio engine"; the QC catalog is documented as
  reconstructed reference data; the "fullscreen" output is documented as a borderless window;
  `PROJECT_STATUS.md` is marked superseded.
- **Suite-name correction found by running the tests:** `Tests/QuartzComposerMilestoneTests.swift`
  declares five `XCTestCase` classes (`QuartzComposerCatalogTests`,
  `QuartzComposerNestedGraphTests`, `QuartzComposerPreferenceTests`, `QuartzComposerRuntimeTests`,
  `SyphonVendorModificationTests`), so `xcodebuild` reports five suites for one file. The first
  draft of `PROJECT_MAP.md` listed a suite named `QuartzComposerMilestoneTests`, which does not
  exist. The test inventory and the owning system pages were corrected, and `AGENTS.md` now warns
  that suite names do not map one-to-one to file names.
- Sixteen defects (D1–D17) and four risks (R1–R4) recorded in `../wiki/CURRENT_STATE.md`. None was
  fixed in this change.
- The pre-existing uncommitted changes to `Sources/`, `Tests/`, `Scripts/`, `README.md` and the
  Xcode project were preserved.

## Tree state

Uncommitted before this session and left untouched by it (from `git status` at the start):
`Metaliquartz.xcodeproj/project.pbxproj`, `Metaliquartz.xcodeproj/xcshareddata/xcschemes/Metaliquartz.xcscheme`,
`README.md`, `Scripts/soak-test.sh`, `Scripts/verify.sh`, `Sources/App/InterfacePreferences.swift`,
`Sources/Editor/EditorShellView.swift`, `Sources/Editor/GraphCanvasView.swift`,
`Sources/Graph/GraphRuntime.swift`, `Sources/Graph/LegacyPatchCatalog.swift`,
`Sources/Graph/PatchDescriptor.swift`, `Sources/Renderer/MetalPreviewView.swift`,
`Tests/MetalImageRendererTests.swift`, plus the untracked `PROJECT_STATUS.md`, the new
`Sources/Graph/QCColorMath.swift`, `Sources/Graph/QuartzComposerColorPatches.swift`,
`Tests/QCColorPatchTests.swift` and `UITests/`.

This reorganization added `AGENTS.md`, `wiki/`, `docs/`, `.github/workflows/docs.yml`,
`Scripts/verify-docs`, and edited `README.md`, `Scripts/verify.sh` and `PROJECT_STATUS.md`.

## Not checked

- **The UI journeys (2)** — they failed in this environment; not confirmed against a real GUI
  desktop session.
- **The Release build** — `Scripts/verify.sh` stopped at the UI-test failure, so it never ran.
- **Archive, signature, notarization** — never run; no developer identity is configured
  (`DEC-0006`).
- **Soak run** — never run.
- **Physical-device paths** — camera capture, movie playback, physical MIDI, Syphon against a
  second application, real-network OSC, and fullscreen output on a target display were not
  exercised.
- **Platform matrix** — only this machine (macOS 27.0, arm64) was used; the macOS 14 floor is
  asserted by `Config/Base.xcconfig`, not verified.
- **Case-sensitive filesystem behaviour** — this volume is case-insensitive HFS+, so the
  `Scripts/` vs `scripts/` path handling was not exercised on a case-sensitive filesystem.
