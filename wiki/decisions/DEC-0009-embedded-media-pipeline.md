---
id: DEC-0009
status: accepted
date: 2026-09-25
---

# Media frames become Metal textures without CPU copies

## Context

Movie and camera input must feed the same image graph as generated content, at frame rate, without
stalling the main actor. AVFoundation hands out `CVPixelBuffer`s; the renderer wants `MTLTexture`s.

## Decision

Bridge through `CVMetalTextureCache` (`PixelBufferTextureConverter`,
`Sources/Media/MediaSources.swift`):

- Movie assets are materialized from the embedded `Assets/` data into
  `temporaryDirectory/MetaliquartzMedia/<assetID>` and played through `AVPlayer` +
  `AVPlayerItemVideoOutput`, muted, looping by default.
- Camera uses one shared `AVCaptureSession` at preset `.high`, BGRA, with
  `alwaysDiscardsLateVideoFrames = true`.
- A pixel buffer becomes a `.bgra8Unorm` texture via
  `CVMetalTextureCacheCreateTextureFromImage`; the resulting `MediaTextureFrame` retains the
  `CVMetalTexture` so the backing store outlives the frame, and the renderer extends its lifetime
  through the command buffer.
- Media sources are `@MainActor`; camera capture additionally uses a session queue and a frame lock.

## Consequences

- No pixel-buffer copy on the frame path, which is what makes live camera feedback viable.
- Exactly one shared camera session: only the first `cameraImage` node's device is honoured (D5).
- Movie sources are keyed by asset ID, so two nodes using the same asset share one player and the
  last node's `loop` setting wins (D6).
- The embedded-asset cache never evicts and will not rewrite changed bytes for the same asset ID
  and extension (D7).
- Tests cover the cache URL and the pixel-buffer bridge but never instantiate the movie or camera
  source, so decode and playback are unverified without a device (D13).
- There is no audio track handling; movies are silent by design.
