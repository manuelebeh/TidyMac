#!/bin/zsh
# Has the compiler list every text the app can show, then checks the translations against that list.
set -euo pipefail
cd "${0:a:h}/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
target="$(uname -m)-apple-macos13.0"
mkdir -p "$work/core" "$work/app" "$work/modules"

xcrun swiftc -parse-as-library -wmo -c -target "$target" -module-name TidyCore \
    -emit-module -emit-module-path "$work/modules/TidyCore.swiftmodule" -o "$work/core.o" \
    -emit-localized-strings -emit-localized-strings-path "$work/core" Sources/TidyCore/*.swift
xcrun swiftc -parse-as-library -wmo -c -target "$target" -module-name TidyMac -I "$work/modules" -o "$work/app.o" \
    -emit-localized-strings -emit-localized-strings-path "$work/app" Sources/TidyMac/*.swift

swift Packaging/check-translations.swift "$work"
