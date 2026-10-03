# System: live control, media and Syphon

**Sources:** `Sources/Integrations/`, `Sources/Media/`, `Vendor/Syphon/`
**Tests:** `Tests/MIDIIntegrationTests.swift`, `Tests/OSCIntegrationTests.swift`,
`Tests/LiveControlIntegrationTests.swift`, `Tests/SyphonIntegrationTests.swift`,
`Tests/MediaSourcesTests.swift`
**Decisions:** `DEC-0004` (Syphon), `DEC-0008` (OSC 1.0 set), `DEC-0009` (media pipeline)

## Purpose

Connect the document to the outside world: CoreMIDI control input, inbound OSC over UDP, Syphon
texture sharing, camera and movie frames as Metal textures, and permission readiness for the
capture paths. The hub is `LiveControlController`; the transports and the Syphon bridge are
separate files.

## Key files

| File | Responsibility | ~Lines |
| --- | --- | --- |
| `Sources/Integrations/LiveControlIntegration.swift` | `@MainActor @Observable` hub: MIDI/OSC receive, mapping and learn, 16 ms smoothing ticker, action queue | 384 |
| `Sources/Integrations/OSCIntegration.swift` | OSC 1.0 decoder (messages, bundles, time tags), address patterns, `NWListener` UDP server | 407 |
| `Sources/Integrations/MIDIIntegration.swift` | CoreMIDI client/input port, UMP MIDI 1.0 parser, endpoint discovery, learned-source descriptors | 299 |
| `Sources/Integrations/SyphonIntegration.swift` | Server directory descriptor, SwiftUI picker, `SyphonMetalBridge` client + server | 285 |
| `Sources/Media/MediaSources.swift` | Embedded asset cache, `MovieFrameSource`, `CameraFrameSource`, pixel-buffer→Metal converter, `MetalMediaSourceManager` | 306 |
| `Sources/Integrations/PermissionGuidance.swift` | Camera / screen-recording / external-access readiness model | 95 |
| `Vendor/Syphon/` | Vendored Syphon 5, commit `71351d4b484cd2d1917867f7846a5cdca724552d`, BSD; local patch removes deprecated `kIOSurfaceIsGlobal` | — |

## Control flow

**MIDI → parameter.** CoreMIDI receive block → `MIDI1MessageParser.event(umpWord:source:)` →
`MIDIInputEvent` (channel is one-based; `normalizedValue` is `value/127` or
`pitchBend/16383`) → `MIDIInputService` serial queue → MainActor
`LiveControlController.receive(_:)` → for each `controlMapping` whose source matches, apply:
clamp to `0...1`, scale into the mapping's `min...max`. With smoothing `> 0` the value becomes a
target advanced by the ticker; otherwise it is written to `currentValues` and queued as
`.setParameter`, which `EditorShellView.applyLiveControlActions()` drains into
`node.parameters[published.parameterKey]`.

**OSC → parameter.** `NWListener` (UDP) → `receiveMessage` → `OSCPacketDecoder.decode` →
`OSCUDPServer.deliver` (immediate, or `queue.asyncAfter` for a future time tag) → MainActor
`LiveControlController.receive(_ scheduledMessage:)` → first argument mapped (int32/float32 →
scalar, boolean, string) → matching OSC mappings, or the default address
`/metaliquartz/<slug>` when the document has none. Publishing a parameter normally auto-creates
one OSC mapping, so the default-address branch applies mainly to older documents.

**MIDI learn.** `toggleMIDILearn(for:)` arms a parameter; the next MIDI event clears the armed
state, applies the value through a throwaway mapping, and enqueues `.learnedMapping`, which the
editor stores after removing that parameter's previous MIDI mappings.

**Syphon.** Client: `SyphonDirectory.rawDescription` (exact UUID first, then name/application
fallback) → `SyphonMetalClient`, polled once per render frame for the latest texture, which
`.syphonInput` binds. Server: `.syphonOutput` reads its input texture and publishes it onto the
caller's command buffer via `SyphonMetalServer` (full-texture region, `flipped: false`). The
bridge prunes, reconnects and renames as the composition changes.

**Media.** `MetalMediaSourceManager.update` scans for `.movieImage` / `.cameraImage` nodes. Movie
assets are materialized into `temporaryDirectory/MetaliquartzMedia/<assetID>` and played through
`AVPlayer` + `AVPlayerItemVideoOutput` with loop notification; camera uses one shared
`AVCaptureSession`. `copyCurrentPixelBuffer()` / `copyLatestPixelBuffer()` feed
`PixelBufferTextureConverter` (`CVMetalTextureCacheCreateTextureFromImage`, `.bgra8Unorm`) and the
resulting `MediaTextureFrame` retains the `CVMetalTexture` for the frame's lifetime.

## Concurrency

| Type | Isolation |
| --- | --- |
| `LiveControlController` | `@MainActor @Observable`; MIDI/OSC handlers hop with `Task { @MainActor ... }`; ticker sleeps 16 ms |
| `MIDIInputService` | `@unchecked Sendable`; serial `DispatchQueue` + `NSLock` guarding client/port/contexts; never holds the lock while calling handlers |
| `OSCUDPServer` | `@unchecked Sendable`; serial queue + `NSLock`; listener and connections live on the queue |
| `SyphonMetalBridge` | no isolation marker, no lock; MainActor-only by convention |
| `MetalMediaSourceManager`, `MovieFrameSource` | `@MainActor` |
| `CameraFrameSource` | `@unchecked Sendable`; serial session queue + `NSLock` around the latest frame |

Syphon `newFrameHandler` is `nil`, so the framework never calls back into app code.

## Exact constants

| Constant | Value |
| --- | --- |
| Default OSC port / UI clamp | 9 000 / `1...65535` |
| NTP epoch offset | `2_208_988_800.0` s; fraction divisor `4_294_967_296` |
| Smoothing response / tick / snap | `max(0.001, response)` s / 16 ms / `0.000_1` |
| OSC listener retry | 2 s |
| Syphon picker poll | 1 s |
| OSC packet alignment | datagram length must be non-zero and a multiple of 4; bundle element size non-zero and a multiple of 4; strings ASCII, null-terminated, zero-padded |
| Camera | preset `.high`, `kCVPixelFormatType_32BGRA`, `alwaysDiscardsLateVideoFrames = true` |
| Movie | `32BGRA`, muted, `actionAtItemEnd = .pause`, loop default `true` |
| Syphon default server name | `"Metaliquartz"`, publish `flipped: false` |

## Invariants and rejection rules

**MIDI.** Only UMP message type `0x2` (MIDI 1.0 Channel Voice) is parsed. Accepted statuses are
note-off `0x80`, note-on `0x90`, CC `0xB0` and pitch bend `0xE0`; poly aftertouch, program change,
channel pressure, sysex and RPN/NRPN are dropped silently. A mapping matches only when its optional
device and channel filters match, the message kind matches, and the controller/note number matches.

**OSC.** Decoded argument types are exactly `i`, `f`, `s`, `T`, `F` (`DEC-0008`). Any other type
tag throws. Inside a bundle a bad type tag discards that element and continues with siblings;
every other decode error aborts the datagram. A nested non-immediate time tag earlier than a
non-immediate enclosing tag is rejected; equal is allowed. The address must start with `/` and the
type-tag string with `,`.

**Syphon.** A server descriptor is invalid without a non-empty UUID; display name falls back from
name to application name to `"Unnamed Server"`. Directory lookup prefers an exact UUID, otherwise
the first non-empty name/application match.

**Permissions.** Camera maps the system authorization status (unknown → restricted). Screen
recording is binary (`ready` / `denied`) because only `CGPreflightScreenCaptureAccess()` is
consulted. External access is hardcoded `ready` because App Sandbox is disabled.

## Implemented vs deferred

- **Implemented and wired:** CoreMIDI input, UMP parsing, device discovery; OSC 1.0 decode,
  address patterns, UDP receive, time-tag scheduling; mapping/learn/smoothing; Syphon Metal
  client, server, directory and picker; movie and camera textures; permission guidance.
- **Requires real hardware or OS state:** MIDI delivery tests use a CoreMIDI virtual source;
  the Syphon loopback test needs a real Metal device; the UDP test uses a synthetic loopback.
- **Never instantiated in tests:** `CameraFrameSource` and `MovieFrameSource` — camera and movie
  decode/playback are effectively unverified without a device and a file (finding D13).
  `PermissionGuidance` has no test at all.
- **Deferred / not present:** OSC output (inbound only), screen capture, MIDI 2.0 and sysex, movie
  audio, the Syphon OpenGL path.

## Known limits

| Finding | Detail |
| --- | --- |
| D2 | No `NSLocalNetworkUsageDescription` despite the inbound UDP listener |
| D3 | `CameraFrameSource.startIfNeeded` marks started before authorization/configuration |
| D4 | `retiredContexts` retains disconnected MIDI endpoints until `stop()` |
| D5 | Only the first `cameraImage` node is honoured |
| D6 | Movie sources are keyed by asset ID, so shared assets share one player |
| D7 | `EmbeddedMediaCache` never evicts and will not rewrite changed bytes |
| D8 | Malformed OSC datagrams are dropped with no diagnostic |
| D9 | Production smoothing uses wall-clock deltas; `advanceSmoothing(by:)` is test-only |
| D10 | `PublishedParameterMapper` / `PublishedParameterSmoother` are test-only |

## Tests that protect this

| Behaviour | Test |
| --- | --- |
| UMP parsing, device/channel/message filters, virtual source delivery | `MIDIIntegrationTests` |
| OSC argument types, nested bundles, malformed/backwards time tags, address patterns, UDP receive | `OSCIntegrationTests` |
| MIDI range mapping, MIDI learn, OSC default addresses, smoothing, mapping round-trip | `LiveControlIntegrationTests` |
| Syphon ports, descriptor rules, Metal loopback | `SyphonIntegrationTests` |
| Embedded movie cache URL, pixel-buffer bridge, media port definitions | `MediaSourcesTests` |
