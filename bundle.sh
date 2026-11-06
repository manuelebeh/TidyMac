#!/bin/zsh
# Wraps the SwiftPM executable in a .app so it gets a bundle id, an icon and Dock presence.
#
#   UNIVERSAL=1      build for Apple silicon and Intel (default: this Mac only)
#   VERSION=1.2.3    default: the VERSION file
#   BUILD_NUMBER=42  default: the number of commits
#   SIGN_ID="Developer ID Application: …"   default: an ad hoc signature
set -e
cd "${0:a:h}"

VERSION=${VERSION:-$(<VERSION)}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
SIGN_ID=${SIGN_ID:--}
BUNDLE_ID=io.github.manuelebeh.TidyMac

build_flags=(-c release)
if [[ -n $UNIVERSAL ]]; then build_flags+=(--arch arm64 --arch x86_64); fi
swift build $build_flags

APP=build/TidyMac.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build $build_flags --show-bin-path)/TidyMac" "$APP/Contents/MacOS/TidyMac"
cp Packaging/TidyMac.icns "$APP/Contents/Resources/TidyMac.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>TidyMac</string>
<key>CFBundleExecutable</key><string>TidyMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>TidyMac</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>TidyMac asks System Events to list and remove login items, and to restart your Mac when you request it.</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
  <key>CFBundleURLSchemes</key><array><string>tidymac</string></array>
</dict></array>
<key>NSServices</key><array><dict>
  <key>NSMenuItem</key><dict><key>default</key><string>Uninstall with TidyMac</string></dict>
  <key>NSMessage</key><string>uninstallApplications</string>
  <key>NSPortName</key><string>TidyMac</string>
  <key>NSRequiredContext</key><dict/>
  <key>NSSendFileTypes</key><array><string>com.apple.application-bundle</string></array>
</dict></array>
</dict></plist>
PL

# The hardened runtime is what notarization requires, so every build runs under the same rules as a release.
sign_flags=(--force --options runtime --entitlements Packaging/TidyMac.entitlements --sign "$SIGN_ID")
if [[ $SIGN_ID != - ]]; then sign_flags+=(--timestamp); fi
codesign $sign_flags "$APP"
echo "$APP"
