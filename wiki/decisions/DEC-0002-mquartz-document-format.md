---
id: DEC-0002
status: accepted
date: 2026-09-25
---

# The `.mquartz` package format is versioned and migrates forward

## Context

A composition must survive editing across app versions and must carry embedded assets and custom
shader sources. Bundling everything into one JSON blob would make large assets painful; an opaque
archive would make inspection and recovery harder. The app also needs to reject files it cannot
understand rather than guess.

## Decision

A document is a package directory with extension `.mquartz`:

- `composition.json` — required. Format identifier
  `com.steolepanda.metaliquartz.composition`, `version` integer.
- `Assets/` — optional directory of embedded media, keyed by asset id.
- `Shaders/` — optional directory of externalized custom shader sources.
- `Thumbnail.png` — optional.

`CompositionFile.currentVersion` is **2**. Versions 0 and 1 are accepted; version 0 migrates
through `LegacyCompositionV0`, and all accepted versions are restamped to 2 on write. Any other
version, or a non-v0 document with the wrong format identifier, is rejected
(`CompositionCodingError`). JSON is written pretty-printed with sorted keys and unescaped slashes,
with ISO-8601 dates.

Package entry names are validated recursively (no empty, `.`, `..`, `/`, `\` or control
characters). Custom shader sources are externalized to `Shaders/<shaderFile>` on write and
re-hydrated on read for the root graph and every macro graph.

## Consequences

- Every format change requires a version bump, a migration and a follow-up decision record; older
  files keep opening.
- A version newer than the app reports a clear error instead of silently dropping data.
- The package is inspectable with Finder and recoverable by hand, which matters for a live tool.
- Both the hydrate and externalize paths must stay in sync for the root graph *and* macros; a
  divergence would silently drop shader source for one of them. Tests cover the macro case.
