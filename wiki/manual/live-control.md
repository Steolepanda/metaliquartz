# Live control and output

This page covers driving a composition with MIDI or OSC, publishing parameters, and getting the
result out of the app. It describes what exists today; deferred capabilities are labelled.

## Publishing a parameter

1. Select a patch and open the **Inspector**.
2. Publish the parameter you want to control.
3. Open **Live Session** to see it under Published Parameters.

Each published parameter gets a name, an output range and an optional smoothing time (0…5
seconds). The name determines its default OSC address.

## MIDI

Supported input is MIDI 1.0 Channel Voice over CoreMIDI:

| Message | Behaviour |
| --- | --- |
| Control change | Continuous value |
| Note on / note off | Value, with note-off treated as velocity 0 (a gate) |
| Pitch bend | Continuous value over the full 14-bit range |

Use **MIDI Learn** and then move a control: the first matching message binds that parameter,
replacing any previous MIDI binding for it. A mapping can additionally filter by device and MIDI
channel, and remap the incoming `0…1` value into an output range.

*Not accepted:* polyphonic aftertouch, program change, channel pressure, sysex, RPN/NRPN. Those
messages are ignored.

## OSC

The app listens for OSC 1.0 over UDP. Port 9000 is the default and is stored per composition.

Decoded argument types are `i` (int32), `f` (float32), `s` (string), `T` (true) and `F` (false),
inside single messages or ordered nested bundles, with time tags honoured. Address patterns are
matched.

A published parameter named `Glow Intensity` defaults to `/metaliquartz/glow-intensity`. Custom
addresses can be mapped per parameter.

*Not decoded:* blob, int64, double, timetag arguments, symbol, char, RGBA, MIDI, nil and array
argument types. A bundle element with an unsupported type is skipped and its siblings still
arrive; a packet with any other structural problem is discarded.

*Deferred:* sending OSC out.

## Smoothing

Set a smoothing time to glide between incoming values. The app advances the value continuously
toward the latest target rather than jumping, which makes fader moves usable on stage.

## Presets

The live session stores presets of published parameter values inside the document and recalls them
without recompiling the graph.

## Output

- Pick an output display and resolution (1280×720, 1920×1080 or 3840×2160).
- Output opens a borderless black window covering the chosen display. It is **not** native macOS
  fullscreen; use the overlay button or Escape to leave.
- The main window preview and the output share the same renderer.

## Syphon input and output

- Add a **Syphon Input** patch and choose a published server in the inspector to receive its
  frames.
- Add a **Syphon Output** patch to publish the composition's frames for other applications.

Only Syphon's Metal path is used, so textures are never copied through the CPU.

## Diagnostics while performing

The live session shows frame counters and node errors:

- Rolling CPU and GPU frame time, and a p95 frame time over a rolling window.
- Dropped-frame percentage, measured as the share of frames slower than 20 ms.
- Texture-pool usage and any node-local errors.
- A **diagnostic report export** containing system, renderer and structured-log details.

The dropped-frame number is a slowness indicator, not a count of frames the system discarded.

## Permissions

The panel reports camera and screen-recording readiness with a direct link to System Settings.
Camera capture asks for permission the first time. Screen-recording readiness is binary
(ready / denied) because only the preflight check is consulted. There is currently no in-app
request flow for screen recording, and screen-capture patches are not implemented.

## Recovery

Snapshots are written automatically after a short debounce while you edit, and can be saved,
restored or deleted manually from **Live Session → Recovery**. An unclean exit is detected on the
next launch and noted in the local log.
