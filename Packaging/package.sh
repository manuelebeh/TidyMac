#!/bin/zsh
# Builds what a release publishes into dist/: a universal app as a ZIP and a DMG, checksums and the Homebrew cask.
#
# Without credentials the app is signed ad hoc, and macOS asks people to approve it in System Settings.
# To sign and notarize, set:
#   SIGN_ID="Developer ID Application: …"
#   NOTARY_PROFILE=<name from `xcrun notarytool store-credentials`>
#     or APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD
set -euo pipefail
cd "${0:a:h}/.."

VERSION=${VERSION:-$(<VERSION)}
SIGN_ID=${SIGN_ID:--}
DIST=dist
ZIP="$DIST/TidyMac-$VERSION.zip"
DMG="$DIST/TidyMac-$VERSION.dmg"
APP=build/TidyMac.app

notary_flags=()
if [[ -n ${NOTARY_PROFILE:-} ]]; then
    notary_flags=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n ${APPLE_ID:-} ]]; then
    notary_flags=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
if (( ${#notary_flags} )) && [[ $SIGN_ID == - ]]; then
    echo "Notarization needs a Developer ID signature: set SIGN_ID." >&2
    exit 1
fi

# `stapler` refuses a ticket Apple did not issue, so a rejected submission stops the script here.
notarize() {
    xcrun notarytool submit "$1" $notary_flags --wait
    xcrun stapler staple "$2"
}

rm -rf "$DIST"; mkdir -p "$DIST"
VERSION=$VERSION SIGN_ID=$SIGN_ID UNIVERSAL=1 ./bundle.sh

if (( ${#notary_flags} )); then
    ditto -c -k --keepParent "$APP" "$DIST/submission.zip"
    notarize "$DIST/submission.zip" "$APP"
    rm "$DIST/submission.zip"
fi
ditto -c -k --keepParent "$APP" "$ZIP"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$APP" "$staging/TidyMac.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname TidyMac -srcfolder "$staging" -ov -format UDZO "$DMG"
if [[ $SIGN_ID != - ]]; then codesign --force --timestamp --sign "$SIGN_ID" "$DMG"; fi
if (( ${#notary_flags} )); then notarize "$DMG" "$DMG"; fi

(cd "$DIST" && shasum -a 256 "${ZIP:t}" "${DMG:t}" > SHA256SUMS.txt)
sha=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$sha/" Packaging/tidymac.rb.template > "$DIST/tidymac.rb"

if (( ${#notary_flags} )); then
    spctl --assess --type execute "$APP"
else
    echo "Not notarized: macOS will ask people to approve the app in System Settings › Privacy & Security."
fi
ls -l "$DIST"
