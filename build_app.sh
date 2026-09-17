#!/bin/zsh
# Builds dist/VirtualAudioVisualizer.app and dist/VAIControl.app (with the HAL driver embedded).
set -e
cd "$(dirname "$0")"

make -C HALPlugin
codesign --force --sign - HALPlugin/build/VirtualAudioInterfaceDriver.driver
swift build -c release --package-path VisualizerApp
BIN=VisualizerApp/.build/release
mkdir -p dist

make_app() { # <exec> <app file name> <display name> <bundle id>
  local APP="dist/$2.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN/$1" "$APP/Contents/MacOS/"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleName</key><string>$3</string>
    <key>CFBundleDisplayName</key><string>$3</string>
    <key>CFBundleIdentifier</key><string>$4</string>
    <key>CFBundleExecutable</key><string>$1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
}

make_app VisualizerApp VirtualAudioVisualizer "Virtual Audio Visualizer" com.daitomanabe.virtualaudiointerface.visualizer
make_app VAIControl VAIControl "VAI Control" com.daitomanabe.virtualaudiointerface.control
cp -R HALPlugin/build/VirtualAudioInterfaceDriver.driver dist/VAIControl.app/Contents/Resources/

for app in dist/VirtualAudioVisualizer.app dist/VAIControl.app; do
  xattr -cr "$app"
  codesign --force --sign - "$app"
done
echo "built: dist/VirtualAudioVisualizer.app dist/VAIControl.app"
