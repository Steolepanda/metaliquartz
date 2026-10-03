---
id: DEC-0013
status: accepted
date: 2026-09-25
---

# Rendering is Metal-first, with Core Image used only for a defined effect set

## Context

The project's premise is Apple-silicon-native GPU rendering. Core Image would make some effects
trivial but would introduce a second rendering model, its own colour management and extra copies.
A pure-Metal implementation of everything (blur, glow, gradients) would cost significant time.

## Decision

- The frame path is Metal: one `MTLDevice`, one `MTLCommandQueue`, `MTKView` presentation,
  custom Metal shaders for preview, aspect-fit, 2D transform and all geometry.
- Core Image is used, and only used, for a bounded effect set: colour controls, colour invert,
  blur, glow, blend, displace, linear/render gradients and solid colour. Core Image passes render
  through `CIContext.render(_:to:commandBuffer:)` into pooled `.rgba16Float` textures on the same
  command buffer, so there is still a single queue.
- Intermediate textures come from a `TexturePool` keyed by size and pixel format; the pool never
  evicts and is guarded by a lock because command-buffer completion handlers recycle into it.
- The presented preview alpha is forced opaque; intermediate passes clear to transparent black.

## Consequences

- One command queue and one device simplify reasoning about ordering and lifetime.
- Core Image's colour management applies to those effects, so colour results there may differ
  slightly from a hand-written Metal kernel; golden tests assert with tolerance.
- `TexturePool` is unbounded (D16 in `../CURRENT_STATE.md`): many distinct resolutions accumulate
  textures until the renderer is dropped. Bounding it is a future decision.
- "Dropped frames" is a latency heuristic (`deltaTime > 20 ms`), not actual frame skipping; the
  number must not be read as discarded frames.
- Sphere, cube and particle patches reuse the mesh/point pipelines by parameter remapping, so their
  geometry is an approximation rather than a dedicated generator.
