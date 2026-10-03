# System: renderer

**Sources:** `Sources/Renderer/`
**Tests:** `Tests/MetalImageRendererTests.swift`, `Tests/ImageEffectsTests.swift`,
`Tests/GeometryRendererTests.swift`, `Tests/FeedbackTests.swift`,
`Tests/MetalPreviewRendererTests.swift`, plus `Tests/MacroGraphTests.swift` for the
shader-in-macro path
**Decisions:** `DEC-0007` (feedback boundary), `DEC-0013` (Metal-only rendering)

## Purpose

Turn a compiled graph into a presented frame: evaluate control values, execute image-producing
patches on the GPU, composite consumer layers, draw into an `MTKView` drawable, publish to
Syphon or the fullscreen window, and record frame diagnostics. Everything here is real GPU work;
the only synthetic element is the fallback gradient used when there is no preview-output chain.

## Key files

| File | Responsibility | ~Lines |
| --- | --- | --- |
| `MetalImageRenderer.swift` | Frame encoder: graph update, per-kind execution, asset loading, `TexturePool`, feedback capture, preview encode | 845 |
| `ImageEffects.swift` | `MetalImageEffects` (Core Image colour/invert/blur/glow/blend/displace/gradients), `CustomShaderCompiler`, `CustomShaderPipelineCache` | 465 |
| `PreviewShaders.metal` | Preview vertex/fragment (fallback gradient), aspect-fit preview fragment, 2D transform fragment, geometry vertex/fragment functions | 258 |
| `GeometryRenderer.swift` | Sprite, mesh, point and line pipelines; `drawConfiguration`; output-size presets | 219 |
| `MetalPreviewRenderer.swift` | `MTKViewDelegate`; owns the single `MTLCommandQueue` and the preview pipeline; per-vsync frame; diagnostics | 157 |
| `MetalPreviewView.swift` | SwiftUI `NSViewRepresentable` creating the `MTKView` and renderer; accessibility overlay | 150 |
| `FeedbackTextureStore.swift` | One retained previous-frame texture per feedback node | 77 |
| `RenderDiagnostics.swift` | `@Observable RenderDiagnosticsModel` and `RenderDiagnosticsSnapshot` | 73 |

## Frame flow

1. `MetalPreviewView` creates the `MTLDevice` and an `MTKView` (`.bgra8Unorm_srgb`,
   `preferredFramesPerSecond = 60`, `framebufferOnly = true`, `enableSetNeedsDisplay = false`,
   `isPaused = false`; an optional forced drawable size disables auto-resize for the fullscreen
   output). `MetalPreviewRenderer` creates the **single** `MTLCommandQueue`.
2. `MetalImageRenderer.update(composition:assets:transport:)` recompiles only when the graph or
   macro definitions changed, prunes loaded asset textures, recomputes feedback node IDs, resets
   the feedback store when `transport.resetToken` changed, and forwards updates to the media
   manager and the Syphon bridge.
3. `MetalPreviewRenderer.drawFrame` builds a `FrameContext` from `ProcessInfo.systemUptime` and
   calls `MetalImageRenderer.encodeFrame(...)`.
4. `encodeFrame` evaluates control values once, seeds feedback inputs, then walks the schedule in
   topological order injecting evaluated non-image values as parameters. Intermediate textures come
   from `TexturePool` and are recycled in the command-buffer completion handler; media frames are
   kept alive with `withExtendedLifetime`.
5. Consumer layers are sorted by layer and composited; the composite replaces the preview texture.
   `encodePreview` draws the preview into the drawable; feedback captures are blitted last.
6. `encodeFrame` never commits. The preview renderer commits, presents and records diagnostics.
   If there is no schedule or no preview texture, it draws the fallback animated gradient.

Ownership: one `MTLDevice` and one command queue for the whole path; `MetalImageEffects`,
`GeometryRenderer`, `FeedbackTextureStore`, `MetalMediaSourceManager` and `SyphonMetalBridge` all
share that device.

## Concurrency

- `MetalPreviewRenderer`, `MetalImageRenderer`, `MetalImageEffects`, `CustomShaderCompiler`,
  `CustomShaderPipelineCache`, `GeometryRenderer`, `FeedbackTextureStore`, `RenderDiagnosticsModel`
  and the SwiftUI views are `@MainActor`. All Metal encoding happens single-threaded there.
- The only lock is `TexturePool`, a `@unchecked Sendable` class with an `NSLock` guarding its free
  lists, because command-buffer completion handlers recycle off-main.
- GPU timing hops back with `Task { @MainActor in ... }`. Diagnostics counters use wrapping `&+=`
  and are main-actor-confined, not atomic.
- `SyphonMetalBridge` has no lock and is MainActor-only by convention.
- No atomics, semaphores, `MTLEvent`/fences or triple-buffered dynamic buffers.

## Exact constants

| Constant | Value | Where |
| --- | --- | --- |
| Preview clear colour / pass clear | `(0.025, 0.02, 0.08, 1)` / `(0.01, 0.01, 0.015, 1)` | `MetalPreviewView`, `MetalImageRenderer.encodePreview` |
| Dropped-frame heuristic | `deltaTime > 1/50` s (20 ms), first frame excluded | `MetalPreviewRenderer` |
| Diagnostics sample capacity / p95 | 600 frames; `sorted[ceil(n*0.95)-1]` of `max(cpu,gpu)` | `RenderDiagnostics` |
| FPS smoothing | `previous*0.9 + next*0.1` | `RenderDiagnostics` |
| Custom shader fragment / metadata prefix | `mqFragment` / `// mq-parameters:` | `ImageEffects` |
| Custom shader parameter cap | 4 (`SIMD4<Float>` at buffer(1)); frame uniforms at buffer(0) | `ImageEffects`, `PreviewShaders.metal` |
| Pipeline colour format | `.rgba16Float` for effects/intermediates | `ImageEffects` |
| Geometry defaults | `columns` 64, `rows` 36, clamp `2...256`; `displacement` 0.5, `pointSize` 3, `lineSize` 1.5, `cameraDistance` 2.25, `scale` 1 | `GeometryRenderer`, `PatchDescriptor.swift` |
| Sphere / particles | sphere `slices` 32 × `stacks` 16; particles 1...100 000 laid out as `ceil(sqrt(count))` grid | `GeometryRenderer` |
| Effect defaults | blur radius 10, glow radius 12 / intensity 0.8, displace 40, colour controls identity | `ImageEffects` |
| Blend mapping | `add`→addition, `screen`→screen, `multiply`→multiply, else source-over; consumer composite only passes add/normal | `ImageEffects` |
| Output sizes | 1280×720, 1920×1080 (default), 3840×2160 | `LiveOutputResolution` |

## Invariants and rejection rules

- **Malformed custom shader:** the pipeline cache compiles each source once and remembers the
  diagnostic; a failed compile retains the **last valid pipeline** (or none). With no pipeline the
  node contributes no texture for that frame. Success clears the diagnostic.
- **Unknown patch types** are disabled at snapshot time and skipped at encode time; their data is
  preserved.
- **Missing inputs** yield `nil` and the node is skipped for the frame; `blend` falls back to
  whichever side exists.
- **Alpha:** the presented preview is forced opaque (`half4(color.rgb, 1.0h)`); the 2D transform
  returns transparent outside `[0,1]` uv and preserves source alpha scaled by opacity; geometry
  multiplies by tint including its alpha; colour invert preserves alpha (tested).
- **Feedback:** one retained texture per feedback node, reused while size and format match; any
  change to `transport.resetToken` drops all feedback textures; the per-node `clear` input removes
  that node's texture and skips capture; output lags input by exactly one frame.
- `TexturePool` never evicts — `totalAllocated` is monotonic and free lists are unbounded.

## Known limits

- "Dropped frames" is a latency heuristic, not real frame dropping; frames with no drawable are
  not counted at all.
- Sphere, cube and particles reuse the mesh/point pipelines via parameter remapping; they are
  approximations, not dedicated geometry generators.
- Value-only executor kinds (`qcMath`, `qcLFO`, colour conversions, containers) can never produce
  an image in the renderer switch; those branches are unreachable by design.
- The fallback gradient is the standby for a graph without a preview-output chain, and is not the
  normal preview path.
- No TODO/FIXME or stub markers exist in this subsystem.
- `TexturePool.availableCount(for:)` and direct test calls to `encodeTransform`/`encodePreview`
  exist for tests; `encodePreview` is also on the frame path.

## Tests that protect this

| Behaviour | Test |
| --- | --- |
| Pipeline compilation, texture pool reuse, identity transform, embedded asset, golden chains | `MetalImageRendererTests` |
| Shader metadata cap, last-valid-pipeline, colour controls/invert, gradient crop, shader round-trip | `ImageEffectsTests` |
| Geometry definitions, pipeline compilation, GPU coverage, 1080p submission | `GeometryRendererTests` |
| Feedback boundary, store reuse/resize/reset, one-frame delay | `FeedbackTests` |
| Device, default-library shaders, command queue/pipeline | `MetalPreviewRendererTests` |
| Rolling p95 and drop percentage | `AlphaHardeningTests` |
| Frames/drops/textures/node errors, resolution, fullscreen state | `LiveSessionTests` |
