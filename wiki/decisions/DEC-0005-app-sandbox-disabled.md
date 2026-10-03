---
id: DEC-0005
status: accepted
date: 2026-09-25
---

# App Sandbox stays disabled for direct distribution

## Context

The app reads and writes user-chosen files anywhere, embeds media into documents, captures camera
and screen, listens on a UDP port, drives external displays and shares frames through Syphon. An
App Store sandbox would require a designed access story for each of those — security-scoped
bookmarks, camera and microphone entitlements, network server/client entitlements, and a
screen-capture exception — none of which exist today.

## Decision

Keep `ENABLE_APP_SANDBOX = NO` and distribute directly (ad hoc / Developer ID), not through the
Mac App Store. Enabling the sandbox is a designed change with its own decision record, not a build
flag flip. Until then, do not add sandbox entitlements or claim sandbox compatibility.

## Consequences

- File, camera, display and network access keep working without bookmark plumbing.
- The app cannot be distributed through the Mac App Store in this form.
- There is a documented gap: a sandboxed build would need entitlements for files, network control,
  Syphon, screen capture and external media devices all at once.
- `PermissionGuidance` currently hardcodes external access as ready on the basis of this decision;
  if the sandbox is ever enabled, that hardcode becomes wrong and must change with it.
- macOS privacy prompts still apply; disabling the sandbox does not remove TCC prompts for camera
  or screen recording.
