---
id: DEC-0016
status: accepted
date: 2026-09-25
---

# Documentation is a maintained tree with a structural gate

## Context

The project accumulated specifications, status files and a large README, but no maintained map from
source to documentation, and no check that a link or a decision record was still valid. Status was
carried in a portfolio-generated file (`PROJECT_STATUS.md`) whose upstream source
(`PORTFOLIO_CONFIG.md`) does not exist in this repository.

## Decision

Adopt a documentation-first handoff:

- `AGENTS.md` is the engineering-constraints contract; `wiki/` is the maintained knowledge tree;
  `docs/verification/` defines how to verify and how to report.
- `wiki/CURRENT_STATE.md` is a short operational handoff (target < ~120 lines); history goes to
  `wiki/changelog/` and `wiki/evidence/`.
- `wiki/PROJECT_MAP.md` owns the source-to-docs ownership map; every sensitive source path appears
  there with the documents and tests that must move with it.
- Every lasting choice gets a record in `wiki/decisions/` with a registry row.
- `Scripts/verify-docs` enforces *structure* only: link and anchor resolution, decision-registry
  consistency, and hash-guarded fixtures. It never claims prose agrees with the runtime.
- A CI workflow (`.github/workflows/docs.yml`) runs the checker with `--strict` on push and pull
  request.

## Consequences

- A change is not finished until its paired documents are updated; the obligations table in
  `AGENTS.md` is the checklist.
- The structural gate prevents the most common rot (dead links, an unregistered decision) but not
  the most damaging kind (a confident sentence that is no longer true). Prose-versus-source
  agreement remains a review duty, stated in `docs/verification/README.md`.
- `PROJECT_STATUS.md` is kept for history and marked superseded; it is not maintained further and
  its portfolio YAML cannot be regenerated in this repository.
- `Scripts/` (capital S) is the only scripts directory despite the checker commonly being written
  as `scripts/verify-docs`: the volume is case-insensitive HFS+, and the checker resolves to
  `Scripts/verify-docs`.
- The checker is stdlib-only Python 3 so it needs no new dependency, at the cost of running under
  whatever Python 3 the machine provides (3.9 was used for the proof run).
