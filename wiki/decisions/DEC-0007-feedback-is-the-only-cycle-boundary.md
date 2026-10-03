---
id: DEC-0007
status: accepted
date: 2026-09-25
---

# Feedback patches are the only legal frame-cycle boundary

## Context

Visual graphs need loops — previous-frame effects, trails, accumulators — but an unconstrained
graph cycle makes evaluation order undefined. The options were to reject all cycles, to allow
implicit one-frame delays anywhere, or to make the delay explicit at a single patch type.

## Decision

A graph may not contain a cycle except through a **Feedback** patch.
`NodeRecord.breaksFrameCycle` is true only for
`patchType == "com.steolepanda.metaliquartz.feedback"`. The validator and the compiler both exclude
outgoing edges from such a node when detecting cycles and building the schedule, so a feedback node
is the topological boundary of a loop.

The runtime passes the feedback node's input straight through; the previous frame is supplied by
`FeedbackTextureStore`, which keeps one retained texture per feedback node, is reset by any change
to `transport.resetToken`, and is pruned when a node stops being a feedback node. The per-node
`clear` input drops that node's texture and skips capture.

## Consequences

- Evaluation order is always well defined; feedback output lags its input by exactly one frame, and
  that delay is testable and tested (`Tests/FeedbackTests.swift`).
- Users who want a different delay must compose it from multiple feedback nodes; the model is
  deliberately small.
- Feedback state is renderer-owned, not document state, so it survives edits but not a transport
  reset — which is what a performer expects from a "clear" control.
- The one-frame delay is visible as a lag in a live camera loop; this is inherent to the design,
  not a defect.
- Because only one node type creates the boundary, changing that patch's id is a breaking change to
  every saved document's cycle legality.
