---
id: DEC-0010
status: accepted
date: 2026-09-25
---

# Iterator and replicate work is capped at 4 096 executions per frame

## Context

Iterator and Replicate patches expand a child graph N times per frame. A user can type a large
count, and a nested iterator multiplies, so an unbounded graph can hang the app with no visible
cause. The budget must be small enough to keep a frame bounded and large enough for dense grids.

## Decision

Each `GraphRuntime.evaluate` call starts with a local budget of **4 096** executions.
`evaluateContainer` takes `min(requested, budget)` iterations and decrements the budget per
execution across all iterators and replicates in the frame. When the budget runs out, a diagnostic
is appended (`"Iterator/replicate evaluation was capped at 4,096 executions."`) and evaluation
continues with what was produced. The schema range for a single iterator `count` or replicate
`copies` is `0...4_096`.

The budget is per frame and per runtime, so it does not accumulate across frames.

## Consequences

- A pathological graph degrades by producing fewer iterations instead of freezing; the user sees a
  diagnostic rather than a hang.
- The cap applies to iteration only. There is no cap on node, port or connection count, no macro
  nesting-depth cap and no evaluation recursion-depth cap, so a sufficiently large or deeply nested
  graph can still be slow (D14 in `../CURRENT_STATE.md`).
- The budget mechanism is currently untested; a regression that removed it would not fail a test.
- Because the budget spans the whole frame, one large iterator can starve a later one in the same
  frame; the diagnostic makes that visible.
