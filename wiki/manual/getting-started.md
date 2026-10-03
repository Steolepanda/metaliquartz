# Getting started with Metaliquartz

This page describes **what the app does today**, migrated from the project README so the wiki is
the single home for user-facing behaviour. Anything not implemented is labelled *deferred*.

## Requirements

- Apple silicon Mac (arm64 only)
- macOS 14 or newer (asserted by the build; see `../roadmap/ROADMAP.md`)
- Xcode 26.3 or newer (the toolchain used for the latest recorded verification is Xcode 27.0)
- The Xcode Metal Toolchain component
- Developer tool automation enabled, only for the UI-test journeys

Install the Metal compiler once if it is missing:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Enable developer tool automation before running the complete verification gate:

```sh
sudo DevToolsSecurity -enable
```

## Open and run

Open `Metaliquartz.xcodeproj`, select the shared `Metaliquartz` scheme and **My Mac**, then run.
Debug builds are signed ad hoc and need no Apple Developer team.

Verify the whole project from Terminal:

```sh
Scripts/verify.sh
```

The script lints the Swift sources, checks the generated Quartz Composer definitions, builds
Debug, runs the unit and UI tests, and builds Release. The two UI journeys launch the app in both
interface styles and require an unlocked desktop session. Build products go to a temporary
directory and are removed.

## The document

A composition is a `.mquartz` package containing `composition.json` plus optional `Assets/`,
`Shaders/` and `Thumbnail.png`. Documents are versioned; version 0 and 1 files open and are
migrated forward to version 2. A file that is not a valid package, is missing
`composition.json`, or carries an unsupported version reports an actionable error and is left
untouched.

Two sample compositions ship with the app:

- **Control Modulation** — a control-signal graph with published parameters and OSC mappings.
- **Live Camera Feedback** — a camera feed through feedback processing.

## The workspace

- **Modern** interface: library, inspector and viewer in fixed regions.
- **Legacy (Quartz Composer 4)** interface: the same regions in detachable panels whose positions
  are remembered and clamped to the visible screen.

Choose the style on first launch; switch later from settings.

### Graph editing

The canvas is keyboard focusable:

- Tab / Shift-Tab move between patches.
- Arrow keys nudge selected patches.
- Return enters a selected macro.
- Command-A selects all; Command-0 resets the viewport.
- Standard copy, paste, delete, undo and redo are available.

Drag from an output port to an input port to connect. An input accepts one connection; connecting
again replaces the existing one. Feedback patches are the only way to form a loop.

### The patch library

The library is a reconstructed Quartz Composer catalogue plus the native Metaliquartz patches.
Entries marked with a lock are **catalog reference only**: they can be searched and inspected but
not added. Two OpenCL rows are marked deprecated. Only `functional` entries can be placed on the
canvas.

### Images and shaders

Drop image files (PNG or TIFF), file promises, or raw image data onto the canvas. Dropping onto an
existing image-file patch replaces its asset; dropping several files creates a row of image-file
patches. Images are embedded in the package under `Assets/`, and an asset is deleted only when no
patch in the root graph or any macro still references it.

Custom shader patches keep their source in the package under `Shaders/` and are compiled when the
graph runs; a shader that fails to compile keeps the last working pipeline and reports the error in
the inspector.

## Live session

Open **Live Session** to find transport, output display and resolution, published parameters,
MIDI/OSC mappings, presets, recovery, diagnostics, permissions and samples.

### Published parameters and control

Publish a patch parameter from its inspector, then:

- **MIDI Learn** captures a CC, note velocity/gate or pitch-bend source.
- Optional device and channel filters, output ranges and smoothing apply.
- **OSC** listens on UDP port 9000 by default, configurable per composition.
- A default address is derived from the published name, for example
  `/metaliquartz/glow-intensity`; custom addresses can be mapped instead.

OSC support covers the OSC 1.0 `i`, `f`, `s`, `T` and `F` argument types, ordered nested bundles,
time tags and address patterns. Mappings are stored inside the `.mquartz` document.

*Deferred:* OSC output, MIDI 2.0, sysex, screen capture, audio.

### Output

Choose a display and a resolution (1280×720, 1920×1080 or 3840×2160). Output opens a borderless
window on that display; it is not native macOS fullscreen. Escape or the overlay button exits.

### Recovery and diagnostics

Composition edits are debounced into recovery snapshots under Application Support; use
**Live Session → Recovery** to save, restore or delete the current snapshot. A launch marker
detects an unclean previous exit and recoverable failures are appended to a rotating local log.

The panel also shows camera and screen-recording permission status with System Settings guidance,
rolling CPU/GPU frame time, p95 frame time, dropped-frame percentage, texture-pool usage and
node-local errors, and can export a plain-text diagnostic report.

## Syphon

Metaliquartz integrates Syphon's Metal client and server only; textures stay on Metal throughout.
Pick a server in the live session to receive its frames, or add a Syphon Output patch to publish.
The framework is vendored under `Vendor/Syphon` (see `../systems/live-control-and-media.md`).

## Prepare source for GitHub

```sh
python3 Scripts/test-public-preflight.py
python3 Scripts/prepare-github-package.py
```

This creates an audited source ZIP, SHA-256 and file manifest in ignored `dist/github/`. It
includes the current working-tree code and maintained docs, excluding local reference captures,
private backups, Git history and file metadata. Unzip into a new directory before creating a
fresh GitHub repository. Keep the original `.git` out of it; run `Scripts/public-preflight.sh`
before pushing. The source package does not mean the app archive or UI/soak gates passed.
See [the verification rules](../../docs/verification/README.md#public-source-packages).

## Sharing and distribution

The alpha is ad hoc signed. Before distributing, configure a Developer ID Application certificate,
a development team, required entitlements and Apple notarization. Do not enable App Sandbox
without first designing access for files, network control, Syphon, screen capture and external
media devices (see `DEC-0005` in `../decisions/`).
