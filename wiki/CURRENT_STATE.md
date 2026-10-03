# CURRENT_STATE — Metaliquartz

> Last reviewed: 2026-10-03
> Reviewer: public source-package audit (see `evidence/2026-10-03-public-source-package.md`)
> This page is the operational handoff. History lives in `changelog/CHANGELOG.md` and
> `evidence/`.

## Health, phase, target

- **Health:** 🟡 Needs attention — lint, Debug build and all 118 unit tests pass and are recorded,
  but the two UI journeys are unconfirmed, and the Release, archive and soak gates have never run.
- **Phase:** Stabilization. **Target:** alpha verification and soak/release gate.
- **Done means:** lint, Debug build, 120 tests (including the two GUI journeys), Release build,
  alpha archive with signature check, and the two-hour soak all pass on a supported Mac.

## What is true now

- Apple-silicon-only Swift 6 macOS app, Xcode project with three targets (app, `MetaliquartzTests`,
  `MetaliquartzUITests`) and one shared scheme. No SwiftPM manifest.
- Test inventory, verified by running: **118 unit test methods** (all passing on 2026-09-25) across
  19 files in `Tests/`, plus **2 UI journeys**. Note `Tests/QuartzComposerMilestoneTests.swift`
  declares five `XCTestCase` classes, so suite names do not map one-to-one to file names.
- Graph engine is real and tested: versioned `.mquartz` codec (v0/v1→v2), validator, macro
  expansion, Kahn-ordered compiler, per-frame control evaluator, 4 096 iterator budget.
- Renderer is real GPU work: Metal preview, Core Image effects, custom Metal shaders, four
  geometry pipelines, feedback store, pooled textures, diagnostics.
- Live control works end to end for MIDI (CoreMIDI/UMP), OSC 1.0 inbound, and Syphon Metal
  client/server. All are main-actor driven.
- No audio engine, no `.qtz` importer, no recording, no screen capture. The README's
  "graph/audio" phrase overstates the audio side.
- The Quartz Composer catalog is a reconstructed reference library: `functional` rows are
  addable, `catalogOnly` rows are searchable/inspectable only, two OpenCL rows are marked
  deprecated.
- Documentation is now a maintained tree (`wiki/`, `docs/verification/`) with a structural gate
  (`Scripts/verify-docs`). A green docs gate proves structure only, never runtime agreement.

## Verification snapshot

| Check | State | Evidence |
| --- | --- | --- |
| `swift-format lint --strict` over `Sources Tests UITests` | ✅ pass, 0 findings | `evidence/2026-09-25-reorganization.md` |
| Generated QC definitions (`generate-swift-color-patches.py --check`) | ✅ pass, "up to date" | same |
| Debug build | ✅ pass (needs a non-sandboxed session — see the environment blocker) | same |
| Unit tests (118) | ✅ pass, `Executed 118 tests, with 0 failures` | same |
| UI tests (2 golden journeys) | ❌ 6 failures, all `XCTWaiterResult` timeouts (`.timedOut` waiting for UI elements); needs an unlocked GUI session — **unconfirmed on a real desktop** (D18) | same |
| Release build | ⛔ did not run — `Scripts/verify.sh` stops at the UI-test failure | — |
| Alpha archive + signature | ⛔ never run | — |
| Two-hour soak | ⛔ never run | — |
| Docs structure (`Scripts/verify-docs --strict`) | ✅ pass, 0 errors / 0 warnings on 2026-10-03 | `evidence/2026-10-03-public-source-package.md` |
| Public source snapshot / privacy regressions | ✅ package scan passes; 9 scanner tests pass; original history remains blocked | same |

Jump to the [known problems](#known-problems-and-risks) or the [next actions](#next-actions).

## Public source publication

- A source package can be prepared with `python3 Scripts/prepare-github-package.py`. It includes
  current working-tree source and maintained docs, excludes original Git history and local
  reference material, and performs privacy, docs, generated-definition and ZIP integrity checks.
- **Do not push the original history:** reachable commits include local upstream binaries over
  10 MiB and the original scanner's personal contact address. Two local reference documents are
  still tracked despite the new `Documentation/` ignore rule. They are excluded from the package;
  local inputs and original history are preserved. Publish from a fresh extracted source tree.
- GitHub privacy and structural CI are configured, but have not run remotely. No upload occurred.

## Next actions

1. Run `Scripts/verify.sh` on an unlocked Mac desktop session outside the restricted sandbox and
   record the result in a new `evidence/` page, including the test count from the log.
2. Run `Scripts/archive-alpha.sh /tmp/MetaliquartzAlpha` and record the archive path, the
   `codesign --verify` result and the ZIP SHA-256.
3. Run the two-hour soak against a saved **Live Camera Feedback** composition and record the CSV
   plus the in-app diagnostics export.
4. Record the supported-OS/device matrix as a decision record (currently only "macOS 14+,
   arm64" is asserted in `Config/Base.xcconfig`).
5. Decide the alpha distribution target (personal vs wider) — this is the open owner question
   carried over from `PROJECT_STATUS.md`; it gates signing/notarization work.
6. Fix or explicitly accept the known problems below, each as its own bounded change with its
   paired docs and a test where possible.

## Blockers

- No hard blocker in the code.
- **Release-authority blocker:** Developer ID signing and notarization are deliberately absent;
  an alpha ZIP is ad hoc signed only. Any distribution beyond the author's machine needs a
  certificate, a team, entitlements and notarization — none of which exist yet.
- **Environment blocker:** a file-sandboxed session cannot write the Metal compiler's clang
  module cache outside the workspace, so `Scripts/verify.sh` fails at the Debug build with
  `could not build module 'metal_types'`. This is an environment limitation, not a code defect;
  run the gate non-sandboxed.

## Known problems and risks

Defects found during the reorganization audit. None were fixed here — each needs its own
bounded change (rule: record, do not silently fix).

| # | Finding | Path | Severity |
| --- | --- | --- | --- |
| D1 | `EditorSession.isImportingImages` is written but never read (dead state) | `Sources/Editor/EditorShellView.swift` | low |
| D2 | No `NSLocalNetworkUsageDescription` while an inbound OSC UDP listener exists; macOS local-network privacy may block or misreport it | `Sources/Resources/Info.plist` | medium |
| D3 | `CameraFrameSource.startIfNeeded` sets `hasStarted = true` before authorization/configuration, so a denied or failed start never retries and a late `requestAccess` callback can start the session after `stop()` | `Sources/Media/MediaSources.swift` | medium |
| D4 | `MIDIInputService.retiredContexts` retains disconnected `SourceContext` pointers until `stop()`; memory grows with endpoint churn | `Sources/Integrations/MIDIIntegration.swift` | low |
| D5 | Only the first `cameraImage` node is honoured; extra camera nodes silently share one session | `Sources/Media/MediaSources.swift` | low |
| D6 | Movie sources are keyed by asset ID, so nodes sharing an asset share one player and the last iterated node's `loop` value wins | `Sources/Media/MediaSources.swift` | low |
| D7 | `EmbeddedMediaCache` never evicts and will not rewrite changed bytes for the same asset ID + extension | `Sources/Media/MediaSources.swift` | low |
| D8 | Malformed OSC datagrams are dropped with `try?` and leave no diagnostic | `Sources/Integrations/OSCIntegration.swift` | low |
| D9 | `advanceSmoothing(by:)` has no production caller; production smoothing uses wall-clock deltas, not frame deltas | `Sources/Integrations/LiveControlIntegration.swift` | low |
| D10 | `PublishedParameterMapper` / `PublishedParameterSmoother` in `LiveSession.swift` are referenced only by tests | `Sources/Editor/LiveSession.swift` | low |
| D11 | `diagnosticReport` hardcodes `Architecture: arm64` | `Sources/App/ApplicationHealth.swift` | low |
| D12 | Autosave task is keyed only on `document.composition`, so an assets-only mutation does not reschedule the snapshot | `Sources/Editor/EditorShellView.swift` | low |
| D13 | No test covers `PermissionGuidance`, `CameraFrameSource` or `MovieFrameSource` | `Sources/Integrations/PermissionGuidance.swift`, `Sources/Media/MediaSources.swift` | medium |
| D14 | No test covers the 4 096 evaluation budget or container nesting depth | `Sources/Graph/GraphRuntime.swift` | low |
| D15 | The advertised "fullscreen" output is a borderless window at screen size, not native `NSWindow` fullscreen | `Sources/Editor/LiveSession.swift` | informational |
| D16 | `TexturePool` is unbounded and keyed only by size/format; distinct resolutions accumulate until the pool is dropped | `Sources/Renderer/MetalImageRenderer.swift` | low |
| D17 | `README.md` requirements say "Xcode 26.3 or newer"; the verified toolchain here is Xcode 27.0. The floor is unverified | `README.md` | informational |
| D18 | The two golden UI journeys fail in a non-GUI environment and cannot self-skip, so they will fail any headless CI runner. They are also unconfirmed on a real desktop session | `UITests/GoldenAuthoringJourneyUITests.swift` | medium |

Risk register (not defects):

- **R1 — Realtime behaviour is unmeasured.** No frame-time/fps acceptance run exists outside the
  in-app counters; the 60 fps / p95 / dropped-frame thresholds in
  `manual/release-runbook.md` are goals, not recorded results.
- **R2 — Device-dependent paths are untested.** MIDI hardware, camera capture, Syphon peers and
  screen-recording states can only be exercised on a real machine with an unlocked session.
- **R3 — Two filesystem/CI assumptions.** The docs checker and the Xcode build behave
  differently under a case-sensitive filesystem (none of this repo's machines) and under a
  headless CI runner (UI tests fail rather than skip).
- **R4 — Catalog drift.** New probes still depend on local framework inputs. Existing colour
  definitions can now be regenerated and checked using the public six-patch schema fixture and
  `Scripts/generate-swift-color-patches.py`; the full private capture is not required.

## Pointers

- Documentation map and ownership: `PROJECT_MAP.md`
- Architecture: `architecture/overview.md`
- Roadmap and deferred work: `roadmap/ROADMAP.md`
- Change history: `changelog/CHANGELOG.md`
- Decisions: `decisions/README.md`
- How to verify and how to report: `../docs/verification/README.md`
- The pre-existing portfolio audit this page supersedes as the handoff: `../PROJECT_STATUS.md`
  (kept for history; its `PORTFOLIO_CONFIG.md` source does not exist in this repository).
