# docs verification checker — failure-class proof

- **Date:** 2026-09-25
- **Commit:** working tree (uncommitted reorganization); see `2026-09-25-reorganization.md`
- **Machine:** Apple silicon Mac, macOS 27.0 (build 26A428), Xcode 27.0 (27A266a), Python 3.9.6
- **Class:** automated
- **Scope:** prove that `Scripts/verify-docs` detects every required failure class and passes a
  clean tree.

## Method

A throwaway tree was built under `/tmp/verify-docs-fixture` containing one instance of each failure:
a broken repository link, a bad anchor (cross-page and in-page), a duplicate decision registry row,
an unregistered decision record, a fixture hash mismatch, and an unregistered fixture file. The
tree also contained a link inside an inline code span and a link inside a fenced code block, to
prove both are stripped before parsing.

## Commands and results

| Command | Result |
| --- | --- |
| `scripts/verify-docs --repo-root /tmp/verify-docs-fixture` | exit 1; 6 errors, 1 warning (all classes reported below) |
| `scripts/verify-docs --repo-root /tmp/verify-docs-fixture --json` | `ok: false`; counts `{"markdownFiles":6,"links":4,"anchors":4,"decisions":2,"fixtures":1,"errors":6,"warnings":1}` |
| `scripts/verify-docs --repo-root /tmp/verify-docs-fixture --quiet` | findings still printed when present (quiet suppresses output only on a clean tree) |
| `scripts/verify-docs --repo-root /tmp/verify-docs-clean --strict` | exit 0; 0 errors, 0 warnings |

Salient output of the dirty run, quoted:

```
Sources/Graph/Other.swift:0: WARNING: fixture is not registered in docs/verification/fixtures.json
docs/verification/fixtures.json:0: ERROR: fixture Sources/Graph/Evidence.swift hash mismatch (recorded 000000000000, actual 1c8eb85217cc)
wiki/PROJECT_MAP.md:5: ERROR: link target does not exist: systems/does-not-exist.md
wiki/PROJECT_MAP.md:6: ERROR: anchor '#no-such-heading' does not exist in wiki/CURRENT_STATE.md
wiki/PROJECT_MAP.md:7: ERROR: anchor '#absent-heading' does not exist in wiki/PROJECT_MAP.md
wiki/decisions/DEC-0003-orphan.md:0: ERROR: record DEC-0003 is not registered in wiki/decisions/README.md
wiki/decisions/README.md:7: ERROR: duplicate registry row for DEC-0002
verify-docs: 6 markdown file(s), 4 link(s), 4 anchor(s), 2 decision(s), 1 fixture(s) — 6 error(s), 1 warning(s)
```

The fenced and inline-code example links were **not** reported, confirming the stripper works.

## Observations

- Every failure class required by the specification produced an error: broken link, bad anchor
  (both forms), duplicate decision id, unregistered record, wrong fixture hash.
- The unregistered-fixture case produced a warning, not an error, and `--strict` promotes warnings
  to a non-zero exit.
- `--json` emits counts, per-finding objects and an `ok` flag; `--quiet` is silent only on a clean
  tree.

## Not checked

- Windows or Linux behaviour; the checker is used on macOS only.
- Non-UTF-8 Markdown (unreadable files are reported as an error rather than skipped).
- HTML `<a name>` anchors nested in raw HTML blocks; only inline occurrences are recognised.
- Symlinks inside the repository tree.
