---
id: DEC-0017
status: accepted
date: 2026-10-03
---

# Public source packages exclude local references and original Git history

## Context

The working repository contains local upstream captures and private release backups. Reachable
history still contains upstream binaries larger than the publishing gate permits. A scanner that
checks tracked working-tree files alone misses new maintained docs and deleted historical secrets.
The original scanner also embedded a personal contact address in its own source.

## Decision

- `Scripts/prepare-github-package.py` exports approved project paths from tracked and non-ignored
  untracked files. It includes current source, maintained docs and vendored Syphon with its license.
- Git history, local `Documentation`, private backups, ignored output and filesystem metadata
  are excluded. No original commits are rewritten; no remote is contacted.
- `Scripts/public-preflight.sh` checks prospective files, staged contents and all reachable history by default.
  Its `--tree` mode checks exported files only. Reports contain categories and paths, not secrets.
- Recognized credential formats, personal paths/emails, development-team values, signing files,
  reference/private directories, excessive file sizes and personal PNG metadata block publication.
  GitHub noreply addresses and public vendor contact attribution are retained; EXIF consisting
  only of colour space and pixel dimensions is permitted.
- The public generator and six-patch schema reproduce the existing generated Swift bytes without
  distributing a framework, private capture or Apple application.

## Consequences

- Publish the extracted source snapshot through a fresh repository; do not copy the original
  `.git`. A successful ZIP scan cannot certify the original repository history.
- The package provides ZIP integrity, SHA-256 and a per-file manifest; it does not imply the UI,
  app archive, hardware or soak gates passed.
- Pattern scans cannot prove the absence of every possible secret format. Review new input files
  and keep the privacy regressions current. The GitHub workflow runs the same history-aware gate.
