# The Metaliquartz wiki

This tree is the project's maintained documentation. It is written against the source in
`Sources/` and the tests in `Tests/`, and it is checked structurally by `Scripts/verify-docs`.

## How the wiki is maintained

- **One fact, one home.** If a fact appears in two pages, one of them is a bug: keep the
  canonical copy and link to it.
- **Verify against source, never against a previous summary.** Before you write a claim, open the
  file. Line numbers drift; prefer symbol and file names.
- **Pair every change.** A change to a sensitive path updates the documents named in
  `PROJECT_MAP.md`; `AGENTS.md` has the obligations table.
- **Keep `CURRENT_STATE.md` short.** It is an operational handoff (target < ~120 lines). Push
  history into `changelog/` and `evidence/`.
- **Date the snapshot.** `CURRENT_STATE.md` carries a `Last reviewed` date; update it whenever
  you touch the page.
- **Distinguish implemented / deferred / needs-device-check.** System pages say explicitly what is
  real, what is catalog-only or fallback, and what has never been exercised on hardware.
- **Record before fixing.** If the audit finds a code defect, write it in `CURRENT_STATE.md`
  (Known problems) and leave the fix for a separate bounded change.

## What the structural check does and does not prove

`Scripts/verify-docs --strict` walks every maintained Markdown file, strips fenced and inline
code, resolves repository links, checks anchors against GitHub-style slugs, validates the decision
registry, and verifies hash-guarded fixtures. It fails on a broken link, a bad anchor, an
unregistered or duplicated decision, or a stale fixture hash.

It **cannot** prove that a sentence matches the runtime. Prose-versus-source agreement remains a
human review duty; see `../docs/verification/README.md`.

## Scope of the structural check

The checker maintains `README.md`, `AGENTS.md`, `THIRD_PARTY_NOTICES.md`, and everything under
`wiki/` and `docs/`. It deliberately excludes generated, vendored and untracked material:
`Documentation/` (upstream reference capture), `Vendor/`, `.build/`, `DerivedData/` and `.private/`.
It also does not maintain `PROJECT_STATUS.md`, which is a superseded historical page kept for
reference; do not add new links to it.

## Layout

| Path | Contents |
| --- | --- |
| `CURRENT_STATE.md` | Short operational handoff: health, truth, snapshot, next actions, blockers, known problems |
| `PROJECT_MAP.md` | Source map, test inventory, and the source-to-docs ownership map |
| `architecture/overview.md` | Stack, runtime shape, subsystems, boundaries |
| `systems/*.md` | One page per subsystem: purpose, files, flow, concurrency, constants, invariants, limits, tests |
| `manual/*.md` | User-facing behaviour: what exists today, what is deferred |
| `roadmap/ROADMAP.md` | Deferred and planned work, with the decisions it depends on |
| `changelog/CHANGELOG.md` | Dated history of changes to the project and its docs |
| `decisions/` | One record per lasting choice, plus the registry |
| `evidence/` | One page per verification event: commit, machine, commands, results, and what was *not* checked |

## Adding a decision record

1. Copy the shape of an existing record: front matter `id`, `status`, `date`, then Context /
   Decision / Consequences.
2. Name the file `DEC-NNNN-short-slug.md` with the next free number.
3. Add a row to the registry table in `decisions/README.md`.
4. Run `Scripts/verify-docs --strict` — it cross-checks the file name, the declared id, the
   registry row, and the three required sections.

## Adding an evidence page

Copy an existing page under `evidence/`, set the date in the file name, and fill in commit,
machine, scope, exact commands, observed results, and an explicit "not checked" list. Never
claim a result you did not observe; if a command was blocked, say by what.
