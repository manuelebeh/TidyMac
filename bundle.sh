#!/bin/zsh
# Wraps the SwiftPM executable in a minimal .app so it gets a bundle id and Dock presence.
set -e
swift build -c release
APP=build/TidyMac.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/TidyMac" "$APP/Contents/MacOS/TidyMac"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.local.TidyMac</string>
<key>CFBundleName</key><string>TidyMac</string>
<key>CFBundleExecutable</key><string>TidyMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>dev.local.TidyMac</string>
  <key>CFBundleURLSchemes</key><array><string>tidymac</string></array>
</dict></array>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "$APP"
