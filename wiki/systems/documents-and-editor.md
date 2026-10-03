# System: documents, app lifecycle and editor

**Sources:** `Sources/App/`, `Sources/Documents/`, `Sources/Editor/`, `Sources/Resources/`
**Tests:** `Tests/CompositionModelTests.swift`, `Tests/AlphaHardeningTests.swift`,
`Tests/LegacyInterfaceAndImportTests.swift`, `Tests/LiveSessionTests.swift`,
`UITests/GoldenAuthoringJourneyUITests.swift`
**Decisions:** `DEC-0002` (format), `DEC-0003` (health log), `DEC-0011` (dual interface)

## Purpose

Own the user's document on disk, the application lifecycle, and the editing surface. It is a
SwiftUI `DocumentGroup` app whose graph canvas is AppKit, whose live-session panel hosts MIDI/OSC
and diagnostics, and whose recovery/health behaviour is designed for a live-performance tool that
may be killed mid-show.

## Key files

| File | Responsibility | ~Lines |
| --- | --- | --- |
| `Sources/App/MetaliquartzApp.swift` | `@main` scene, `DocumentGroup`, Settings, commands, default window 1280×820 | 21 |
| `Sources/App/ApplicationHealth.swift` | `ApplicationHealthStore` (log dir, launch markers, rotation, diagnostic report/export) and `ApplicationLifecycleDelegate` | 231 |
| `Sources/App/InterfacePreferences.swift` | Interface style, numeric-control style, category colours, legacy panel preferences, UI-test configuration, settings scene | 423 |
| `Sources/Documents/CompositionDocument.swift` | `FileDocument` package read/write, entry-name validation, shader hydrate/externalize | 213 |
| `Sources/Documents/SampleCompositions.swift` | Two built-in samples built from `PatchRegistry` | 149 |
| `Sources/Editor/EditorShellView.swift` | Editor session, shell, autosave task, modern/legacy workspaces, macro creation, image-drop handling, `NSPanel` coordinator | 1971 |
| `Sources/Editor/GraphCanvasView.swift` | `GraphCommandExecutor` (undo), canvas `NSView` (draw, hit-test, drag-connect, marquee, pan/zoom, clipboard, accessibility) | 1261 |
| `Sources/Editor/LiveSession.swift` | `LiveOutputResolution`, fullscreen controller/state, `ProjectRecoveryStore`, published-parameter helpers, live-session panel | 1162 |
| `Sources/Editor/ImageDropImport.swift` | Pasteboard/file-promise/raw-image resolution and asset import mutation | 414 |
| `Sources/Editor/RotaryFader.swift` | Rotary fader mapping and AppKit control | 171 |
| `Sources/Resources/Info.plist` | Bundle id, document type/UTI, camera usage string, high-resolution support | — |

## Document flow

**Open.** `CompositionDocument.init(packageWrapper:)` requires a directory (`expectedPackage`),
requires `composition.json` (`missingComposition`), validates every entry name recursively
(`unsafePackageEntry`), decodes the JSON (bad decode is logged under the `document` category and
rethrown as `unreadableComposition`), reads `Assets/`, `Shaders/` and `Thumbnail.png`, then
hydrates `shaderSource` for `.customShader` nodes in the root graph **and** each macro graph.

**Package layout written.** `composition.json`, `Assets/`, `Shaders/`, and `Thumbnail.png` only
when present. Custom shader sources are externalized to `Shaders/<shaderFile ?? "<nodeID>.metal">`
and the `shaderSource` key removed before writing; JSON is pretty-printed with sorted keys.

**Recovery.** `ProjectRecoveryStore` writes
`Application Support/Metaliquartz/Recovery/<composition.metadata.id>.mquartz` atomically. The
editor autosaves through a cancellation-based 2 s debounce (`task(id: document.composition)` with
`Task.sleep`), skipped entirely when `MQ_UI_TESTING=1`. Manual save/restore/delete is in the live
session panel. `availableSnapshots` lists snapshots newest-first.

**Health.** `ApplicationHealthStore` writes `Application Support/Metaliquartz/Logs/metaliquartz.log`
plus an `OSLog` channel (`com.steolepanda.Metaliquartz`, category `application`). A launch writes
`running-<pid>.marker`; a marker whose PID is no longer alive is treated as an unclean exit, logged
and removed. The log rotates once past 1 000 000 bytes into a single `metaliquartz.previous.log`.
The diagnostic report includes system, renderer snapshot and the whole log, exported through a
save panel as `Metaliquartz-Diagnostics.txt`.

## Image drop import

The canvas registers `.string`, `.fileURL`, `.png`, `.tiff` and `NSFilePromiseReceiver` types.
A drop resolves file URLs (security-scoped, validated by `CGImageSource`), file promises
(received into a temporary `MetaliquartzDrops-<UUID>` directory and deleted afterwards) or raw
image data. Each payload must be at most 256 MB and decodable. `ImageImportMutation.apply`
replaces the target image-file node's asset when dropping onto one, creates new image-file nodes
for the rest on a three-per-row grid (dx 222, dy 126), stores assets under
`<newUUID>-<sanitizedFilename>`, and deletes a replaced asset only if no node in the root graph or
any macro still references it.

## Workspaces

Two interface styles, chosen on first launch and switchable later:

- **Modern** — fixed SwiftUI library/inspector/viewer regions.
- **Legacy (Quartz Composer 4)** — detachable `NSPanel` windows with frame autosave
  (`Metaliquartz.Legacy.<kind>.frame`) and clamping to the visible screen.

The choice is persisted in `interfaceStyle`; an empty value means "ask on first launch". UI tests
set `MQ_UI_TESTING=1` and `MQ_INTERFACE_STYLE`, and force all legacy panels docked and visible.

## Live output

`FullscreenOutputController` presents a borderless black window on the selected `NSScreen` (or the
main screen), sized to the screen frame, hosting `MetalPreviewView` with a forced drawable size
from `LiveOutputResolution` (1280×720, 1920×1080 default, 3840×2160). It is not native
`NSWindow` fullscreen — it joins all spaces and uses the auxiliary full-screen behaviour. Escape
or the overlay button exits.

## Concurrency

- `EditorSession`, `GraphCommandExecutor`, the canvas coordinator, `ImageDropResolver`,
  `FilePromiseAccumulator`, `FullscreenOutputState`/`Controller`, `LegacyPanelCoordinator` and
  `ApplicationLifecycleDelegate` are `@MainActor`.
- Exactly two structured background tasks exist here: the 2 s autosave sleep and one image-drop
  read task, which inherits the MainActor. There are no timers.
- `ApplicationHealthStore` guards all of its file work with a static `NSLock`.
- AppKit hosting resolves the parent window through `DispatchQueue.main.async`.

## Exact constants

| Constant | Value | Where |
| --- | --- | --- |
| Default window | 1280×820, `.titleBar` | `MetaliquartzApp` |
| Autosave debounce | 2 s, skipped when `MQ_UI_TESTING=1` | `EditorShellView` |
| Recovery directory / snapshot name | `Metaliquartz/Recovery` / `<metadata.id>.mquartz` | `ProjectRecoveryStore` |
| Log directory / file / previous | `Metaliquartz/Logs` / `metaliquartz.log` / `metaliquartz.previous.log` | `ApplicationHealthStore` |
| Log rotation threshold | `> 1_000_000` bytes | `ApplicationHealthStore` |
| Launch marker | `running-<pid>.marker` | `ApplicationHealthStore` |
| Image drop limit / grid | 256 MB, 3 per row, 222×126 | `ImageDropImport` |
| Legacy panel defaults | library 272×540, inspector 320×580, viewer 520×390; clamp margin 16 | `InterfacePreferences` |
| Rotary fader arc | −135°…135° | `RotaryFader` |
| Built-in samples | "Control Modulation", "Live Camera Feedback" | `SampleCompositions` |

## Invariants and rejection rules

- Package entry names may not be empty, `.`, `..`, or contain `/`, `\` or control characters —
  checked recursively for directories too.
- A corrupted package produces an actionable error and is **not** modified; the user is pointed at
  the recovery snapshot or a backup.
- Decoding rejects a wrong format and unsupported versions (see `systems/graph-runtime.md`).
- Macro conversion requires a non-empty selection whose nodes all exist in the active graph, and a
  valid post-conversion macro library.
- First-run choice cannot be dismissed without choosing; unset legacy panel visibility defaults to
  visible, unset docking defaults to detached.

## Known limits

- `EditorSession.isImportingImages` is dead state (finding D1).
- The autosave task keyed only on `document.composition` does not reschedule for assets-only
  changes (finding D12).
- `diagnosticReport` hardcodes `Architecture: arm64` (finding D11).
- The advertised fullscreen output is a borderless window, not native fullscreen (finding D15).
- `SampleCompositionLibrary` uses `preconditionFailure` when a built-in patch or port is missing,
  so a registry regression crashes at sample-load time rather than failing gracefully.
- The graph canvas's `init?(coder:)` is unavailable and traps; the canvas is code-created only.
- UI tests need an unlocked, logged-in GUI session and fail rather than skip without one.

## Tests that protect this

| Behaviour | Test |
| --- | --- |
| Package layout and round-trip, version migration | `CompositionModelTests` |
| Unclean launch, corrupted packages, samples, recovery enumeration, diagnostics export, canvas accessibility | `AlphaHardeningTests` |
| Interface choice, legacy panel frames, drop validation and layout, asset GC, macro-local import | `LegacyInterfaceAndImportTests` |
| Live settings round-trip, recovery snapshot, diagnostics, resolution, fullscreen state | `LiveSessionTests` |
| End-to-end modern and legacy authoring journeys | `GoldenAuthoringJourneyUITests` |
