---
id: DEC-0004
status: accepted
date: 2026-09-25
---

# Syphon is vendored and used through its Metal path only

## Context

Syphon is the de-facto macOS inter-application frame-sharing protocol and the natural way for a
patching tool to feed and consume other visual software. The upstream framework ships both OpenGL
and Metal APIs. Adding it as a package dependency would drag in a resolver and a build graph the
Xcode project does not otherwise have.

## Decision

Vendor Syphon at `Vendor/Syphon`, pinned to upstream commit
`71351d4b484cd2d1917867f7846a5cdca724552d` (version 5, BSD-2-Clause), linked and embedded as
`Syphon.framework`. Integrate only `SyphonMetalClient`, `SyphonMetalServer` and
`SyphonServerDirectory`; never pass textures through a CPU copy, and never use the OpenGL classes.
Record the one local modification (removal of the deprecated `kIOSurfaceIsGlobal`) in
`Vendor/Syphon/Metaliquartz-Vendor.md`.

The client is polled once per render frame rather than driven by `newFrameHandler`, so Syphon never
calls back into app code and the MainActor-only assumption holds.

## Consequences

- Textures stay on the GPU end to end, which is the whole point of the Metal path.
- The dependency is pinned by copy, so an upstream change cannot break the build silently; the
  cost is that security or platform fixes must be imported by hand.
- The license notice must travel with the vendor tree (`THIRD_PARTY_NOTICES.md`) and the public
  preflight gate checks for forbidden assets.
- `SyphonMetalBridge` has no lock and is MainActor-only by convention; using it off-main would be a
  bug.
- Publishing every frame regardless of `hasClients` is a small waste that is accepted for now.
