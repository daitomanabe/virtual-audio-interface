#!/bin/zsh
# Builds dist/VirtualAudioInterface.app (with the HAL driver embedded).
# Universal (arm64 + x86_64) where the toolchain allows it; falls back to
# arm64-only per component and says why.
set -e
cd "$(dirname "$0")"

VERSION=$(<VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
echo "==> Version $VERSION ($BUILD_NUMBER)"

# --- HAL driver: universal via clang++ -arch arm64 -arch x86_64, falls back to arm64 ---
echo "==> Building HAL driver"
make -C HALPlugin clean >/dev/null
set +e
make -C HALPlugin >/tmp/vai_driver_build.log 2>&1
DRIVER_STATUS=$?
set -e
if [ $DRIVER_STATUS -ne 0 ]; then
  echo "==> universal driver build failed, retrying arm64-only. Reason:"
  tail -15 /tmp/vai_driver_build.log
  make -C HALPlugin clean
  make -C HALPlugin ARCHS="-arch arm64"
fi
DRIVER_BUNDLE=HALPlugin/build/VirtualAudioInterfaceDriver.driver
plutil -replace CFBundleShortVersionString -string "$VERSION" "$DRIVER_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$DRIVER_BUNDLE/Contents/Info.plist"
codesign --force --sign - "$DRIVER_BUNDLE"

# --- App: try single-invocation universal build (needs XCBuild, which CLT-only
# setups don't have), else build each triple and lipo them together. We check
# for xcbuild up front rather than trying --arch and letting it fail: a failed
# --arch invocation leaves SwiftPM's shared .build state (build.db/release.yaml)
# corrupt and breaks the plain build that would otherwise follow it.
echo "==> Building VisualizerApp"
if xcrun --find xcbuild >/dev/null 2>&1; then
  UNIVERSAL_BIN="VisualizerApp/.build/apple/Products/Release/VisualizerApp"
  rm -f "$UNIVERSAL_BIN"
  swift build -c release --package-path VisualizerApp --arch arm64 --arch x86_64
  APP_BIN="$UNIVERSAL_BIN"
  echo "==> universal app build via --arch arm64 --arch x86_64"
else
  echo "==> xcbuild not available (Command Line Tools only); building arm64 + x86_64 separately"
  swift build -c release --package-path VisualizerApp
  ARM_BIN="VisualizerApp/.build/arm64-apple-macosx/release/VisualizerApp"
  set +e
  swift build -c release --package-path VisualizerApp --triple x86_64-apple-macosx13.0 >/tmp/vai_swift_x86.log 2>&1
  X86_STATUS=$?
  set -e
  if [ $X86_STATUS -eq 0 ]; then
    X86_BIN="VisualizerApp/.build/x86_64-apple-macosx/release/VisualizerApp"
    mkdir -p VisualizerApp/.build/universal
    lipo -create -output VisualizerApp/.build/universal/VisualizerApp "$ARM_BIN" "$X86_BIN"
    APP_BIN="VisualizerApp/.build/universal/VisualizerApp"
    echo "==> universal app binary assembled with lipo (arm64 + x86_64)"
  else
    echo "==> x86_64 triple build failed, shipping arm64-only. Reason:"
    tail -15 /tmp/vai_swift_x86.log
    APP_BIN="$ARM_BIN"
  fi
fi

BIN="$APP_BIN"
mkdir -p dist
rm -rf dist/VirtualAudioVisualizer.app dist/VAIControl.app dist/VirtualAudioInterface.app

APP="dist/VirtualAudioInterface.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VisualizerApp"
cp -R "$DRIVER_BUNDLE" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleName</key><string>Virtual Audio Interface</string>
    <key>CFBundleDisplayName</key><string>Virtual Audio Interface</string>
    <key>CFBundleIdentifier</key><string>com.daitomanabe.virtualaudiointerface.app</string>
    <key>CFBundleExecutable</key><string>VisualizerApp</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "built: $APP"
echo "==> architectures:"
lipo -archs "$APP/Contents/MacOS/VisualizerApp" | sed 's/^/    app:    /'
lipo -archs "$APP/Contents/Resources/VirtualAudioInterfaceDriver.driver/Contents/MacOS/VirtualAudioInterfaceDriver" | sed 's/^/    driver: /'
