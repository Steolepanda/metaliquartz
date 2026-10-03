---
id: DEC-0008
status: accepted
date: 2026-09-25
---

# OSC support is inbound OSC 1.0 with a defined argument subset

## Context

OSC is the natural control protocol for live visual software, but the 1.0 specification includes
types the app has no use for (blobs, timetags as arguments, MIDI messages, arrays, chars). A
decoder that silently coerces unknown types hides mapping bugs; one that rejects a whole packet
because of one unknown sibling is brittle on a shared network.

## Decision

Implement **inbound** OSC 1.0 only, over UDP, default port 9000 (per-composition override).

- Decoded argument types: `i` (int32), `f` (float32), `s` (string), `T` (true), `F` (false).
- Support single messages, ordered recursive bundles, time tags, and address patterns.
- Inside a bundle, an element with an unsupported type tag is discarded and its siblings continue
  to be processed. Any other structural error (truncation, misalignment, bad address, bad string,
  backwards nested time tag) rejects the datagram.
- A nested non-immediate time tag earlier than a non-immediate enclosing tag is invalid; equal is
  allowed.
- There is no OSC output path and no network send.

## Consequences

- Tools that send blobs, doubles, int64 or array arguments cannot drive parameters until those
  types are added, and the app will not tell them why: malformed datagrams are dropped silently
  (D8 in `../CURRENT_STATE.md` — worth surfacing as a diagnostic).
- Sibling isolation makes a mixed bundle partial-succeed, which is friendlier on stage but means a
  mapping can appear to work intermittently if one argument type is wrong.
- The subset is small enough to test exhaustively; `Tests/OSCIntegrationTests.swift` covers the
  accepted types, nested bundles, address patterns, malformed packets and backwards time tags.
- Adding a type or an output path is a change to this record.
