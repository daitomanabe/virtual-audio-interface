#!/bin/zsh
# Builds dist/VirtualAudioInterface-<VERSION>.pkg from a fresh ./build_app.sh
# output. Two required components (see packaging/distribution.xml):
#   /Applications/VirtualAudioInterface.app
#   /Library/Audio/Plug-Ins/HAL/VirtualAudioInterfaceDriver.driver
set -e
cd "$(dirname "$0")/.."   # repo root

VERSION=$(<VERSION)
PKG_APP_ID="com.daitomanabe.virtualaudiointerface.app.pkg"
PKG_DRIVER_ID="com.daitomanabe.virtualaudiointerface.driver.pkg"
OUT="dist/VirtualAudioInterface-$VERSION.pkg"

echo "==> Building app + driver"
./build_app.sh

WORK=$(mktemp -d /tmp/vai-pkg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- App component: /Applications/VirtualAudioInterface.app --------------
echo "==> Packaging app component"
APP_ROOT="$WORK/app-root/Applications"
mkdir -p "$APP_ROOT"
cp -R dist/VirtualAudioInterface.app "$APP_ROOT/"

pkgbuild --analyze --root "$WORK/app-root" "$WORK/app-component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/app-component.plist"

pkgbuild \
  --root "$WORK/app-root" \
  --component-plist "$WORK/app-component.plist" \
  --identifier "$PKG_APP_ID" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$WORK/app.pkg"

# --- Driver component: /Library/Audio/Plug-Ins/HAL/*.driver ---------------
echo "==> Packaging driver component"
DRIVER_ROOT="$WORK/driver-root/Library/Audio/Plug-Ins/HAL"
mkdir -p "$DRIVER_ROOT"
cp -R HALPlugin/build/VirtualAudioInterfaceDriver.driver "$DRIVER_ROOT/"

pkgbuild --analyze --root "$WORK/driver-root" "$WORK/driver-component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/driver-component.plist"

pkgbuild \
  --root "$WORK/driver-root" \
  --component-plist "$WORK/driver-component.plist" \
  --identifier "$PKG_DRIVER_ID" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  --scripts packaging/scripts/driver \
  "$WORK/driver.pkg"

# --- Resources: welcome (always present) + license (optional at this point) ---
RES="$WORK/resources"
mkdir -p "$RES"
cp packaging/resources/welcome.html "$RES/"
if [ -f LICENSE ]; then
  cp LICENSE "$RES/license.txt"
else
  echo "License not yet published at build time." > "$RES/license.txt"
fi

# --- Final product pkg -----------------------------------------------------
echo "==> Building product archive"
mkdir -p dist
productbuild \
  --distribution packaging/distribution.xml \
  --package-path "$WORK" \
  --resources "$RES" \
  "$OUT"

shasum -a 256 "$OUT" > "$OUT.sha256"
echo "built: $OUT"
cat "$OUT.sha256"
