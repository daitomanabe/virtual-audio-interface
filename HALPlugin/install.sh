#!/bin/bash
# Build, ad-hoc sign, install the HAL plugin and restart coreaudiod. Needs sudo.
set -e
cd "$(dirname "$0")"
make
codesign --force --sign - build/VirtualAudioInterfaceDriver.driver
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VirtualAudioInterfaceDriver.driver
sudo cp -R build/VirtualAudioInterfaceDriver.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod
for i in 1 2 3 4 5 6; do
  sleep 2
  if system_profiler SPAudioDataType | grep -A4 "Virtual Audio Interface"; then exit 0; fi
done
echo "device not found — check: log show --last 2m --predicate 'process == \"coreaudiod\"'"
