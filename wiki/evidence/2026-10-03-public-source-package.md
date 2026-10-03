# Public source package and privacy audit

- **Date:** 2026-10-03 (Asia/Shanghai)
- **Commit:** `8e45c05`; working tree dirty: yes. Existing uncommitted app, graph, renderer,
  test, Xcode project and documentation work is included in the source snapshot.
- **Machine:** local macOS arm64 development host; source packaging and Xcode tooling only.
- **Class:** automated
- **Scope:** exported source files, staged contents, reachable original history and fresh repository.

## Commands and results

| Command | Result |
| --- | --- |
| Original `Scripts/public-preflight.sh` before edits | Exit 1: `Public release blocked by 1 preflight finding(s).` Three oversized historical upstream files, including a DMG, plugin binary and movie |
| Updated `Scripts/public-preflight.sh` in original repository | Exit 1: `Public release blocked by 1741 preflight finding(s).` Prospective files, index and history include local references and old contact information; original history is preserved |
| `python3 Scripts/test-public-preflight.py` | Exit 0: `Ran 9 tests`; `OK`. Includes a secret staged before its working copy is cleaned, an untracked email, and a removed historical token |
| `bash -n Scripts/public-preflight.sh` and `zsh -n Scripts/verify.sh` | Exit 0 |
| `xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests UITests` | Exit 0, no findings |
| `Scripts/verify-docs --strict` | Exit 0, `0 error(s), 0 warning(s)` |
| `python3 Scripts/generate-swift-color-patches.py --check` | Exit 0: `up to date: Sources/Graph/QuartzComposerColorPatches.swift` |
| `python3 Scripts/prepare-github-package.py` | Exit 0: `GitHub source package prepared: 218 files`; privacy, docs, generated definitions and ZIP integrity passed |
| ZIP extraction + SHA-256/file-manifest comparison | All 218 member hashes, member paths and excluded-directory checks pass |
| `bash Scripts/public-preflight.sh` in a fresh temporary repository made from the ZIP | Exit 0: `Scanned 218 prospective files, 218 index entries and 215 reachable history blobs.`; `Public preflight passed: no prohibited paths or recognized private-information patterns found.` |
| Docs and generated-definition checks repeated in the extracted tree | Exit 0: `40 markdown file(s)`, `17 decision(s)`, `4 fixture(s)`; `0 error(s), 0 warning(s)`; generated Swift is `up to date` |
| `plutil -lint Metaliquartz.xcodeproj/project.pbxproj` in the extracted tree | Exit 0: `Metaliquartz.xcodeproj/project.pbxproj: OK` |
| `xcodebuild -list -project Metaliquartz.xcodeproj` in the extracted tree | Exit 0; app, unit-test and UI-test targets; Debug/Release configurations; Metaliquartz and Syphon schemes |
| `git diff --check` | Exit 0 |

## Observations

The ZIP and external SHA-256/file manifest are under ignored `dist/github/`. The package contains
current working-tree source, maintained docs, public six-patch generation data and vendored Syphon.
It excludes `.git`, `.private`, local `Documentation`, ignored build/cache output and file xattrs.

The original gate missed untracked files and excluded the scanner's hardcoded personal address.
The replacement no longer stores that address and scans staged data as well as working files and
history. A fresh source snapshot avoids publishing the old scanner or historical upstream files.

Image inspection found the supplied brand artwork and icon EXIF consisting only of colour space
and pixel dimensions; no personal image metadata is distributed. Public vendor contact attribution
is retained with third-party licenses. The pattern scanner is a bounded check, not proof against
all possible secret formats.

## Not checked

- No GitHub repository, commit, tag, push, release or upload was created. Remote CI did not run.
- The full app gate, Debug/Release builds, XCTest/UI journeys, alpha archive, signature,
  notarization, device paths and soak were not run for this source-only package.
- Original repository history is **not** safe to push; it remains blocked. Publish by creating
  a fresh repository from the extracted source, without copying the old `.git`.
