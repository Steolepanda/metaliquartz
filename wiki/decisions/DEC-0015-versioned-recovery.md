---
id: DEC-0015
status: accepted
date: 2026-09-25
---

# Document migrations are additive and never rewrite the source in place

## Context

Compositions are the user's work, and a live-performance tool must not lose one to a parse bug. Two
tempting shortcuts are dangerous: guessing at an unknown version, and "repairing" a damaged package
on open.

## Decision

- A document the app cannot fully parse is reported with an actionable error and **left unchanged**;
  the user is pointed at the recovery snapshot or a backup. No automatic repair, no save-on-open of
  a repaired file.
- Accepted older versions (0 and 1) migrate in memory through `LegacyCompositionV0` and are
  restamped to version 2 only when the user saves.
- An unknown or newer version is rejected, not coerced.
- Package entry names are validated before any content is trusted, recursively, so a hostile or
  corrupted package cannot escape its directory.
- Decode failures are logged to the local health log with the `document` category before the error
  is surfaced.

## Consequences

- Opening a file is side-effect free; a failed open cannot make the situation worse.
- Users of a newer app version cannot open a document in an older build, by design.
- The recovery snapshot is the safety net, which is why it is written on a short debounce
  (`DEC-0003`).
- Migration code accumulates: `LegacyCompositionV0` must stay readable as long as version-0 files
  exist in the wild, and each new version adds another path.
