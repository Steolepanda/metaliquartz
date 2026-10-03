---
id: DEC-0001
status: accepted
date: 2026-09-25
---

# Swift 6 with complete strict concurrency, main-actor UI and rendering

## Context

The app is a real-time macOS instrument that touches Metal, AppKit, SwiftUI, CoreMIDI,
Network.framework, AVFoundation and file IO, most of it from the main thread. Historically the
project is Swift 6 with `SWIFT_STRICT_CONCURRENCY = complete`, which makes data-race safety a
compile-time property rather than a convention.

## Decision

Keep Swift 6 language mode and `SWIFT_STRICT_CONCURRENCY = complete` (`Config/Base.xcconfig`).
Confine UI, graph evaluation and Metal encoding to the main actor. Where work genuinely happens
off-main — CoreMIDI, the OSC UDP server, camera capture, texture-pool recycling from command-buffer
completion handlers — give that type its own serial queue or lock and mark it `@unchecked Sendable`
only with that justification. Graph and frame data cross boundaries as `Sendable` value types.

`GraphRuntime` remains a non-isolated `final class` evaluated only from the main-actor renderer;
this is a deliberate exception, not a precedent.

## Consequences

- Data races in shared state become compile errors; the shared mutable state that remains is small
  and enumerated in `AGENTS.md`.
- Real-time work is single-threaded on the main actor. That simplifies correctness but means a slow
  main-thread frame stalls the UI and the render together; frame timing must be watched (R1 in
  `../CURRENT_STATE.md`).
- Refactoring evaluation off the main actor later is a real design change, not a flag flip.
- Any new `@unchecked Sendable` requires an explicit justification in review.
