# Roadmap

Planned and deferred work, ordered by what unblocks the alpha. Each item names the decision it
depends on, if any. Nothing here is a commitment; it exists so a handoff can pick up without
re-deriving intent.

## Now — close the alpha gates

1. **Run and record the code gate.** `Scripts/verify.sh` on an unlocked Mac desktop session;
   record the test count and result in `../evidence/`. Depends on nothing.
2. **Run and record the archive gate.** `Scripts/archive-alpha.sh`; record archive path,
   `codesign --verify` result and ZIP SHA-256.
3. **Run and record the two-hour soak** with the **Live Camera Feedback** composition; record the
   CSV and the in-app diagnostics export.
4. **Record the supported-OS/device matrix** as a decision record; today only "macOS 14+, arm64"
   is asserted by `Config/Base.xcconfig`, not measured.

## Next — defects found by the reorganization audit

Each is a separate bounded change with a test where one is possible. See
`../CURRENT_STATE.md` for the full table.

| Finding | Work | Decision needed |
| --- | --- | --- |
| D2 | Declare `NSLocalNetworkUsageDescription`, or document why inbound OSC needs none | `DEC-0008` |
| D3 | Make `CameraFrameSource` retry after a denied/failed start and ignore late callbacks after `stop()` | — |
| D13 | Add tests for `PermissionGuidance`, `CameraFrameSource`, `MovieFrameSource` (device-dependent) | — |
| D1, D9, D10, D11 | Remove or wire up the dead state and hardcoded architecture string | — |
| D5, D6, D7 | Decide the intended multi-camera / shared-asset / cache-eviction behaviour, then implement | `DEC-0009` |
| D4, D8 | Bound MIDI retired-context retention; surface malformed-OSC drops as a diagnostic | — |
| D12 | Reschedule autosave for assets-only changes | — |
| D14 | Cover the evaluation budget and nesting depth with tests | `DEC-0007` |
| D16 | Decide whether `TexturePool` needs a capacity bound | `DEC-0013` |
| D17 | Verify or correct the README Xcode floor | — |

## Later — capability roadmap

These are the directions the project brief points at but that are **not implemented**:

- **OSC output** — send parameter changes and transport to other tools. Needs a decision record
  for the address scheme and rate.
- **Screen capture input** — needs a permission-request flow and a decision on frame pacing.
- **MIDI 2.0 and sysex** — the parser currently accepts only UMP MIDI 1.0 Channel Voice.
- **Audio** — there is no audio engine at all. Any audio work is a new subsystem with its own
  architecture and realtime decisions; do not describe the app as audio-capable before then.
- **Native fullscreen output** — the current output is a borderless window; a native fullscreen
  path would need display-change handling.
- **`.qtz` import** — deliberately absent; the QC catalog is reference data, not a runtime.

## Process roadmap

- Keep `Scripts/verify-docs --strict` green and extend it as the wiki grows.
- Add a CI job that runs the docs gate on every push and, where a runner with a GUI Metal stack
  exists, the full `Scripts/verify.sh`.
- Re-derive the test inventory in `../PROJECT_MAP.md` whenever a suite changes.
