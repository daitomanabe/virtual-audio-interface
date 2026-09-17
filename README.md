# Virtual Audio Interface

A 128-channel virtual audio interface for macOS with a built-in visualizer for spatial audio debugging.
Your DAW sees it as an ordinary output device; the app shows what arrives on every channel and which
speaker of your layout (`.sscene`) it would come out of.

[日本語 README](README.ja.md)

![Monitor tab: speaker layout from a .sscene file with live levels and routing warnings](docs/images/monitor-top.png)

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
- **Meters** — dBFS meters for every channel with RMS, peak, peak hold and latched clip indicators.
  Channels that carry signal but have no speaker in the loaded layout are marked *unassigned*.
- **Monitor** — loads an SSD (`.sscene`) speaker layout and shows it as a plan view, front/side
  elevations or a free 3D view. Speakers light up by level; optional lines from the listener show what is
  sounding right now. Click a speaker to select it everywhere.
- **Routing checks** — signal on an unassigned channel, speakers beyond the device's channel count,
  signal on muted or disabled speakers, channels shared by several speakers, parser warnings.
- **Host-decided values** — IO buffer size, running state, client count and the sample rate the DAW asked
  for, so you can see what the host actually negotiated.
- **Driver ON / OFF / Update** from the app, with verification that the driver process is really gone
  when turned off.

| Meters | Settings |
|---|---|
| ![Meters tab](docs/images/meters.png) | ![Settings tab](docs/images/settings.png) |

![Monitor tab, perspective view](docs/images/monitor-perspective.png)

The interface labels are currently Japanese; localization is on the [roadmap](TODO.md).

## Requirements

- macOS 13 or later, Apple silicon or Intel (universal binaries)
- A DAW or any app that can output to a Core Audio device

## Install

1. Download `VirtualAudioInterface-<version>.pkg` from [Releases](https://github.com/daitomanabe/virtual-audio-interface/releases).
2. The package is not notarized, so macOS blocks the first attempt to open it. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway** next to the message about the package.
   Alternatively, remove the quarantine flag in Terminal:
   ```bash
   xattr -d com.apple.quarantine ~/Downloads/VirtualAudioInterface-0.1.0.pkg
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
To only unload the driver and keep the app, use **Driver OFF** in the app.

## Quick start

1. Open **Virtual Audio Interface**. The dot at the top right is green when the driver is loaded.
2. In your DAW, select **Virtual Audio Interface (128ch)** as the output device.
   In Ableton Live: *Settings → Audio → Audio Output Device*, then enable the channels you need in
   *Output Config*.
3. Open a layout with **Open…** (⌘O) or drop a `.sscene` file on the window.
   Try [`Examples/dome-24.sscene`](Examples/dome-24.sscene).
4. Play. The **Monitor** tab lights up the speakers that receive signal; **Meters** shows every channel.

The app reopens the last layout on the next launch; **Reload** (⌘R) picks up edits to the file.

## Speaker layouts (SSD / .sscene)

Layouts use SSD (Spatial Scene Definition) v0.1, a tab-separated text format. The app reads the sections
below; other SSD sections (screens, projectors, cameras, …) are accepted and ignored.

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

The parser ([`ssd_reader.h`](VisualizerApp/Sources/SSDBridge/ssd_reader.h)) validates the header, numbers,
parent references and cycles, and reports errors with line numbers.

### Routing warnings

| Warning | When |
|---|---|
| Unassigned (red) | A channel above −60 dBFS has no speaker |
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
make -C Tools check            # shared memory + meter ballistics, SSD parser and transforms
make -C Tools harness          # drives the plug-in like coreaudiod under ASan/UBSan
```

- `dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --status` prints the driver state.
- `... --docshot <dir> [scene.sscene]` renders every tab to PNG (used for the screenshots above).
- `Tools/fake_meter [sweep|sine|clip]` writes synthetic levels without a DAW. It uses the same shared memory
  as the driver, so run it only while the driver is OFF.

## Project layout

```text
HALPlugin/        Core Audio HAL plug-in (C++), Makefile, dev install script
Shared/           Shared memory layout used by the plug-in and the app
VisualizerApp/    Swift package: SwiftUI app, AudioBridge (shared memory), SSDBridge (SSD parser)
Tools/            Self-checks, HAL harness, fake meter source
Examples/         Sample .sscene layouts
packaging/        Installer (pkg) build, uninstall script
```

## Roadmap

See [TODO.md](TODO.md) — UI polish, a built-in test signal generator, pass-through monitoring,
notarization and more.

## License

[MIT](LICENSE) © 2026 Daito Manabe
