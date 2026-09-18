# TODO

Planned work, roughly in priority order within each section. Contributions welcome.
日本語の概要は [README.ja.md](README.ja.md#todo) を参照してください。

## UI polish

- [x] Visual design pass: color, type, spacing and radius tokens (`Theme.swift`) in every view; light and dark reviewed
- [x] App icon (`packaging/icon/make_icon.swift`) and the standard About panel
- [ ] Meters: selectable layout (grid / horizontal strip), channels-per-row zoom, dB scale labels, value readout on hover
- [x] Meters: group channels by SSD speaker layer (Layout mode: height groups, Unassigned with signal)
- [ ] Monitor: avoid overlapping labels for nearby speakers and scene objects (the light rows and the room
      label in `Examples/FIL-v1.sscene`, Top view with Channel + name labels), add a color/level legend
- [x] Monitor: visualize Gain and Delay (Gain drives the level display; both in the Channel + name labels and the speaker table)
- [ ] Monitor: draw speaker aim once SSD defines a speaker forward axis
- [ ] Routing panel: sortable columns, search, copy warnings to clipboard
- [ ] Driver controls: progress feedback while coreaudiod restarts, clearer error messages
- [ ] Menu bar status item (driver state, quick ON/OFF) so the window can stay closed
- [ ] First-run onboarding (install driver → select device in DAW → load .sscene)
- [x] UI text in English throughout (no Japanese localization planned)

## Testing and debugging features

- [x] Built-in test signal generator: pink noise or sine, selected channel / step through SSD speakers or all channels / all at once, `--test-signal` CLI
- [ ] Pass-through to a real audio interface so you can listen while visualizing
- [ ] Energy/velocity vector (rE / rV) display to check panning and localization
- [ ] Record and replay meter sessions for offline debugging
- [ ] OSC output of per-channel levels
- [ ] Import other speaker layout formats (e.g. ADM, IEM AllRADecoder JSON)

## Driver

- [ ] Device name follows the configured channel count (currently fixed "(128ch)")
- [ ] Per-channel mute / trim controls exposed as HAL controls
- [ ] Optional input stream (loopback) so other apps can record what the DAW sends
- [ ] Settable safety offset / latency reporting
- [ ] Restrict the shared-memory config area (currently writable by any local process)
- [ ] Privileged helper (SMAppService) so ON/OFF does not ask for a password every time

## Performance

- [ ] Reduce CPU use (currently ~30% visible / ~25% hidden on Apple silicon with 128 channels at 60 Hz):
      publish only changed meter values, skip SwiftUI updates while the window is occluded, lower the
      3D update rate when nothing changes

## Distribution

- [ ] Developer ID signing and notarization for the app, driver and installer
- [ ] GitHub Actions: build, `make -C Tools check`, `make -C Tools harness`, docshot screenshots
- [ ] Homebrew cask

## Known limitations

- The installer and app are not notarized; Gatekeeper asks for confirmation on first launch.
- Turning the driver ON/OFF restarts `coreaudiod`, which briefly interrupts every audio device.
- `Tools/fake_meter` writes the same shared memory as the driver; use it only while the driver is OFF.
- SSD speaker orientation is not visualized because the format does not define a speaker forward axis.
