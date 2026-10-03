# AGENTS.md — engineering constraints and the session loop

Metaliquartz is an Apple-silicon-native macOS graph/patching environment built on Metal
(`Sources/`, Xcode project `Metaliquartz.xcodeproj`). This file holds the constraints that are
true of the *code*, not aspirations. Each rule cites the path that enforces it. When a rule and
the source disagree, the source wins and this file is the bug.

Reading order for a new session: this file → `wiki/CURRENT_STATE.md` → `wiki/PROJECT_MAP.md` →
the `wiki/systems/` page you are about to touch.

## The 4-step handoff loop

1. **Read context.** `wiki/CURRENT_STATE.md` for where the project is now, then the
   `wiki/systems/` page for the area you will touch, then the source and tests.
2. **Make a bounded change.** One intent per change. Do not fix unrelated defects in the same
   change — record them in `wiki/CURRENT_STATE.md` (Known problems) instead.
3. **Pair the docs.** Update the documents named by the documentation-obligations table below
   *in the same change*. A change with stale docs is not finished.
4. **Verify and report limits.** Run the relevant commands from the verification section. State
   exactly what you ran, what passed, and what you could not run (device, credentials, GUI
   session). Record a `wiki/evidence/` page for any gate-level run.

## Constraints, by domain

### Concurrency and threading

- Swift 6 language mode with `SWIFT_STRICT_CONCURRENCY = complete` (`Config/Base.xcconfig`).
  Anything shared across isolation domains must be `Sendable`; do not silence the checker with
  `@unchecked Sendable` except for a type that owns its own lock, as the existing ones do.
- Rendering, evaluation and UI are **main-actor confined**. `MetalPreviewRenderer`,
  `MetalImageRenderer`, `MetalImageEffects`, `GeometryRenderer`, `FeedbackTextureStore`,
  `RenderDiagnosticsModel` and the SwiftUI views are `@MainActor`. `GraphRuntime` is a plain
  `final class` that is *not* actor-isolated by declaration (`Sources/Graph/GraphRuntime.swift`);
  it is only safe because `MetalImageRenderer` evaluates it from the main actor. Do not call
  `GraphRuntime.evaluate` from another isolation domain without making it an actor or adding
  synchronization.
- Background work is limited to specific transports: the CoreMIDI input service and the OSC UDP
  server own serial `DispatchQueue`s with `NSLock`-guarded state
  (`Sources/Integrations/MIDIIntegration.swift`, `Sources/Integrations/OSCIntegration.swift`);
  `CameraFrameSource` uses a session queue plus a frame lock (`Sources/Media/MediaSources.swift`);
  `ApplicationHealthStore` guards its log with a static `NSLock`
  (`Sources/App/ApplicationHealth.swift`); `TexturePool` guards its free lists with an `NSLock`
  because command-buffer completion handlers recycle textures off the main actor
  (`Sources/Renderer/MetalImageRenderer.swift`).
- Frame data crosses into the renderer as immutable value types. Graph records and
  `GraphEvaluation` are `Sendable` structs/enums; do not introduce reference-type graph state.

### Timing, retry and rate constants

These are behaviour, not trivia. Changing one is a documentation-visible change.

| Constant | Value | Where |
| --- | --- | --- |
| Autosave recovery debounce | 2 s, cancellation-based, skipped when `MQ_UI_TESTING=1` | `Sources/Editor/EditorShellView.swift` |
| Health-log rotation threshold | `> 1_000_000` bytes, one `metaliquartz.previous.log` generation | `Sources/App/ApplicationHealth.swift` |
| Live-control smoothing tick | 16 ms `Task.sleep` | `Sources/Integrations/LiveControlIntegration.swift` |
| Smoothing response floor / UI range | `max(0.001, response)` s / slider `0...5` s | `Sources/Integrations/LiveControlIntegration.swift`, `Sources/Editor/LiveSession.swift` |
| OSC listener retry after failure | `Task.sleep(for: .seconds(2))` | `Sources/Integrations/LiveControlIntegration.swift` |
| Syphon picker poll | `Task.sleep(for: .seconds(1))` | `Sources/Integrations/SyphonIntegration.swift` |
| Dropped-frame heuristic | `deltaTime > 1.0/50.0` (20 ms), first frame excluded | `Sources/Renderer/MetalPreviewRenderer.swift` |
| Preferred preview FPS | 60 | `Sources/Renderer/MetalPreviewView.swift` |
| Diagnostics sample capacity | 600 frames; p95 = `sorted[ceil(n*0.95)-1]` of `max(cpu,gpu)` | `Sources/Renderer/RenderDiagnostics.swift` |
| Evaluation budget | 4 096 iterator/replicate executions per frame | `Sources/Graph/GraphRuntime.swift` |
| Default OSC port | 9 000 | `Sources/Graph/CompositionModel.swift` (`LiveSessionSettings.default`) |

Do not introduce a second source of truth for any of these: reference the symbol, not a copy.

### Audio, media and IO

- There is **no audio engine**. The README's "graph/audio" phrasing is aspirational; movies are
  muted and no audio track is read (`Sources/Media/MediaSources.swift`). Do not document audio
  features.
- Movie and camera frames become `MTLTexture`s through `CVMetalTextureCache`
  (`PixelBufferTextureConverter`); frames are retained for the command buffer's lifetime via
  `withExtendedLifetime`. Do not copy pixel buffers on the frame path.
- Media sources are `@MainActor`; camera capture uses `alwaysDiscardsLateVideoFrames = true`.
- Still images are loaded with `MTKTextureLoader` from `CGImageSource` data with orientation
  handling (`Sources/Renderer/MetalImageRenderer.swift`).

### Platform and distribution boundaries

- Supported platform is macOS 14+, arm64 only (`Config/Base.xcconfig`: `ARCHS = arm64`,
  `ONLY_ACTIVE_ARCH = NO`, `MACOSX_DEPLOYMENT_TARGET = 14.0`).
- **App Sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) because the direct-distribution app
  needs files, cameras, displays, network control and Syphon. Do not enable it without designing
  access for all five (decision `DEC-0005`).
- Release builds enable the hardened runtime and remain ad hoc signed
  (`Config/Release.xcconfig`, `Scripts/archive-alpha.sh`). Developer ID signing and notarization
  are deliberately out of scope for the personal alpha; do not claim a notarized build.
- Never add a camera-, microphone- or network-usage string you have not actually requested, and
  never remove `NSCameraUsageDescription` (`Sources/Resources/Info.plist`) while camera capture
  exists. Known gap: no `NSLocalNetworkUsageDescription` despite an inbound OSC listener.

### Persistence and data formats

- A composition is a `.mquartz` package: `composition.json` plus optional `Assets/`, `Shaders/`,
  `Thumbnail.png` (`Sources/Documents/CompositionDocument.swift`). Thumbnail is optional;
  the other two directories are written even when empty.
- Format id `com.steolepanda.metaliquartz.composition`, **current version 2**. Versions 1 and 2
  are accepted; version 0 migrates via `LegacyCompositionV0`; anything else throws
  `CompositionCodingError.unsupportedVersion` (`Sources/Graph/CompositionModel.swift`).
- Changing the on-disk record shape requires bumping `currentVersion`, providing a migration that
  the previous version can round-trip, and a decision record (`DEC-0002`).
- Package entry names are validated recursively: empty, `.`, `..`, `/`, `\` and control
  characters are rejected (`CompositionDocumentError.unsafePackageEntry`).
- Custom-shader source is externalized into `Shaders/<shaderFile>` on write and re-hydrated into
  `shaderSource` on read, for the root graph *and* every macro graph. Keep both paths in sync.
- Recovery snapshots live under Application Support `Metaliquartz/Recovery/<composition.id>.mquartz`
  (`ProjectRecoveryStore`). Never delete a user's damaged package to "fix" a parse error.

### Security and secrets

- `Scripts/public-preflight.sh` is the publishing gate: it rejects prospective tracked and non-ignored untracked `.env`/provisioning
  files, private keys, tokens, personal absolute paths, a `DEVELOPMENT_TEAM` value, personal/contact
  emails (except GitHub noreply addresses and public vendor attribution), reference/private
  directories, PNG text or personal EXIF metadata, and staged contents and any blob larger than 10 MiB in reachable
  history. Findings print paths and categories, never matched contents. Run it before any public
  push. `--tree <directory>` checks an exported source snapshot without history.
- `python3 Scripts/prepare-github-package.py` writes a source ZIP, checksum and manifest under
  ignored `dist/github/`; it includes approved project paths, validates privacy, docs and generated
  definitions, and excludes Git history, local references, xattrs and private backups. A safe
  snapshot does not authorize pushing the original repository history.
- `.private/` is git-ignored and holds release-safety backups (history bundles, the extracted
  `QuartzComposer.framework`, the reference image). Nothing under `.private/` may be committed.
- The app writes diagnostic logs to Application Support; do not add credentials or user content
  to a log line.

### Third-party pinning

- The only third-party component is Syphon, vendored at `Vendor/Syphon`, upstream commit
  `71351d4b484cd2d1917867f7846a5cdca724552d`, version 5, BSD-licensed
  (`Vendor/Syphon/Metaliquartz-Vendor.md`, `THIRD_PARTY_NOTICES.md`). Never re-resolve it to a
  branch or a moving tag; any local patch must be recorded in the vendor note.
- `Documentation/` is untracked upstream/reference material (EMIT QC library, Origami,
  OpenCompositor, Metal-Node, a 48 MB Xcode DMG, `.webloc` captures). Treat it as read-only
  input; do not edit it, link to it as maintained documentation, or commit it.

### Release gates

- The full gate is `Scripts/verify.sh`: Metal toolchain check → `swift-format lint --strict` over
  `Sources Tests UITests` → generated-QC-definition check from a public six-patch schema fixture → docs check → Debug build → unit+UI tests → Release
  build. It writes build products to a temporary directory and removes them.
- `Scripts/archive-alpha.sh <outdir>` runs the gate, archives Release, verifies the signature
  deep/strict, and emits a ZIP plus SHA-256. `Scripts/soak-test.sh <app> <composition> <seconds>`
  records resident memory once a minute and fails if the app exits early.
- The documentation gate is `Scripts/verify-docs --strict`. It proves structure only; prose
  agreeing with the runtime is a source-review duty (`docs/verification/README.md`).
- A gate is only "passed" if you ran it and can quote the result. Never write "verified" from a
  previous summary.

### Testing

- Tests are XCTest, Xcode-native: 118 unit test methods in 19 files in `Tests/` — note that
  `Tests/QuartzComposerMilestoneTests.swift` declares **five** `XCTestCase` classes
  (`QuartzComposerCatalogTests`, `QuartzComposerNestedGraphTests`, `QuartzComposerPreferenceTests`,
  `QuartzComposerRuntimeTests`, `SyphonVendorModificationTests`), so the suite names reported by
  `xcodebuild` do not map one-to-one to file names. `UITests/` holds 2 UI test methods in one
  class (120 test methods total). There is no SwiftPM manifest — `xcodebuild -scheme Metaliquartz
  test` is the only runner.
- GPU tests require a real Metal device and run on the main actor; they assert rendered pixels
  with tolerance (`Tests/GeometryRendererTests.swift`, `Tests/MetalImageRendererTests.swift`).
- `UITests/GoldenAuthoringJourneyUITests.swift` drives real keystrokes and system panels. It
  requires an unlocked, logged-in GUI session and fails (not skips) without one.
- When you add behaviour, add the test next to the existing suite for that area and update the
  system page and the test inventory in `wiki/PROJECT_MAP.md`.

## Sources of truth

| Fact | Home |
| --- | --- |
| Current status, next actions, blockers | `wiki/CURRENT_STATE.md` |
| What the code is and where it lives | `wiki/PROJECT_MAP.md`, `wiki/systems/*` |
| Product/architecture overview | `wiki/architecture/overview.md` |
| User-facing behaviour | `wiki/manual/*` |
| Lasting choices and their consequences | `wiki/decisions/` |
| What was verified, when, by what | `wiki/evidence/`, `docs/verification/README.md` |
| History of changes | `wiki/changelog/CHANGELOG.md` |
| Known defects, deferred work | `wiki/CURRENT_STATE.md`, `wiki/roadmap/ROADMAP.md` |
| Build/test/release commands | `Scripts/verify.sh`, `Scripts/archive-alpha.sh`, `Scripts/soak-test.sh` |

## Documentation obligations

| If you change… | Update |
| --- | --- |
| Anything under `Sources/Graph/` | `wiki/systems/graph-runtime.md`, `wiki/PROJECT_MAP.md`, a decision record if a format/rule changes |
| Anything under `Sources/Renderer/` | `wiki/systems/renderer.md` |
| Anything under `Sources/Integrations/` or `Sources/Media/` | `wiki/systems/live-control-and-media.md` |
| `Sources/Documents/`, `Sources/App/`, `Sources/Editor/` | `wiki/systems/documents-and-editor.md` |
| The `.mquartz` format or a codec version | `wiki/systems/graph-runtime.md`, `wiki/systems/documents-and-editor.md`, `DEC-0002`, a new decision record |
| A user-visible feature | the matching `wiki/manual/*` page and `wiki/changelog/CHANGELOG.md` |
| A build/test/release command | `AGENTS.md`, `docs/verification/README.md`, `wiki/manual/getting-started.md` |
| A platform, signing or sandbox boundary | `DEC-0005`, `DEC-0006`, `wiki/architecture/overview.md` |
| A third-party dependency | `AGENTS.md`, `THIRD_PARTY_NOTICES.md`, `wiki/decisions/`, `Scripts/public-preflight.sh` |
| A test suite or its counts | `wiki/PROJECT_MAP.md`, the owning system page |
| A hash-guarded fixture | `docs/verification/fixtures.json`, then re-run `Scripts/verify-docs` |

## Verification commands

```sh
Scripts/verify-docs --strict          # documentation structure (links, anchors, decisions, fixtures)
Scripts/verify.sh                     # the complete code gate: lint, Debug, tests, Release
Scripts/archive-alpha.sh /tmp/Alpha   # gate + archive + signature + ZIP + SHA-256
Scripts/public-preflight.sh           # prospective files + reachable history; may block a direct push
python3 Scripts/test-public-preflight.py # privacy scanner regression checks
python3 Scripts/prepare-github-package.py # audited source ZIP in ignored dist/github/
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests UITests
xcodebuild -project Metaliquartz.xcodeproj -scheme Metaliquartz \
  -destination 'platform=macOS,arch=arm64' test
```

Limitations to state when reporting: UI tests need a GUI session; camera, MIDI hardware, Syphon
peers and the soak run need a real machine; the sandboxed environment used for some sessions
cannot write the Metal compiler's default module cache, so `Scripts/verify.sh` may need a
non-sandboxed run (see `wiki/evidence/` for which runs were affected).
