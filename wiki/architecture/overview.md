# Architecture overview

## What Metaliquartz is

An Apple-silicon-native macOS visual patching environment modelled on Quartz Composer: documents
hold a typed node graph, the graph is compiled and evaluated every frame, image-producing nodes
are executed on Metal, and the result is previewed or published to a fullscreen output or a
Syphon server. Published parameters can be driven from CoreMIDI or OSC.

It is a personal, direct-distribution instrument, not a sandboxed App Store product.

## Stack

| Concern | Choice | Where |
| --- | --- | --- |
| Language | Swift 6, strict concurrency `complete` | `Config/Base.xcconfig` |
| UI | SwiftUI shell + AppKit `NSView` graph canvas and `NSPanel` legacy workspace | `Sources/Editor/` |
| Graphics | Metal (MetalKit `MTKView`), Core Image for some effects | `Sources/Renderer/` |
| Media | AVFoundation + `CVMetalTextureCache` | `Sources/Media/` |
| Control input | CoreMIDI (UMP MIDI 1.0), Network.framework UDP OSC 1.0 | `Sources/Integrations/` |
| Sharing | Vendored Syphon 5 (Metal path only) | `Vendor/Syphon/` |
| Platform | arm64 only, macOS 14+ | `Config/Base.xcconfig` |
| Distribution | Ad hoc signed, hardened runtime, sandbox disabled | `Config/Release.xcconfig` |

There is no package manager manifest: the build is the Xcode project
`Metaliquartz.xcodeproj` with three targets (app, `MetaliquartzTests`, `MetaliquartzUITests`) and
one shared scheme. The Metal toolchain is a separate Xcode component.

## Runtime shape

```
DocumentGroup (CompositionDocument)
        │  .mquartz package → CompositionFile (versioned JSON)
        ▼
EditorShellView ── MetalPreviewView ── MetalPreviewRenderer (MTKView delegate, 60 fps)
        │                                   │
        │                                   ▼
        │                      MetalImageRenderer.update(composition:assets:transport:)
        │                                   │
        │            GraphCompiler.compile ─┴─ GraphRuntime(schedule:)
        │                                   │
        │                        per frame: GraphRuntime.evaluate(FrameContext)
        │                                   │  control values
        │                                   ▼
        │              encodeFrame(): image passes, geometry, effects, media,
        │              Syphon in/out, feedback capture, consumer compositing
        │                                   │
        ▼                                   ▼
Editor canvas / inspector          preview texture → drawable / fullscreen window
        │
        ├─ LiveControlController (MainActor): CoreMIDI + OSC → mappings → parameters
        ├─ ApplicationHealthStore: logs, launch markers, diagnostics export
        └─ ProjectRecoveryStore: debounced recovery snapshots
```

The graph layer evaluates **control** values only; every image-producing executor kind is either
a pass-through placeholder or is executed by the renderer's own switch. See
`systems/graph-runtime.md` and `systems/renderer.md` for the exact split.

## Subsystems

| Subsystem | Page | One-line responsibility |
| --- | --- | --- |
| Graph model, compiler, runtime | `systems/graph-runtime.md` | Typed records, validation, codec, macros, scheduling, per-frame control evaluation |
| Renderer | `systems/renderer.md` | Metal frame encoding, effects, geometry, feedback, preview, diagnostics |
| Documents, app, editor | `systems/documents-and-editor.md` | Package IO, recovery, health log, SwiftUI/AppKit editing surface |
| Live control and media | `systems/live-control-and-media.md` | MIDI, OSC, Syphon, camera and movie sources, permissions |
| Deployment boundaries | `systems/deployment.md` | Platform, signing, sandbox, vendored dependency, release scripts |

## Boundaries and non-goals

- **No audio engine.** Movies are muted and no audio track is decoded. "Graph/audio" language in
  older material is aspirational.
- **No `.qtz` import, recording or screen capture.** The QC catalog is a reconstructed reference
  library, not a runtime for QC plugins.
- **No third-party patch SDK.** Syphon is the only vendored dependency.
- **No App Sandbox.** The direct-distribution app needs flexible file, camera, display, network
  and Syphon access; enabling the sandbox is a designed change, not a checkbox (`DEC-0005`).
- **No network output.** OSC is inbound only.

## Cross-cutting invariants

- Feedback patches are the only legal frame-cycle boundary (`DEC-0007`).
- The document format is versioned and migrates forward; unknown versions are rejected rather
  than guessed (`DEC-0002`).
- The graph is evaluated on the main actor; anything off-main owns a lock or a serial queue
  (`AGENTS.md`).
- Every lasting choice has a record in `decisions/`; every sensitive path has a row in
  `PROJECT_MAP.md`.
