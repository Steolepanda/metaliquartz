---
id: DEC-0011
status: accepted
date: 2026-09-25
---

# Ship both a modern workspace and a Quartz Composer 4 legacy workspace

## Context

The project is inspired by Quartz Composer, whose 4.x editor used free-floating utility panels. A
single modern SwiftUI layout is easier to maintain, but long-time QC users reach for the panel
workflow, and the project explicitly targets that muscle memory.

## Decision

Support two interface styles and persist the choice:

- **Modern** — library, inspector and viewer in fixed SwiftUI regions.
- **Legacy (Quartz Composer 4)** — the same regions in detachable `NSPanel`s created by
  `LegacyPanelCoordinator`, with frame autosave (`Metaliquartz.Legacy.<kind>.frame`) and clamping
  to the visible screen, plus a rotary-fader control style.

`InterfaceStyle` is stored in `interfaceStyle`; an empty value means the app must ask on first
launch (`InterfaceChoiceView`, non-dismissable). Settings can switch later. UI tests force a style
through `MQ_INTERFACE_STYLE` and force all legacy panels docked and visible.

## Consequences

- Two layouts to keep working; the legacy workspace is the only place `NSPanel` lifecycle, frame
  autosave and screen clamping exist, and it has its own tests
  (`Tests/LegacyInterfaceAndImportTests.swift`).
- First launch cannot be skipped, so the app never guesses a style.
- Legacy panels are child windows of the editor; the viewer has its own coordinator instance while
  library and inspector share a process-wide one, an asymmetry worth remembering when changing
  panel behaviour.
- Removing either style later is a user-visible change requiring a migration for the stored
  preference and a new decision record.
