# Agent instructions

Rules for any coding agent (Codex, Claude Code, …) working in this repository.
Current state and open work live in [AI_HANDOFF.md](AI_HANDOFF.md); user-facing docs in [README.md](README.md).

## Build and test

```sh
./build_app.sh                 # HAL driver + dist/VirtualAudioInterface.app (universal)
packaging/build_pkg.sh         # dist/VirtualAudioInterface-<VERSION>.pkg + .sha256
make -C Tools check            # shm/meter ballistics, SSD parser + transforms, test-signal DSP, file watcher
make -C Tools harness          # drives the HAL plug-in like coreaudiod under ASan/UBSan
swift build --package-path VisualizerApp
```

Headless app modes (no window in front): `VisualizerApp --status`, `--docshot <dir> [scene.sscene] [--appearance light|dark] [--size WxH]`,
`--test-signal <channel> <seconds> [pink|sine] [dBFS]`. Look at docshot PNGs before claiming a UI change works.

README screenshots (`docs/images/`): run the bundled app (a bare `swift build` binary shows "Version ? (?)") with
`--docshot <dir> "$PWD/Examples/FIL-v1.sscene" --appearance dark --size 1400x848`, then `sips --resampleWidth 1600`.
`monitor-top`, `monitor-perspective` and `settings` keep their names; `meters.png` is the `meters-layout` shot.
The README's first image is `monitor-perspective`: the Top view draws every object's name, which overlaps in a
dense layout (TODO) and should not be the first thing a visitor sees.

If the x86_64 Swift build fails with "not registered", delete `VisualizerApp/.build/x86_64-apple-macosx` (build_app.sh retries once).

## Invariants

- `Shared/MeterShm.h` and `VisualizerApp/Sources/AudioBridge/include/MeterShm.h` must stay byte-identical (`diff` them).
  Changing the layout means a new `VAI_SHM_NAME` / magic and reinstalling the driver.
- The shared memory has one writer per half: the driver writes status/levels, the app writes the config half.
  Tools (`selfcheck`, harness) must never write config to the live segment; the harness uses its own name.
- Realtime paths (`Plugin_DoIOOperation`, the test-signal render callback in `TestSignalDSP`) must not allocate, lock,
  log or call Objective-C/Swift runtime code.
- Never call CoreAudio (`AudioObjectGetPropertyData` etc.) on the main thread: `coreaudiod` can be unresponsive for
  minutes after a restart and the UI would freeze.
- Never bring the app to the front (`NSApp.activate`, `orderFrontRegardless`, floating levels). `--docshot` orders its
  window to the back. Keep the App Nap-suppressing activity and common-mode timers so the app keeps working behind a DAW.
- The SSD parser (`VisualizerApp/Sources/SSDBridge/ssd_reader.h`) is an independent MIT implementation. Do not copy code
  from the reference reader in github.com/daitomanabe/ssd-format; cross-check behavior against it instead.
- All UI text is English.

## Side effects that need the user's approval

- Anything that installs/removes the driver or restarts `coreaudiod` (Driver ON/OFF/Update, `HALPlugin/install.sh`,
  installing a pkg, `killall coreaudiod`): it interrupts every audio device on the machine and needs an admin password.
- `git push`, creating releases or tags, changing repository settings. This is a public repository.
- `Tools/fake_meter` writes the same shared memory as the driver; only use it while the driver is OFF.

## Commits

Commit each logical change on its own with a message that explains why. Do not commit `dist/`, build outputs or screenshots
other than the curated ones in `docs/images/`.
