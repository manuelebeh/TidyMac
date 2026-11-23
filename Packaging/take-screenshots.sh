#!/bin/zsh
# Retakes the README screenshots (Overview, History, Toolkit, Settings; light and dark) from the installed app.
# The terminal running it needs Screen Recording permission (System Settings › Privacy & Security).
# It switches TidyMac's appearance setting for the shots and puts it back afterwards.
set -euo pipefail
cd "${0:a:h}/.."

app=/Applications/TidyMac.app
domain=io.github.manuelebeh.TidyMac
key=TidyMac.general.appearance
out=docs/screenshots
previous=$(defaults read $domain $key 2>/dev/null || echo system)

window_id() {
    swift - <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let main = list.first { ($0[kCGWindowOwnerName as String] as? String) == "TidyMac" && ($0[kCGWindowLayer as String] as? Int) == 0 }
print(main?[kCGWindowNumber as String] as? Int ?? 0)
SWIFT
}

for appearance in light dark; do
    osascript -e 'quit app "TidyMac"' 2>/dev/null || true
    sleep 2
    defaults write $domain $key $appearance
    open $app
    sleep 4
    # Same size as the screenshots already in the README (points; doubled on a Retina display).
    osascript -e 'tell application "System Events" to tell process "TidyMac" to set size of window 1 to {1512, 949}' 2>/dev/null || true
    id=$(window_id)
    [[ $id != 0 ]] || { echo "TidyMac's window was not found"; exit 1; }
    for page in smartCare:overview activity:history myTools:toolkit settings:settings; do
        open "tidymac://open/${page%%:*}"
        sleep 3
        screencapture -x -o -l $id "$out/${page##*:}-$appearance.png"
        echo "$out/${page##*:}-$appearance.png"
    done
done

defaults write $domain $key $previous
osascript -e 'quit app "TidyMac"' 2>/dev/null || true
sleep 2
open $app
