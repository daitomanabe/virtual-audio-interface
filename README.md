# Virtual Audio Interface

A 128-channel virtual audio interface for macOS with a built-in visualizer for spatial audio debugging.
Your DAW sees it as an ordinary output device; the app shows what arrives on every channel and which
speaker of your layout (`.sscene`) it would come out of.

[日本語 README](README.ja.md)

![Monitor tab: speaker layout from a .sscene file with live levels and routing warnings](docs/images/monitor-perspective.png)

## Why

Debugging a spatial audio setup usually means sitting in front of the actual speaker system: is channel 17
really the ceiling speaker, did the panner send anything to a muted speaker, is a bus accidentally routed
to a channel nobody listens to? Virtual Audio Interface lets you do that check anywhere. It shows up in
Ableton Live (or any Core Audio app) as a real audio interface, so the signal chain stays exactly as it
will be on site, and the app visualizes the result: per-channel meters, the speaker layout in 3D with
the sounding speakers lit up, and warnings for routing mistakes.

## Features

- **Virtual output device** — up to 128 channels, 44.1 / 48 / 88.2 / 96 kHz, implemented as a Core Audio
  HAL plug-in (AudioServerPlugIn). Channel count and sample rate can be changed from the app.
- **Meters** — dBFS meters for every channel with RMS, peak, peak hold and latched clip indicators,
  stretched to fill the window. **All channels** shows 1–128 in order; **Layout** groups the loaded
  layout's channels by speaker height (see [Meters](#meters)). Signal on a channel without a speaker is
  marked *NO SPK*; channels whose speakers are all muted or disabled are grayed out with *MUTE* / *OFF*.
- **Monitor** — loads an SSD (`.sscene`) speaker layout and shows it as a plan view, front/side
  elevations or a free 3D view. Speakers light up by level (optionally input level + the layout's Gain);
  optional lines from the listener show what is sounding right now. Screens, LED walls, projectors, cameras,
  boxes and FOVs from the same file are drawn for context. Click a speaker to select it everywhere.
  The file reloads automatically when you save it.
- **Routing checks** — signal on an unassigned channel, speakers beyond the device's channel count,
  signal on muted or disabled speakers, channels shared by several speakers, parser warnings.
- **Test signal** — pink noise or a sine into the virtual device, on the selected channel, stepping through
  the layout's speakers or all channels, or on all channels at once, so the whole chain can be checked
  without a DAW (see [Test signal](#test-signal)).
- **Host-decided values** — IO buffer size, running state, client count and the sample rate the DAW asked
  for, so you can see what the host actually negotiated.
- **Driver ON / OFF / Update** from the driver menu at the top right, with verification that the driver
  process is really gone when turned off.

| Meters | Settings |
|---|---|
| ![Meters tab](docs/images/meters.png) | ![Settings tab](docs/images/settings.png) |

![Monitor tab, plan view with Channel + name labels](docs/images/monitor-top.png)

## Requirements

- macOS 13 or later, Apple silicon or Intel (universal binaries)
- A DAW or any app that can output to a Core Audio device

## Install

1. Download `VirtualAudioInterface-<version>.pkg` from [Releases](https://github.com/daitomanabe/virtual-audio-interface/releases).
2. The package is not notarized, so macOS blocks the first attempt to open it. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway** next to the message about the package.
   Alternatively, remove the quarantine flag in Terminal:
   ```bash
   xattr -d com.apple.quarantine ~/Downloads/VirtualAudioInterface-0.3.0.pkg
   ```
3. Run the installer. It installs
   - `/Applications/VirtualAudioInterface.app`
   - `/Library/Audio/Plug-Ins/HAL/VirtualAudioInterfaceDriver.driver`

   and restarts `coreaudiod` to load the driver. **Every audio device on the Mac drops out for a second
   or two** while that happens.

### Uninstall

Quit the app, then run [`packaging/uninstall.sh`](packaging/uninstall.sh) (also attached to each release):

```bash
sudo ./uninstall.sh
```

It removes the app and the driver, forgets the package receipts and restarts `coreaudiod`.
To only unload the driver and keep the app, choose **Turn Driver Off** in the app's driver menu.

## Quick start

1. Open **Virtual Audio Interface**. The dot at the top right is green when the driver is loaded; the menu
   next to it turns the driver on, updates or turns it off and shows its details.
2. In your DAW, select **Virtual Audio Interface (128ch)** as the output device.
   In Ableton Live: *Settings → Audio → Audio Output Device*, then enable the channels you need in
   *Output Config*.
3. Open a layout with **Open…** (⌘O) or drop a `.sscene` file on the window.
   Try [`Examples/FIL-v1.sscene`](Examples/FIL-v1.sscene), the scene in the screenshots: a real room with
   16 speakers, moving lights, a projector and its wall image (its channel patch is an assumption, see the
   file). [`Examples/dome-24.sscene`](Examples/dome-24.sscene) is a 24-speaker dome with gain, delay and a
   muted speaker; [`Examples/venue-demo.sscene`](Examples/venue-demo.sscene) adds a screen, LED walls,
   a projector and cameras.
4. Play. The **Monitor** tab lights up the speakers that receive signal; **Meters** shows every channel.
   No DAW at hand? Start the **Test signal** (second row, right).

The top row shows the file and when it was read, the device format (e.g. *128 ch · 48 kHz*) and the driver.
The second row holds the current tab's controls (Monitor: camera presets and the **View** menu with sounding
lines, scene objects, Apply SSD gain and labels; Meters: All channels / Layout and Reset Clips) and the test
signal. The 3D view and the meters stay dark in light mode too.

The app reopens the last layout on the next launch. Saving the file in an editor reloads it automatically
and keeps the view and selection; if the saved file does not parse (e.g. half-written), the last valid
version stays on screen under an error banner. **Reload** (⌘R) re-reads the file and re-frames the view.

## Meters

**All channels** shows every channel of the device in order. **Layout** needs a loaded `.sscene`: it groups
the layout's channels by speaker height, highest first (a new group starts where adjacent speakers are more
than 0.5 m apart in Z), each headed like *z ≈ 2.7 m · 6 speakers*. Channels above −60 dBFS that no speaker
uses follow as **Unassigned with signal**. The groups flow across the window and the meters stretch to its
height. Click a meter to select that channel everywhere.

| Mark | Meaning |
|---|---|
| red frame, *NO SPK* | signal on a channel without a speaker |
| gray bar, *MUTE* / *OFF* | every speaker on the channel is muted / disabled; orange frame while signal still arrives |
| red dot at the top | the channel clipped (latched until **Reset Clips**) |

## Test signal

The test signal plays into the virtual device from the app itself (mixed with anything your DAW sends), so
the Monitor and Meters tabs, the routing checks and your speaker layout can be checked without a DAW. It
needs the driver ON.

- **Signal**: pink noise, or a sine at 63 Hz – 8 kHz. **Level**: −60 to 0 dBFS (sine: peak, pink noise: RMS).
- **Target**:
  - **Selected channel** — the channel selected in the 3D view, the speaker table or the meters.
  - **Step through SSD speakers** — each channel of the layout's enabled, unmuted speakers in turn.
  - **Step through all channels** — channels 1 … N of the device in turn.
  - **All channels at once**.
- **Dwell** (while stepping): 0.25–5 s per channel. Stepping moves the selection along, so the 3D view,
  the table and the meters follow the channel that is playing.

It stops when you stop it, close the window or quit. From Terminal, without a window:

```bash
dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --test-signal <channel> <seconds> [pink|sine] [dBFS]
# e.g. 2 s of pink noise on channel 17 at -20 dBFS (sine is 1 kHz)
dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --test-signal 17 2 pink -20
```

## Speaker layouts (SSD / .sscene)

Layouts use SSD (Spatial Scene Definition) v0.1, a tab-separated text format documented in
[daitomanabe/ssd-format](https://github.com/daitomanabe/ssd-format). Speakers are defined by the
sections below; the other objects of a scene are drawn for context (see [Scene objects](#scene-objects)).

```text
[SCENE]
Version	0.1
Name	ring-8
Unit	meter
CoordinateSystem	SSD_RH_ZUP
AngleUnit	degree

[OBJECT]
# ID	Type	Name	Parent	X	Y	Z	Yaw	Pitch	Roll	Enabled
1	speaker	SP1	none	0.000	3.000	1.2	0	0	0	1
2	speaker	SP2	none	2.121	2.121	1.2	0	0	0	1

[SPEAKER]
# ID	Channel	Gain	Delay	Mute
1	1	0	0	0
2	2	0	0	0
```

- Right-handed, **+X right, +Y front, +Z up**, meters and degrees.
- `Parent` refers to another OBJECT (or `none`). World transform = parent × T(X,Y,Z) × Ry(Roll) · Rx(Pitch) · Rz(Yaw).
  A speaker is disabled when it or any ancestor has `Enabled` 0.
- `[SPEAKER]` maps an OBJECT of type `speaker` to a 1-based output channel; `Gain` is dB, `Delay` ms, `Mute` 0/1.
  Several speakers may share a channel.
- `[REVIEW_VOLUME]` (Width, Depth, Height) is shown as information only.
- SSD does not define a speaker's forward axis, so speaker aim is not drawn.
- **Apply SSD gain** (View menu, on by default) lights speakers by input level + `Gain`, the level expected at
  the speaker; the speaker table shows both, and the level bar sits in the column that drives the 3D view.
  Muted and disabled speakers never light up: they are ghosted (muted ones with a cross) and turn orange while
  their channel still carries signal. **Channel + name** labels (View menu) add non-zero `Gain` / `Delay`.

### Scene objects

With **View → Scene objects** on (the default), every other OBJECT is drawn in muted colors behind the speakers:

| Section / type | Drawn as |
|---|---|
| `[SCREEN]` / `[SURFACE]` (Width, Height) | translucent rectangle, outline, short tick on the front (+Z) side |
| `[LED]` (Width, Height, PixelWidth, PixelHeight) | the same with a coarse pixel grid |
| `[BOX]` (SizeX, SizeY, SizeZ), any type | wireframe box centered on the object |
| `[FOV]` (Horizontal, Vertical, Distance), any type | frustum |
| type `camera` / `projector` | small view pyramid, shaped by `[CAMERA]` FovH / FovV if present |
| `[PROJECTOR]` TargetID | dotted line from the projector to its target |
| any other type (microphone, …) | small marker; rigs that only hold other objects stay unlabeled |

Rectangles follow the spec: local X right, Y up, +Z front normal, centered; `(Yaw, Pitch, Roll) = (0, 90, 0)`
stands one upright facing world −Y. The format reference does not state an optical axis for cameras,
projectors or FOV in prose, but its reference viewer draws the FOV quad at local (±w, ±h, +Distance), and the
room datasets declare the same; **this app draws them looking along local +Z**, so `(0, −90, 0)` looks toward
world +Y and `(0, 180, 0)` looks straight down. Poses go to SceneKit as
B·M·B⁻¹ (`ssdb_matrix_to_scenekit`), never as reused Euler angles. A geometry row with invalid values is
skipped with a parser warning; the speakers still load. `[REVIEW_VOLUME]` is not drawn.

The parser ([`ssd_reader.h`](VisualizerApp/Sources/SSDBridge/ssd_reader.h)) is an independent
implementation of the format, written from the spec and cross-checked against the reference reader in
[daitomanabe/ssd-format](https://github.com/daitomanabe/ssd-format): same world transforms, enabled state,
speaker values and warnings on every example scene. It validates the header, numbers, parent references
and cycles, and reports errors with line numbers.

### Routing warnings

| Warning | When |
|---|---|
| Unassigned (red) | A channel above −60 dBFS has no speaker in the loaded layout |
| Out of range (red) | A speaker's channel exceeds the device's active channel count |
| Muted / disabled (orange) | A muted or disabled speaker's channel carries signal |
| Parser (orange) | Unknown sections and other parser warnings |
| Shared channel (blue) | Several speakers use the same channel (information) |

## Settings and host-decided values

| Set from the app | Range |
|---|---|
| Channel count | 1–128 |
| Sample rate | 44100 / 48000 / 88200 / 96000 Hz |

The **IO buffer size is chosen by the host (your DAW), not the driver**, so it is displayed but not settable.
The Settings tab also shows the effective sample rate, running state, number of clients, the rate the host
last requested and whether a settings change has been applied.

## How it works

```text
 DAW ──Core Audio (up to 128 ch)──▶ HAL plug-in ──POSIX shared memory──▶ app
                                    (runs in coreaudiod's                 ├─ Meters
                                     driver helper process)               ├─ Monitor ◀── .sscene
                                                                          └─ Settings ──config──▶ plug-in
```

- The plug-in ([`VirtualAudioDevicePlugin.cpp`](HALPlugin/src/VirtualAudioDevicePlugin.cpp)) is a from-scratch
  AudioServerPlugIn with one output device. On every IO cycle it computes per-channel peak (with decay
  ballistics, so fast transients survive the app's 60 Hz polling), RMS and clip counts.
- Levels and device status go through a fixed-size shared memory block ([`MeterShm.h`](Shared/MeterShm.h)).
  The app writes channel count / sample rate requests into the same block; the plug-in applies them through
  the regular `RequestDeviceConfigurationChange` path.
- Turning the driver ON copies it into `/Library/Audio/Plug-Ins/HAL` and restarts `coreaudiod`; OFF removes it,
  restarts `coreaudiod`, and confirms that the `Core Audio Driver (VirtualAudioInterfaceDriver.driver)` process
  and the device are gone (force-killing a leftover process by PID if needed).

## Build from source

Command Line Tools are enough (Xcode is not required).

```bash
./build_app.sh                 # driver + dist/VirtualAudioInterface.app (universal)
open dist/VirtualAudioInterface.app --args "$PWD/Examples/dome-24.sscene"
packaging/build_pkg.sh         # dist/VirtualAudioInterface-<VERSION>.pkg + .sha256
```

`HALPlugin/install.sh` installs a freshly built driver directly (development shortcut).
The version comes from [`VERSION`](VERSION); the build number is the commit count.

### Tests and tools

```bash
make -C Tools check            # shared memory + meter ballistics, SSD parser, objects and transforms,
                               # test signal DSP, file watcher
make -C Tools harness          # drives the plug-in like coreaudiod under ASan/UBSan
```

- `dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --status` prints the driver state.
- `... --docshot <dir> [scene.sscene] [--appearance light|dark] [--size WxH]` renders every tab to PNG
  (used for the screenshots above; the window is 1400×900 pt unless `--size` says otherwise).
- `... --test-signal <channel> <seconds> [pink|sine] [dBFS]` plays the [test signal](#test-signal) without a window.
- `swift packaging/icon/make_icon.swift` redraws the app icon (`packaging/icon/AppIcon.icns`).
- `Tools/fake_meter [sweep|sine|clip]` writes synthetic levels without a DAW. It uses the same shared memory
  as the driver, so run it only while the driver is OFF.

## Project layout

```text
HALPlugin/        Core Audio HAL plug-in (C++), Makefile, dev install script
Shared/           Shared memory layout used by the plug-in and the app
VisualizerApp/    Swift package: SwiftUI app, AudioBridge (shared memory), SSDBridge (SSD parser),
                  TestSignalDSP (test signal generator)
Tools/            Self-checks, HAL harness, fake meter source
Examples/         Sample .sscene layouts
packaging/        Installer (pkg) build, uninstall script, app icon
```

## Roadmap

See [TODO.md](TODO.md) — UI polish, pass-through monitoring, notarization and more.

## See also

- [daitomanabe/ssd-format](https://github.com/daitomanabe/ssd-format) — where the `.sscene` format was
  published. It has moved to `daitomanabe/spatial-scene-definition`, which holds the specification,
  the reference reader and viewer and more example scenes

## License

[MIT](LICENSE) © 2026 Daito Manabe
