#!/bin/bash
# Removes Virtual Audio Interface (app + HAL driver) installed by the .pkg.
# Needs root: re-run with sudo.
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "This needs root privileges. Re-run as:" >&2
  echo "  sudo $0" >&2
  exit 1
fi

if pgrep -f "VirtualAudioInterface.app/Contents/MacOS/VisualizerApp" >/dev/null 2>&1; then
  echo "Virtual Audio Interface is running — quit it first, then re-run this script." >&2
  exit 1
fi

echo "==> Removing /Applications/VirtualAudioInterface.app"
rm -rf /Applications/VirtualAudioInterface.app

echo "==> Removing /Library/Audio/Plug-Ins/HAL/VirtualAudioInterfaceDriver.driver"
rm -rf /Library/Audio/Plug-Ins/HAL/VirtualAudioInterfaceDriver.driver

echo "==> Forgetting package receipts"
pkgutil --forget com.daitomanabe.virtualaudiointerface.app.pkg 2>/dev/null || true
pkgutil --forget com.daitomanabe.virtualaudiointerface.driver.pkg 2>/dev/null || true

echo "==> Restarting coreaudiod"
killall coreaudiod 2>/dev/null || true

echo "Uninstalled. Other audio devices may have glitched briefly while coreaudiod restarted."
