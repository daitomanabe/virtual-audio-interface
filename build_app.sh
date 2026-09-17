#!/bin/zsh
# Builds dist/VirtualAudioInterface.app (with the HAL driver embedded).
set -e
cd "$(dirname "$0")"

make -C HALPlugin
codesign --force --sign - HALPlugin/build/VirtualAudioInterfaceDriver.driver
swift build -c release --package-path VisualizerApp
BIN=VisualizerApp/.build/release
mkdir -p dist
rm -rf dist/VirtualAudioVisualizer.app dist/VAIControl.app dist/VirtualAudioInterface.app

APP="dist/VirtualAudioInterface.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VisualizerApp" "$APP/Contents/MacOS/"
cp -R HALPlugin/build/VirtualAudioInterfaceDriver.driver "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleName</key><string>Virtual Audio Interface</string>
    <key>CFBundleDisplayName</key><string>Virtual Audio Interface</string>
    <key>CFBundleIdentifier</key><string>com.daitomanabe.virtualaudiointerface.app</string>
    <key>CFBundleExecutable</key><string>VisualizerApp</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "built: $APP"
