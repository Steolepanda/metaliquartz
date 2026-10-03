# Release runbook

Operational steps for the alpha release gate. Commands are exact; record every run as an evidence
page (`../evidence/`). Do not skip ahead: each gate assumes the previous one passed on the same
commit.

## 0. Preconditions

- Apple silicon Mac with an unlocked, logged-in desktop session (the UI journeys need a real GUI).
- Xcode with the Metal Toolchain component:
  `xcodebuild -downloadComponent MetalToolchain` if `xcrun metal --version` fails.
- Developer tool automation enabled once: `sudo DevToolsSecurity -enable`.
- A clean checkout at the commit to release, with no uncommitted changes to `Sources/`, `Tests/`,
  `Scripts/`, or the Xcode project. Documentation-only edits are acceptable if the docs gate below
  passes and the tree state is recorded.

## 1. Documentation gate

```sh
Scripts/verify-docs --strict
```

Passes when it reports 0 errors and 0 warnings. This proves *structure*: links resolve, anchors
exist, the decision registry is consistent, and the fixture hashes match. It does **not** prove the
prose matches the runtime — that is a source-review duty
(`../../docs/verification/README.md`).

If a fixture hash changed, confirm the change was intended, update `docs/verification/fixtures.json`
in the same commit, and note it in `../changelog/CHANGELOG.md`.

## 2. Code gate

```sh
Scripts/verify.sh
```

This runs, in order: Metal toolchain check → `swift-format lint --strict` over
`Sources Tests UITests` → generated Quartz Composer definition check → documentation structure
check → Debug build → unit + UI tests → Release build. It expects the final line
`Metaliquartz verification passed.`

Record, from the log: the lint result, the test bundle result including the executed test count,
and the Release build result.

If the Debug build fails with `could not build module 'metal_types'` and an
`Operation not permitted` on a `/var/folders/.../ModuleCache` path, the run is inside a file
sandbox that blocks the Metal compiler's module cache. That is an environment failure, not a code
failure: re-run outside the sandbox and record both attempts.

## 3. Archive and signature gate

```sh
Scripts/archive-alpha.sh /tmp/MetaliquartzAlpha
```

The script re-runs the code gate, archives Release for `generic/platform=macOS`, verifies the
signature with `codesign --verify --deep --strict`, and writes
`Metaliquartz-alpha-arm64.zip` plus a `.sha256`. Record the archive path, the zip path and the
SHA-256 exactly as printed.

This is an **ad hoc** signature. It proves the artifact is the one that was tested; it does not
make the build notarized or generally distributable (`DEC-0006`).

## 4. Soak gate

With the archived app and a saved sample composition (for example **Live Camera Feedback**):

```sh
Scripts/soak-test.sh \
  /path/to/Metaliquartz.app \
  /path/to/Live-Camera-Feedback.mquartz \
  7200
```

The runner records resident memory once per minute and fails if the app exits early. Pair its CSV
with the in-app diagnostics export to assess the acceptance targets below. Record the CSV path, the
run duration, whether the app survived, and the memory trajectory.

Acceptance targets (goals, not yet met or measured anywhere):

| Metric | Target | Source of the number |
| --- | --- | --- |
| Preview frame rate | 60 fps sustained | `MetalPreviewView` `preferredFramesPerSecond` |
| p95 frame time | ≤ 20 ms (the dropped-frame threshold) | `MetalPreviewRenderer` `deltaTime > 1.0/50.0` |
| Dropped-frame percentage | 0 % over the soak | as above; a *slowness* indicator, not discarded frames |
| Node errors | none | in-app diagnostics count |
| Memory | no unbounded growth over two hours | soak CSV, one sample per minute |

These targets are not yet backed by a recorded run (risk R1 in `../CURRENT_STATE.md`).

## 5. Device checks

Before calling the alpha usable, exercise the physical paths that automated tests cannot:

- Camera input and movie playback on the target machine.
- MIDI from the controller actually used for performance.
- Syphon input and output against the other applications in the performance setup.
- OSC from the real sender, including whether macOS local-network privacy prompts or blocks it
  (finding D2 in `../CURRENT_STATE.md`).
- Fullscreen output on the target display(s).

Record each as physical-device evidence, including what was not exercised.

## 6. Closeout

- Update the verification snapshot in `../CURRENT_STATE.md`.
- Add evidence pages for the code, archive and soak runs.
- Update `../changelog/CHANGELOG.md`.
- Tag or archive the commit as the project requires. Do not commit this runbook's output files
  (`*.sha256`, soak CSV, diagnostics export) to the repository; link to them from the evidence page
  by path and keep the raw files outside the tree.

## Review gate for ordinary changes

For a normal change (not a release), the gate is smaller but not optional:

1. `Scripts/verify-docs --strict` if any Markdown changed, or if a decision, fixture or test count
   moved.
2. `Scripts/verify.sh` for anything under `Sources/`, `Tests/`, `UITests/`, `Config/` or the Xcode
   project. A faster loop is `xcrun swift-format lint ...` plus a targeted
   `xcodebuild -only-testing:MetaliquartzTests/<Suite> test`.
3. Complete the documentation obligations for the paths you touched
   (`AGENTS.md` → documentation obligations).
