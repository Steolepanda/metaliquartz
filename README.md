# Metaliquartz

Metaliquartz is an Apple-silicon-native visual patching environment for macOS, inspired by
Quartz Composer and built on Metal. It is developed as a personal live-performance instrument with
document-based compositions, a visual graph editor, GPU image processing, reusable macros,
fullscreen output, and Metal-only Syphon sharing. Published parameters can be driven live by
CoreMIDI CC, notes and pitch bend, or by OSC 1.0 messages over UDP.

It is a macOS app built as an Xcode project (`Metaliquartz.xcodeproj`), not a Swift package.

## Start here

- **Just want to run it?** [wiki/manual/getting-started.md](wiki/manual/getting-started.md)
- **Driving it live (MIDI, OSC, output)?** [wiki/manual/live-control.md](wiki/manual/live-control.md)
- **Contributing or resuming work?** [AGENTS.md](AGENTS.md), then
  [wiki/CURRENT_STATE.md](wiki/CURRENT_STATE.md), then
  [wiki/PROJECT_MAP.md](wiki/PROJECT_MAP.md)
- **Understanding the code?** [wiki/architecture/overview.md](wiki/architecture/overview.md)

## Verify

```sh
Scripts/verify.sh        # lint, generated-definition check, Debug build, unit + UI tests, Release build
Scripts/verify-docs      # documentation structure only (links, anchors, decisions, fixtures)
```

The UI journeys require an unlocked desktop session. Full requirements and setup are in
[wiki/manual/getting-started.md](wiki/manual/getting-started.md); what counts as evidence is
defined in [docs/verification/README.md](docs/verification/README.md).

## Documentation map

| Document | Contents |
| --- | --- |
| [AGENTS.md](AGENTS.md) | Engineering constraints, the 4-step handoff loop, documentation obligations |
| [wiki/CURRENT_STATE.md](wiki/CURRENT_STATE.md) | Short operational handoff: health, truth, next actions, blockers, known problems |
| [wiki/PROJECT_MAP.md](wiki/PROJECT_MAP.md) | Source map, test inventory, source-to-docs ownership map |
| [wiki/architecture/overview.md](wiki/architecture/overview.md) | Stack, runtime shape, subsystem boundaries |
| [wiki/systems/](wiki/systems/) | One page per subsystem: graph runtime, renderer, documents/editor, live control/media, deployment |
| [wiki/manual/](wiki/manual/) | User-facing behaviour, and the [release runbook](wiki/manual/release-runbook.md) |
| [wiki/roadmap/ROADMAP.md](wiki/roadmap/ROADMAP.md) | Planned and deferred work |
| [wiki/changelog/CHANGELOG.md](wiki/changelog/CHANGELOG.md) | Dated history |
| [wiki/decisions/](wiki/decisions/) | Decision records and their registry |
| [wiki/evidence/](wiki/evidence/), [docs/verification/](docs/verification/) | Verification events and the evidence rules |
| [PROJECT_STATUS.md](PROJECT_STATUS.md) | Superseded handoff, kept for history (see note inside) |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | Third-party license notices |

## Notable boundaries

- **No audio engine, no `.qtz` import, no recording, no screen capture.** The Quartz Composer
  catalogue is reconstructed reference data, not a QC plugin runtime.
- **App Sandbox is disabled** because the direct-distribution app needs flexible file, camera,
  display, network and Syphon access ([DEC-0005](wiki/decisions/DEC-0005-app-sandbox-disabled.md)).
- **Alpha builds are ad hoc signed**, not notarized
  ([DEC-0006](wiki/decisions/DEC-0006-ad-hoc-signing-for-alpha.md)).
- The only third-party dependency is vendored Syphon under `Vendor/Syphon`.
- Local upstream reference material stays under `Documentation` and is excluded from public
  source packages. Supplied brand artwork lives under `Design/References`.

## Prepare a GitHub source package

```sh
python3 Scripts/prepare-github-package.py
```

The audited ZIP, checksum and file manifest are written to ignored `dist/github/`. The ZIP
contains current source and maintained docs without old Git history or local references.
See [source-package verification](docs/verification/README.md#public-source-packages) before
creating a fresh repository from it.
