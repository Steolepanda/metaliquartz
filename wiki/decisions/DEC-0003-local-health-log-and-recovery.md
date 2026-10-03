---
id: DEC-0003
status: accepted
date: 2026-09-25
---

# Local health log, launch markers and recovery snapshots

## Context

This is a performance instrument: it may be force-quit on stage, and a lost edit is expensive. The
app also has no telemetry backend, and should not grow one. Diagnostic information has to live on
the user's machine and be exportable on demand.

## Decision

Use Application Support for all operational state, never the network:

- `Metaliquartz/Logs/metaliquartz.log` plus `metaliquartz.previous.log` (one rotation generation
  at 1 000 000 bytes), mirrored to `OSLog` under subsystem `com.steolepanda.Metaliquartz`.
- `Metaliquartz/Logs/running-<pid>.marker` written at launch; a marker whose PID is dead means the
  previous launch did not shut down cleanly.
- `Metaliquartz/Recovery/<composition.id>.mquartz` — a full package snapshot written atomically
  after a 2 s cancellation debounce on composition edits, plus manual save/restore/delete.

Diagnostic export is a plain-text report containing system, renderer and log detail, written
through a user-chosen save panel.

## Consequences

- Failures are diagnosable after the fact without a backend, and the report can be attached to a
  bug report by the user.
- The log is local-only; there is no crash aggregation, so a crash on another machine is invisible
  unless the user exports it.
- Rotation keeps at most one previous generation, so long-running sessions can lose older history.
- Writes are guarded by a lock and snapshots are atomic, so an interrupted write cannot leave a
  half-written recovery file.
- Snapshot cadence is debounce-based and keyed to composition changes; an assets-only change does
  not currently reschedule it (D12 in `../CURRENT_STATE.md`).
