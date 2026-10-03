# PROJECT_MAP — source map and documentation ownership

Two maps live here. The first answers "what is this directory?". The second is the
**change-review checklist**: before you change a sensitive path, the right-hand columns name the
documents that must move with it and the tests or scripts that prove it.

Line counts are approximate and drift; treat the paths and symbols as the source of truth.

## Source map

| Area | Path | Responsibility | System page |
| --- | --- | --- | --- |
| App lifecycle and commands | `Sources/App/` | `@main` scene, document group, settings, interface preferences, launch markers and the health log | `systems/documents-and-editor.md` |
| Documents and codec | `Sources/Documents/` | `.mquartz` package read/write, sample compositions, versioned JSON codec | `systems/documents-and-editor.md` |
| Editor and UI | `Sources/Editor/` | SwiftUI shell, AppKit graph canvas, inspector, live-session panel, image-drop import, recovery store, rotary faders | `systems/documents-and-editor.md` |
| Graph model and runtime | `Sources/Graph/` | Records, validator, codec, editing commands, macros, patch registry/catalog, compiler, per-frame evaluator | `systems/graph-runtime.md` |
| Media sources | `Sources/Media/` | Movie and camera frames as `MTLTexture`s via AVFoundation and `CVMetalTextureCache` | `systems/live-control-and-media.md` |
| Integrations | `Sources/Integrations/` | CoreMIDI input, OSC UDP listener/decoder, Syphon Metal bridge, permission guidance | `systems/live-control-and-media.md` |
| Renderer | `Sources/Renderer/` | Metal frame encoder, effects, geometry, feedback store, preview view, diagnostics, shaders | `systems/renderer.md` |
| Resources | `Sources/Resources/` | `Info.plist`, asset catalog, app icon | `systems/documents-and-editor.md` |
| Unit tests | `Tests/` | 19 XCTest suites, 118 test functions | per system page |
| UI tests | `UITests/` | 2 golden authoring journeys (modern + legacy) | `systems/documents-and-editor.md` |
| Product scripts | `Scripts/` | Verification, alpha archive, soak test, public preflight, and the docs checker | `../../AGENTS.md` |
| Build configuration | `Config/*.xcconfig` | Platform, concurrency, signing, sandbox, hardening | `architecture/overview.md` |
| Xcode project | `Metaliquartz.xcodeproj/` | 3 targets (app, unit tests, UI tests), shared scheme | `architecture/overview.md` |
| Vendored dependency | `Vendor/Syphon/` | Syphon 5, commit `71351d4b…`, BSD | `systems/live-control-and-media.md` |
| Brand input | `Design/References/` | Source artwork | `manual/getting-started.md` |
| Reference material (untracked) | `Documentation/` | Upstream QC material, QC framework captures and original probe tools. Read-only; excluded from public packages | `systems/graph-runtime.md` |
| Release-safety backups (git-ignored) | `.private/` | History bundles, extracted framework, reference image | `../../AGENTS.md` |

Generated or ignored artifacts: `.build/`, `DerivedData/`, `*.profraw`, `*.xcresult`, `.DS_Store`,
`Documentation/qc-reference/` (local probe output), `dist/` (public package output), `__pycache__/`.
The public generator consumes `docs/verification/fixtures/qc-color-generation-schema.json`.

## Test inventory

Counted from the working tree with
`for f in Tests/*.swift UITests/*.swift; do grep -cE '^\s*(@MainActor\s+)?func test' "$f"; done`
— 120 test methods total (118 unit + 2 UI), and confirmed against a real run: `xcodebuild …
-only-testing:MetaliquartzTests test` reported **`Executed 118 tests, with 0 failures`**.

Important: a test **file** is not a test **suite**. `Tests/QuartzComposerMilestoneTests.swift`
declares five `XCTestCase` classes, so `xcodebuild` reports five suites for it. The table below is
per suite, with the owning file named. Re-derive both when a suite changes.

| Suite (file) | Tests | Protects |
| --- | --- | --- |
| `AlphaHardeningTests` (`Tests/AlphaHardeningTests.swift`) | 6 | Health log, unclean launch, corrupted packages, samples, recovery enumeration, diagnostics p95, canvas accessibility |
| `CompositionModelTests` (`Tests/CompositionModelTests.swift`) | 7 | Codec round-trip, v0 migration, version rejection, validator rules, feedback boundary, package layout |
| `FeedbackTests` (`Tests/FeedbackTests.swift`) | 6 | Feedback as the only cycle boundary, store reuse/resize/reset, one-frame delay |
| `GeometryRendererTests` (`Tests/GeometryRendererTests.swift`) | 4 | Geometry port definitions, pipeline compilation, GPU coverage, 1080p submission |
| `GraphEditingTests` (`Tests/GraphEditingTests.swift`) | 3 | Undo of node removal, input-connection replacement, clipboard reidentification |
| `GraphRuntimeTests` (`Tests/GraphRuntimeTests.swift`) | 6 | Topological order, deterministic evaluation, frame context, smooth state, unknown patches, invalid graph |
| `ImageEffectsTests` (`Tests/ImageEffectsTests.swift`) | 6 | Shader metadata cap, last-valid-pipeline, color controls/invert, gradient crop, shader round-trip |
| `LegacyInterfaceAndImportTests` (`Tests/LegacyInterfaceAndImportTests.swift`) | 8 | Interface choice, legacy panels, frame clamping, drop validation, multi-image layout, asset GC, macro-local import |
| `LiveControlIntegrationTests` (`Tests/LiveControlIntegrationTests.swift`) | 5 | MIDI range mapping, MIDI learn, OSC default addresses, smoothing, mapping round-trip |
| `LiveSessionTests` (`Tests/LiveSessionTests.swift`) | 8 | v1 live settings, published params/presets, clamping, frame-rate-independent smoothing, recovery, diagnostics, resolution, fullscreen state |
| `MIDIIntegrationTests` (`Tests/MIDIIntegrationTests.swift`) | 3 | UMP parsing, device/channel/message filters, virtual source delivery |
| `MacroGraphTests` (`Tests/MacroGraphTests.swift`) | 7 | Macro conversion equivalence, nested flattening, recursion rejection, metadata diagnostics, layout, macro shader dir, macro GPU render |
| `MediaSourcesTests` (`Tests/MediaSourcesTests.swift`) | 3 | Embedded movie cache URL, pixel-buffer→Metal bridge, movie/camera port definitions |
| `MetalImageRendererTests` (`Tests/MetalImageRendererTests.swift`) | 6 | Pipelines, texture pool reuse, identity transform, embedded asset, golden gradient+invert, golden package round-trip |
| `MetalPreviewRendererTests` (`Tests/MetalPreviewRendererTests.swift`) | 3 | Metal device, preview shaders in default library, command queue/pipeline |
| `OSCIntegrationTests` (`Tests/OSCIntegrationTests.swift`) | 5 | OSC 1.0 argument types, nested bundles, malformed/back-to-back time tags, address patterns, UDP receive |
| `QCColorPatchTests` (`Tests/QCColorPatchTests.swift`) | 16 | Framework-probe colour arithmetic, generated definitions, runtime colour patches |
| `QuartzComposerCatalogTests` (`Tests/QuartzComposerMilestoneTests.swift`) | 3 | Catalog reconstruction, catalog-only rules, requested mappings |
| `QuartzComposerNestedGraphTests` (`Tests/QuartzComposerMilestoneTests.swift`) | 3 | v1 migration, strict child ownership, clipboard owned-child identity |
| `QuartzComposerPreferenceTests` (`Tests/QuartzComposerMilestoneTests.swift`) | 2 | Category colours, rotary fader arc |
| `QuartzComposerRuntimeTests` (`Tests/QuartzComposerMilestoneTests.swift`) | 4 | LFO shapes/PWM, interpolation/random/math semantics, iterator/replicate scoping, consumer layer sort |
| `SyphonVendorModificationTests` (`Tests/QuartzComposerMilestoneTests.swift`) | 1 | The vendored Syphon local modification is recorded/present |
| `SyphonIntegrationTests` (`Tests/SyphonIntegrationTests.swift`) | 3 | Syphon patch ports, descriptor rules, Metal loopback |
| `GoldenAuthoringJourneyUITests` (`UITests/GoldenAuthoringJourneyUITests.swift`) | 2 | End-to-end modern and legacy authoring journeys |

## Source-to-docs ownership map

Review the right-hand documents whenever you touch the left-hand path. "Tests/scripts" is the
shortest command that exercises that path.

| Sensitive source path / glob | System + decision docs to review | Manual docs | Tests / scripts to run |
| --- | --- | --- | --- |
| `Sources/Graph/CompositionModel.swift` (records, codec, validator) | `systems/graph-runtime.md`, `decisions/DEC-0002-*.md` | `manual/getting-started.md` | `Tests/CompositionModelTests.swift`, `Tests/QuartzComposerMilestoneTests.swift` (`QuartzComposerNestedGraphTests`), `Scripts/verify-docs` |
| `Sources/Graph/GraphRuntime.swift` (compiler, evaluator, budget, smoothing) | `systems/graph-runtime.md`, `decisions/DEC-0007-*.md` | `manual/live-control.md` | `Tests/GraphRuntimeTests.swift`, `Tests/FeedbackTests.swift` |
| `Sources/Graph/MacroGraph.swift` | `systems/graph-runtime.md` | `manual/getting-started.md` | `Tests/MacroGraphTests.swift` |
| `Sources/Graph/PatchDescriptor.swift`, `Sources/Graph/QuartzComposerColorPatches.swift` | `systems/graph-runtime.md` | `manual/getting-started.md` | `Tests/QCColorPatchTests.swift`, `Scripts/generate-swift-color-patches.py --check` |
| `Sources/Graph/LegacyPatchCatalog.swift` | `systems/graph-runtime.md`, `decisions/DEC-0012-*.md` | `manual/getting-started.md` | `Tests/QuartzComposerMilestoneTests.swift` (`QuartzComposerCatalogTests`), `Tests/QCColorPatchTests.swift` |
| `Sources/Graph/QCColorMath.swift` | `systems/graph-runtime.md` | — | `Tests/QCColorPatchTests.swift`, `Scripts/verify-docs` (hashed fixture) |
| `Sources/Graph/GraphEditing.swift` | `systems/graph-runtime.md` | `manual/getting-started.md` | `Tests/GraphEditingTests.swift` |
| `Sources/Renderer/MetalImageRenderer.swift` | `systems/renderer.md` | `manual/getting-started.md` | `Tests/MetalImageRendererTests.swift`, `Tests/FeedbackTests.swift` |
| `Sources/Renderer/ImageEffects.swift`, `Sources/Renderer/PreviewShaders.metal` | `systems/renderer.md`, `decisions/DEC-0013-*.md` | `manual/getting-started.md` | `Tests/ImageEffectsTests.swift`, `Tests/MetalPreviewRendererTests.swift` |
| `Sources/Renderer/GeometryRenderer.swift` | `systems/renderer.md` | `manual/getting-started.md` | `Tests/GeometryRendererTests.swift` |
| `Sources/Renderer/FeedbackTextureStore.swift` | `systems/renderer.md`, `decisions/DEC-0007-*.md` | `manual/getting-started.md` | `Tests/FeedbackTests.swift` |
| `Sources/Renderer/RenderDiagnostics.swift`, `Sources/Renderer/MetalPreviewRenderer.swift` | `systems/renderer.md` | `manual/live-control.md` | `Tests/AlphaHardeningTests.swift`, `Tests/LiveSessionTests.swift` |
| `Sources/Integrations/MIDIIntegration.swift` | `systems/live-control-and-media.md`, `decisions/DEC-0008-*.md` | `manual/live-control.md` | `Tests/MIDIIntegrationTests.swift` |
| `Sources/Integrations/OSCIntegration.swift` | `systems/live-control-and-media.md`, `decisions/DEC-0008-*.md` | `manual/live-control.md` | `Tests/OSCIntegrationTests.swift` |
| `Sources/Integrations/LiveControlIntegration.swift` | `systems/live-control-and-media.md` | `manual/live-control.md` | `Tests/LiveControlIntegrationTests.swift` |
| `Sources/Integrations/SyphonIntegration.swift` | `systems/live-control-and-media.md`, `decisions/DEC-0004-*.md` | `manual/live-control.md` | `Tests/SyphonIntegrationTests.swift` |
| `Sources/Integrations/PermissionGuidance.swift` | `systems/live-control-and-media.md` | `manual/live-control.md` | (no test — see `CURRENT_STATE.md` risks) |
| `Sources/Media/MediaSources.swift` | `systems/live-control-and-media.md`, `decisions/DEC-0009-*.md` | `manual/getting-started.md` | `Tests/MediaSourcesTests.swift` |
| `Sources/Documents/CompositionDocument.swift` | `systems/documents-and-editor.md`, `decisions/DEC-0002-*.md` | `manual/getting-started.md` | `Tests/CompositionModelTests.swift`, `Tests/AlphaHardeningTests.swift` |
| `Sources/Documents/SampleCompositions.swift` | `systems/documents-and-editor.md` | `manual/getting-started.md` | `Tests/AlphaHardeningTests.swift` |
| `Sources/App/ApplicationHealth.swift` | `systems/documents-and-editor.md`, `decisions/DEC-0003-*.md` | `manual/live-control.md` | `Tests/AlphaHardeningTests.swift` |
| `Sources/App/InterfacePreferences.swift` | `systems/documents-and-editor.md`, `decisions/DEC-0011-*.md` | `manual/getting-started.md` | `Tests/LegacyInterfaceAndImportTests.swift` |
| `Sources/Editor/EditorShellView.swift`, `Sources/Editor/LiveSession.swift` | `systems/documents-and-editor.md` | `manual/getting-started.md`, `manual/live-control.md` | `Tests/LiveSessionTests.swift`, `UITests/GoldenAuthoringJourneyUITests.swift` |
| `Sources/Editor/GraphCanvasView.swift` | `systems/documents-and-editor.md` | `manual/getting-started.md` | `Tests/LegacyInterfaceAndImportTests.swift`, `UITests/GoldenAuthoringJourneyUITests.swift` |
| `Sources/Editor/ImageDropImport.swift`, `Sources/Editor/RotaryFader.swift` | `systems/documents-and-editor.md` | `manual/getting-started.md` | `Tests/LegacyInterfaceAndImportTests.swift`, `Tests/QuartzComposerMilestoneTests.swift` (`QuartzComposerPreferenceTests`) |
| `Sources/Resources/Info.plist` | `architecture/overview.md`, `decisions/DEC-0005-*.md` | `manual/live-control.md` | `Scripts/verify.sh` (build), manual permission-path check |
| `Config/*.xcconfig` | `architecture/overview.md`, `decisions/DEC-0001-*.md`, `decisions/DEC-0005-*.md`, `decisions/DEC-0006-*.md` | — | `Scripts/verify.sh` |
| `Metaliquartz.xcodeproj/**` | `architecture/overview.md` | — | `Scripts/verify.sh` |
| `Vendor/Syphon/**` | `systems/live-control-and-media.md`, `decisions/DEC-0004-*.md` | — | `Scripts/public-preflight.sh`, `Tests/SyphonIntegrationTests.swift` |
| `Scripts/verify.sh`, `Scripts/archive-alpha.sh`, `Scripts/soak-test.sh`, `Scripts/public-preflight.sh` | `../../AGENTS.md`, `docs/verification/README.md` | `manual/getting-started.md` | the script itself |
| `Scripts/verify-docs`, `.github/workflows/**` | `wiki/README.md`, `docs/verification/README.md` | — | `Scripts/verify-docs --strict` |
| `docs/verification/fixtures.json` | `docs/verification/README.md` | — | `Scripts/verify-docs` |

## Documentation conventions

**What the gate proves.** `Scripts/verify-docs --strict` proves *structure only*: every repository
link resolves, every anchor exists, the decision registry matches the records, and the guarded
fixture hashes are current. It cannot prove that a sentence still matches the runtime. Prose-versus-
runtime agreement remains a source-review duty for whoever performs the change — read the code and
the tests, do not trust a previous summary.

- One fact, one home. Link instead of restating.
- `Scripts/` (capital S) is the only scripts directory: the volume is a case-insensitive HFS+
  filesystem, so `scripts/verify-docs` and `Scripts/verify-docs` are the same file. Write the
  real on-disk path, `Scripts/verify-docs`, in links.
- `Documentation/` is untracked upstream material and is excluded from the documentation checker;
  never link to it from a maintained page as if it were our documentation.
- Record a decision in `wiki/decisions/` for anything lasting, format-affecting, security- or
  platform-boundary-affecting, or default-with-data-loss-potential.
