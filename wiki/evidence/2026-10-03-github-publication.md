# Clean-history GitHub source upload

- **Date:** 2026-10-03 (Asia/Shanghai)
- **Source:** audited 218-file ZIP; SHA-256
  `693318c3c0113ad95bfb6f7d772de6086d93dc6535f4458f01d3682250ec602d`.
- **Published source commit:** `2dd0f43dc9a92b89c1b27aacca509794ef827ed4`.
- **Class:** automated
- **Scope:** source-only upload to
  [Steolepanda/metaliquartz](https://github.com/Steolepanda/metaliquartz/tree/codex/public-source).

## Commands and results

| Command | Result |
| --- | --- |
| ZIP integrity and all 218 manifest hashes | Pass; exact prepared source files extracted with executable permissions |
| `python3 Scripts/public_preflight.py` against the original GitHub clone | Exit 1: `personal/contact email: commit metadata`; the original single README commit is not used as an ancestor |
| `bash Scripts/public-preflight.sh` before the clean root commit | Exit 0; 218 prospective files, 218 index entries, 0 history blobs |
| `python3 Scripts/test-public-preflight.py` | Exit 0: `Ran 9 tests`; `OK` |
| `python3 Scripts/verify-docs --strict` | Exit 0: 40 Markdown files, 17 decisions, 4 fixtures; `0 error(s), 0 warning(s)` |
| `git diff --cached --check` for the initial import | Exit 2; existing catalog string indentation, Markdown whitespace and vendored Syphon whitespace; no source changes made for this cosmetic check |
| `bash Scripts/public-preflight.sh` after the clean root commit | Exit 0: `Scanned 218 prospective files, 218 index entries and 215 reachable history blobs.`; `Public preflight passed: no prohibited paths or recognized private-information patterns found.` |
| `git push -u origin codex/public-source` | Exit 0: `[new branch] codex/public-source -> codex/public-source` |
| `gh run view 37119361508 --repo Steolepanda/metaliquartz --json conclusion,jobs,url` | Remote CI failed `Check public files and reachable history`; privacy regression tests passed |
| Post-upload documentation/privacy checks | Exit 0; 41 Markdown files, 17 decisions, 4 fixtures; source history and staged docs pass |

## Observations

The uploaded commit is a fresh root containing the checked source snapshot. Neither the original
local history nor GitHub's initial README commit is included in the new branch. The commit author
and committer use the authenticated owner's public GitHub noreply identity; no contact email is
printed or included in this evidence.

GitHub's existing `main` remains at `53c8bc0f446c59d5086a24458cc547994692a9b7`; its contact metadata
already existed remotely. A temporary local clone preserves that commit. Replacing it is a
remote-history rewrite and awaits owner approval. The old local development checkout is untouched.

## Not checked

- [Remote CI run 37119361508](https://github.com/Steolepanda/metaliquartz/actions/runs/37119361508)
  failed its history privacy gate. Checkout fetches the existing `main` contact metadata too;
  cleanup remains pending approval. Strict docs checking was skipped after the failure, while
  the JSON docs report was generated. No remote green gate is claimed.
- No app binaries, alpha release, GitHub Release, tags, notarization or device/soak run were uploaded.
- Full app tests and build gates were not repeated for this source-only publication.
