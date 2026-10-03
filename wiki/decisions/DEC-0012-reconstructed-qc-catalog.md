---
id: DEC-0012
status: accepted
date: 2026-09-25
---

# The Quartz Composer catalogue is a reconstructed reference, not a runtime

## Context

Users coming from Quartz Composer expect to browse its patch library. Reimplementing every QC
patch is out of scope, but silently hiding the library would make the app feel arbitrary. At the
same time, letting a user add a patch that does nothing is worse than not showing it.

## Decision

Ship a reconstructed catalogue with an explicit status per row
(`PatchCatalogStatus` in `Sources/Graph/LegacyPatchCatalog.swift`):

- **functional** — has a real `PatchDefinition` and can be added to the graph.
- **existingAlias** — maps to a native Metaliquartz definition; addable under its alias.
- **catalogOnly** — reference only. Searchable and inspectable, not addable
  (`isAddable == false`). The library shows a lock and the message "Catalog reference only; this
  patch is not implemented yet".
- Two OpenCL rows are additionally marked deprecated in their names.

Genuine Quartz Composer *colour* patches are the exception: their definitions are generated from a
captured framework probe (see `DEC-0014`) and their arithmetic is implemented and tested.

## Consequences

- The library honestly reflects what the app can run; the UI cannot add a non-functional patch
  (`Tests/QuartzComposerMilestoneTests.swift` → `QuartzComposerCatalogTests` asserts this, and the
  UI journey asserts the Add
  button stays disabled for a catalog-only row).
- The catalogue is a data blob parsed at startup, so its size affects launch a little, not the
  frame path.
- The catalogue can drift from the app's real capabilities if a row's status is not updated when a
  patch is implemented; the status field is the single place to fix that.
- Users cannot rely on catalogue completeness, and the app must not imply that catalog-only rows
  are merely disabled by a setting.
