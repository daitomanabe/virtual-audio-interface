# AI_HANDOFF

> Contract: `portable-agent-handoff/v1`
> Captured: `2026-09-18T14:15:36+09:00`
> Scope: `Virtual Audio Interface — 128-channel Core Audio HAL driver plus a SwiftUI app that visualizes levels and SSD (.sscene) speaker layouts for spatial audio debugging; state after the v0.2.0 release.`

## Status

- Overall: `IN_PROGRESS` — v0.2.0 is released and working on the author's machine; the roadmap in `TODO.md` is open.
- Evidence freshness: `current` as of the capture time (commit `9435351`, tag `v0.2.0`).
- Safe continuation: `yes` — the checkout is clean and `main` equals `origin/main`. Anything that restarts `coreaudiod` or publishes needs the user's approval (see Safety Boundaries).

## Read First

1. `AGENTS.md` — build/test commands, invariants and approval rules for every agent.
2. `CLAUDE.md` — points Claude Code to the two files above and below.
3. `AI_HANDOFF.md` — this document.
4. `README.md` — user-facing behavior, install steps and architecture (English). `README.ja.md` is the Japanese version.
5. `TODO.md` — prioritized roadmap and known limitations.
6. `HALPlugin/src/VirtualAudioDevicePlugin.cpp` and `Shared/MeterShm.h` — the driver and the driver ↔ app contract.

Start by checking the real checkout, branch/worktree, and dirty state. Do not assume the path or branch named in an older note is still current.

## Source of Truth

| Area | Authoritative path or artifact | Evidence / conflict note |
| --- | --- | --- |
| Driver (AudioServerPlugIn, one 128 ch output device) | `HALPlugin/src/VirtualAudioDevicePlugin.cpp`, `HALPlugin/Info.plist`, `HALPlugin/Makefile` | `[VERIFIED]` builds warning-free; ASan harness passes |
| Driver ↔ app shared memory (`/vai_meter_v3`) | `Shared/MeterShm.h` (identical copy in `VisualizerApp/Sources/AudioBridge/include/`) | `[VERIFIED]` both copies identical at capture |
| SSD parser and bridge | `VisualizerApp/Sources/SSDBridge/ssd_reader.h`, `ssd_bridge.cpp`, `include/ssd_bridge.h` | `[VERIFIED]` independent implementation, cross-checked against the reference reader of github.com/daitomanabe/ssd-format |
| SSD format specification | github.com/daitomanabe/ssd-format (public, MIT) | `[VERIFIED]` README links it; the camera/projector optical axis is not defined there (see Blockers) |
| App (SwiftUI in an AppKit window) | `VisualizerApp/Sources/VisualizerApp/` (`App.swift` entry and CLI modes, `DriverController.swift`, `AudioLevelsModel.swift`, `SpeakerSceneView.swift`, `RoutingPanel.swift`, `LevelMeterGridView.swift`, `TestSignal*.swift`, `Theme.swift`) | `[VERIFIED]` builds with 0 warnings |
| Test signal DSP (C, realtime-safe) | `VisualizerApp/Sources/TestSignalDSP/` | `[VERIFIED]` `tsgcheck` passes; measured on the live driver |
| Version | `VERSION` (`0.2.0`); build number = `git rev-list --count HEAD` | `[VERIFIED]` |
| Packaging | `build_app.sh`, `packaging/build_pkg.sh`, `packaging/distribution.xml`, `packaging/scripts/driver/`, `packaging/uninstall.sh`, `packaging/icon/` | `[VERIFIED]` universal pkg built for v0.2.0 |
| Released artifacts | GitHub Releases `v0.1.0`, `v0.2.0` of daitomanabe/virtual-audio-interface (pkg, `.sha256`, `uninstall.sh`) | `[VERIFIED]` `gh release view v0.2.0` lists the three assets |
| Roadmap | `TODO.md` | `[VERIFIED]` updated in v0.2.0 |

## Current State

- `[VERIFIED]` `main` at `9435351`, clean, equal to `origin/main`; tags `v0.1.0`, `v0.2.0` exist locally and on GitHub. The repository is public (MIT).
- `[VERIFIED]` Signal path works end to end on the author's Mac: Ableton Live → driver → shared memory → app. Measured shm update rate ≈ 94/s at 48 kHz / 512 frames (48000 / 512 = 93.75).
- `[VERIFIED]` The driver runs in coreaudiod's helper process `Core Audio Driver (VirtualAudioInterfaceDriver.driver)`. ON/OFF/Update copies or removes the bundle in `/Library/Audio/Plug-Ins/HAL` and restarts `coreaudiod`; the app compares `VAIDriverSourceHash` (stamped by `HALPlugin/Makefile`) to decide "outdated".
- `[VERIFIED]` On the author's machine (many third-party audio drivers) `coreaudiod` stayed at ~100% CPU and unresponsive for ~2 min 20 s after the installer restarted it. CoreAudio lookups in the app were moved off the main thread because of this.
- `[STALE]` The app installed in `/Applications` on the author's machine is a v0.2.0 build made before the last two fixes (off-main-thread CoreAudio lookups, CLI device wait). The released `v0.2.0` pkg contains the fixes. Recheck with `/Applications/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --status` and reinstall from the release if needed.
- `[VERIFIED]` Git history was rewritten once before the first push to remove a vendored private file (`ssd/Scene.h`); it is absent from all published commits. Older commit messages still mention it by name, which the user accepted.
- `[INFERRED]` CPU use is high for a monitoring utility (~30% visible, ~25% hidden with 128 channels at 60 Hz, Apple silicon); basis: `ps` sampling during the App Nap test. Listed in `TODO.md → Performance`.

## Completed and Verified

- `[VERIFIED]` Driver: 1–128 channels, 44.1/48/88.2/96 kHz, config changes via `RequestDeviceConfigurationChange`, peak ballistics, RMS, clip counts.
  - Evidence: `make -C Tools harness` → `properties OK`, `io OK`, `OK` (3000 IO cycles with concurrent rate/channel changes under ASan/UBSan).
- `[VERIFIED]` Two driver bugs fixed and covered by the harness: UID lookup crash (qualifier pointer treated as a CFString) and shifted `DoIOOperation` parameters (meters never updated).
- `[VERIFIED]` Checks: `make -C Tools check` → `selfcheck OK`, `ssdcheck OK`, `tsgcheck: OK`, `watchcheck OK`.
- `[VERIFIED]` Test signal on the live driver: `--test-signal 17 3 sine -20` → ch17 peak 0.1000 (−20.0 dBFS), neighbours 0; three parallel instances on ch1/9/17 at −12 dBFS → 0.2512 each.
- `[VERIFIED]` App keeps running behind other apps: window hidden for 25 s keeps ~25% CPU (not throttled). `--docshot` captures with its window ordered behind all others (checked with the on-screen window list) and still renders SceneKit.
- `[VERIFIED]` v0.2.0 pkg: universal app and driver (`lipo -archs` → `x86_64 arm64`), both components non-relocatable, `shasum -a 256 -c` OK; installing over v0.1.0 worked on the author's machine and the driver showed ON/up to date afterwards.
- `[VERIFIED]` UI is English-only; README screenshots in `docs/images/` were captured from the v0.2.0 build with the driver ON.
- `[NOT_RUN]` Interactive GUI flows after the last fixes: Driver ON/OFF/Update clicks, test-signal play/step with selection following, auto reload while editing a file in a real editor.
  - Reason: needs a person at the GUI and admin password; required before: the next release.
- `[NOT_RUN]` macOS 13–15 and real Intel hardware (only the test signal ran under Rosetta).
  - Reason: no such machine available; required before: claiming support beyond Apple silicon on macOS 26.
- `[NOT_RUN]` Notarization / Developer ID signing. Reason: no Developer ID; the user accepted the Gatekeeper "Open Anyway" step.

## Pending Work

1. `[IN_PROGRESS]` Roadmap in `TODO.md` — the user has not picked the next item. Candidates the session considered most valuable:
   - Performance: bring CPU well below 10% (publish only changed meter values, skip SwiftUI updates while occluded, lower the 3D update rate when idle) — acceptance: `ps -o %cpu` under 10% with 128 channels playing.
   - Monitor: avoid overlapping labels for nearby speakers (visible in `dome-24` Top view with Channel + name labels).
   - Device name should follow the configured channel count (currently fixed "Virtual Audio Interface (128ch)").
2. `[UNKNOWN]` Manual GUI verification of the NOT_RUN flows above — first check: ask the user to run Driver Update, Test signal "Step through SSD speakers" on `Examples/dome-24.sscene`, and edit/save a `.sscene`.

## Blockers and Decisions Needed

- `[BLOCKED]` Notarization needs an Apple Developer ID — owner/input needed: the user; safe workaround: current ad-hoc signed pkg with documented Gatekeeper steps.
- `[UNKNOWN]` SSD v0.1 does not define the optical axis of cameras, projectors and FOVs; the app assumes local −Z (README "Scene objects"). Do not change this silently — it should be settled in github.com/daitomanabe/ssd-format first.
- `[UNKNOWN]` SSD does not define a speaker forward axis, so speaker aim is intentionally not drawn.

## Reproduction / Verification

Working directory: `${PROJECT_ROOT}`

```sh
cd "${PROJECT_ROOT}"
git status --short --branch
make -C Tools check
make -C Tools harness
./build_app.sh
dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --status
dist/VirtualAudioInterface.app/Contents/MacOS/VisualizerApp --docshot "${TMPDIR}/vai-docshot" Examples/venue-demo.sscene
```

Expected result: checks print `OK` lines; `--status` prints one line (`on=true outdated=false` when the installed driver matches this build); the docshot directory contains `monitor-*.png`, `meters*.png`, `settings.png` without any window coming to the front.

With the driver ON, `--test-signal <channel> <seconds> sine -20` should raise only that channel's peak to ≈0.1 in the shared memory (read it with a small C program including `Shared/MeterShm.h`; none is committed).

Checks not run: `[NOT_RUN]` installing a freshly built pkg or `HALPlugin/install.sh` — restarts `coreaudiod`, needs approval.

## Safety Boundaries

- `[VERIFIED]` Preserve the invariants in `AGENTS.md` (identical shm headers, single writer per shm half, realtime-safe IO paths, no main-thread CoreAudio, never activate the app, independent SSD parser, English UI).
- `[BLOCKED]` Approval required before: installing/removing the driver or restarting `coreaudiod` (interrupts all audio, possibly for minutes), `git push`, tags, releases, repository settings.
- `[VERIFIED]` Public repository: never commit private paths, email addresses, credentials, or code from private repositories.
- `[UNKNOWN]` Do not assume the author's DAW session is idle; the driver may be carrying live audio.

## Next Agent

Use this sequence:

1. Read the instruction files and the source-of-truth paths above.
2. Recheck the current checkout and dirty state.
3. Run the first focused verification command.
4. Continue item 1 under **Pending Work** only if its acceptance condition remains true.
5. Update this handoff with new evidence before ending the task.

Do not treat the conversation summary as a substitute for this document. Do not claim the work is complete until the stated acceptance evidence exists.

## Change Log

| Timestamp | Agent / session label | Change | Evidence |
| --- | --- | --- | --- |
| `2026-09-18` | `Claude Code` | initial capture after the v0.2.0 release | `make -C Tools check`, `make -C Tools harness`, `gh release view v0.2.0` |
