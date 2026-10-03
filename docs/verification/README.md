# Verification — how to verify, and how to report it

This page defines what counts as evidence in this project and how to record it. It exists because
"it worked when I tried it" is not evidence, and because a structural documentation check must
never be confused with a runtime check.

## Evidence classes

Evidence is classified by what it actually exercises. A stronger class is never implied by a weaker
one.

### 1. Automated evidence

Machine-run checks that need only a Mac with Xcode and the Metal toolchain.

| Check | Command | Covers |
| --- | --- | --- |
| Documentation structure | `Scripts/verify-docs --strict` | Links, anchors, decision registry, fixture hashes |
| Swift lint | `xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests UITests` | Formatting |
| Generated definitions | `python3 Scripts/generate-swift-color-patches.py --check` | Generated QC colour Swift is current |
| Debug build | `xcodebuild -project Metaliquartz.xcodeproj -scheme Metaliquartz -destination 'platform=macOS,arch=arm64' -configuration Debug build` | Compilation |
| Unit + UI tests | same with `-parallel-testing-enabled NO test` | Behaviour, including GPU pixel assertions |
| Release build | same with `-configuration Release build` | Release compilation and hardening |
| Public privacy gate | `Scripts/public-preflight.sh` | Prospective files, staged contents, PNG metadata, reachable blobs and commit metadata; prints redacted categories and paths |
| Privacy regression checks | `python3 Scripts/test-public-preflight.py` | Synthetic credentials, paths, emails, metadata, symlinks, untracked files and historical secrets |
| Source package | `python3 Scripts/prepare-github-package.py` | Approved source snapshot, privacy, docs and generated definitions, ZIP integrity, checksum and file manifest |
| Complete gate | `Scripts/verify.sh` | All of the above in order |

The unit tests include real GPU work (identity transform, golden gradient/invert chains, geometry
coverage, feedback delay), so an automated pass is meaningful for the render path. It is still
**not** a substitute for a device or release check.

### 2. Physical-device evidence

Behaviour that depends on hardware, OS privacy state or a peer process. These require a real Mac
with an unlocked, logged-in desktop session and, where noted, an external device.

- Camera capture and movie playback (`CameraFrameSource`, `MovieFrameSource` are never
  instantiated by tests).
- MIDI from a physical controller; a CoreMIDI virtual source only proves the software path.
- Syphon interoperability with a second application; the loopback test only proves self-consistency.
- OSC from a real sender on the local network, including whether macOS local-network privacy
  interferes (finding D2 in `../wiki/CURRENT_STATE.md`).
- The two UI journeys, which drive real keystrokes and system panels.
- The two-hour soak run's memory trajectory and the in-app fps/p95/dropped-frame thresholds.

### 3. Release-authority evidence

Artifacts and decisions that come from a signing identity, not from code.

- `Scripts/archive-alpha.sh <outdir>`: archive creation, `codesign --verify --deep --strict`, ZIP
  and SHA-256.
- Developer ID signing and notarization: **not performed for the alpha** (`DEC-0006`). An ad hoc
  signature is release-authority evidence for "this build is what we tested", not for "this build
  is safe to distribute".

## The rule

> An automated pass never substitutes for a device check or a release check, and a green
> `Scripts/verify-docs` run proves structure only — never that prose matches the runtime.

Prose-versus-runtime agreement is established by reading the source and the tests, not by a script.
`Scripts/verify-docs` explicitly cannot detect a confident sentence that has become false.

## Evidence template

Copy this into `wiki/evidence/YYYY-MM-DD-short-slug.md`, one page per verification event.

```markdown
# <Title>

- **Date:** YYYY-MM-DD
- **Commit:** <short sha> (plus "working tree dirty: yes/no" and the list of modified paths)
- **Machine:** <model, chip, macOS version, Xcode version, Metal toolchain>
- **Class:** automated / physical-device / release-authority
- **Scope:** <what this run covers, one sentence>

## Commands and results

| Command | Result |
| --- | --- |
| `<exact command>` | <exit status and the exact salient output, quoted> |

## Observations

<What the output actually showed: counts, timings, hashes. Quote, do not paraphrase numbers.>

## Not checked

- <Everything this run did not cover, explicitly. Be specific: which suites, devices, credentials,
  platforms, and why.>
```

## Reporting rules

- Quote the exact command and the observed result. Never summarise a number you did not see.
- If a check was blocked, name the blocker and what the check would have covered. Environmental
  blockers are not failures of the code, but they are not passes either.
- Record the commit and the dirty state. A run against uncommitted changes is still evidence for
  those changes, but say so.
- One page per event. Do not append to an old page; a later run gets a later page.
- Update the verification snapshot in `../wiki/CURRENT_STATE.md` at the same time.

## Public source packages

The package command creates `dist/github/Metaliquartz-source.zip`, its `.sha256` and a
per-file hash manifest. It excludes `.git`, `.private`, local `Documentation`, ignored files,
file xattrs and build output. No upload, commit, index change or history rewrite occurs.
Unzip into a new directory and initialize a fresh repository for publication; do not copy the
original `.git`. Run `Scripts/public-preflight.sh` there before pushing. A package scan pass
only covers the exported files; it does not certify the original history or app release gates.
Public third-party attribution is retained under `Vendor/Syphon`.

## Fixtures

`fixtures.json` guards files whose exact content matters and which are easy to change by accident:

- `docs/verification/fixtures/qc-color-port-signatures.json` — a derived snapshot of the six
  `Utility > Color` patch signatures captured from Quartz Composer. It is the auditable record
  behind the generated definitions.
- `docs/verification/fixtures/qc-color-generation-schema.json` — the complete generation data
  for those six patches, so checks need no local framework or reference capture.
- `Sources/Graph/QuartzComposerColorPatches.swift` — generated; must match its generator.
- `Sources/Graph/QCColorMath.swift` — arithmetic validated against framework probes by
  `Tests/QCColorPatchTests.swift`.

When one of these legitimately changes, update its hash in the same change and explain why in
`../wiki/changelog/CHANGELOG.md`. `Scripts/verify-docs` checks the recorded hash against the file
on disk and warns about files under the fixture directory that are not registered.
