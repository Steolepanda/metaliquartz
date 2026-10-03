# Decision records

One record per lasting choice. A decision belongs here when it is architectural, format-affecting,
security- or trust-affecting, platform- or distribution-affecting, a default with data-loss
potential, or a lasting convention.

Each record has front matter (`id`, `status`, `date`) and the sections **Context**, **Decision** and
**Consequences**. The structural checker cross-checks the file name, the declared id, this
registry, and the three sections.

## Registry

| ID | Record | Status |
| --- | --- | --- |
| DEC-0001 | `DEC-0001-swift6-strict-concurrency.md` | accepted |
| DEC-0002 | `DEC-0002-mquartz-document-format.md` | accepted |
| DEC-0003 | `DEC-0003-local-health-log-and-recovery.md` | accepted |
| DEC-0004 | `DEC-0004-syphon-metal-only.md` | accepted |
| DEC-0005 | `DEC-0005-app-sandbox-disabled.md` | accepted |
| DEC-0006 | `DEC-0006-ad-hoc-signing-for-alpha.md` | accepted |
| DEC-0007 | `DEC-0007-feedback-is-the-only-cycle-boundary.md` | accepted |
| DEC-0008 | `DEC-0008-osc10-inbound-subset.md` | accepted |
| DEC-0009 | `DEC-0009-embedded-media-pipeline.md` | accepted |
| DEC-0010 | `DEC-0010-evaluation-budget.md` | accepted |
| DEC-0011 | `DEC-0011-dual-interface-modern-and-legacy.md` | accepted |
| DEC-0012 | `DEC-0012-reconstructed-qc-catalog.md` | accepted |
| DEC-0013 | `DEC-0013-metal-first-rendering.md` | accepted |
| DEC-0014 | `DEC-0014-generated-quartz-composer-definitions.md` | accepted |
| DEC-0015 | `DEC-0015-versioned-recovery.md` | accepted |
| DEC-0016 | `DEC-0016-documentation-first-handoff.md` | accepted |
| DEC-0017 | `DEC-0017-public-source-snapshot.md` | accepted |

## Status values

- **accepted** — in force today.
- **superseded** — replaced by a newer decision; state which one in Consequences.
- **deprecated** — no longer recommended but not yet replaced.
- **proposed** — not yet in force.

## Adding a record

1. Take the next free `DEC-NNNN` and name the file `DEC-NNNN-short-slug.md`.
2. Write the front matter and the three sections, citing the source paths that enforce the choice.
3. Add the registry row above.
4. Run `Scripts/verify-docs --strict`.
