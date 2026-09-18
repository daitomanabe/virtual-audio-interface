# TODO

Planned work, roughly in priority order within each section. Contributions welcome.
日本語の概要は [README.ja.md](README.ja.md#todo) を参照してください。

## UI polish

- [ ] Visual design pass: consistent typography, spacing and color tokens; review light and dark appearance
- [ ] App icon and a proper About panel
- [ ] Meters: selectable layout (grid / horizontal strip), channels-per-row zoom, dB scale labels, value readout on hover
- [ ] Meters: group channels by SSD speaker layer (e.g. ear level / upper / ceiling / subs)
- [ ] Monitor: avoid overlapping labels for nearby speakers, add a color/level legend
- [ ] Monitor: show Delay graphically (Gain already drives the level display; both are in the Ch + Name labels)
- [ ] Monitor: draw speaker aim once SSD defines a speaker forward axis
- [ ] Routing panel: sortable columns, search, copy warnings to clipboard
- [ ] Driver controls: progress feedback while coreaudiod restarts, clearer error messages
- [ ] Menu bar status item (driver state, quick ON/OFF) so the window can stay closed
- [ ] First-run onboarding (install driver → select device in DAW → load .sscene)
- [ ] Localize UI strings (English / Japanese)

## Testing and debugging features

- [ ] Built-in test signal generator: pink noise or tone per channel, auto-step through SSD speakers
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

## Distribution

- [ ] Developer ID signing and notarization for the app, driver and installer
- [ ] GitHub Actions: build, `make -C Tools check`, `make -C Tools harness`, docshot screenshots
- [ ] Homebrew cask

## Known limitations

- The installer and app are not notarized; Gatekeeper asks for confirmation on first launch.
- Turning the driver ON/OFF restarts `coreaudiod`, which briefly interrupts every audio device.
- `Tools/fake_meter` writes the same shared memory as the driver; use it only while the driver is OFF.
- SSD speaker orientation is not visualized because the format does not define a speaker forward axis.
