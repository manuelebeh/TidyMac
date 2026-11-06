# TidyMac

[![CI](https://github.com/manuelebeh/TidyMac/actions/workflows/ci.yml/badge.svg)](https://github.com/manuelebeh/TidyMac/actions/workflows/ci.yml)

A native macOS app to clean, protect and speed up your Mac, built with SwiftUI. Everything runs locally, with no account and no telemetry.

TidyMac is an independent project. It is not affiliated with or endorsed by any other Mac utility vendor.

## Features

- **Smart Care**: one scan across cleanup, protection, performance, applications and clutter, then one button to run it all.
- **Cleanup**: system junk, developer tool caches (npm, pnpm, Bun, Cargo, Gradle, uv and more), simulator runtimes, unused Docker data, AI tool caches and logs, mail attachments, Trash bins.
- **Protection**: suspicious launch agents and daemons, built-in protections that are turned off (Gatekeeper, FileVault, firewall, System Integrity Protection), browser privacy data, application permissions.
- **Performance**: maintenance tasks, login items, background items, Time Machine snapshots.
- **Applications**: uninstaller with leftovers, updates from Sparkle feeds, the App Store and Homebrew casks, unused installers. The update check sends the IDs of your App Store apps to Apple's public lookup API, and runs `brew update` when Homebrew is installed. Upgrading a cask runs `brew upgrade --cask` with analytics off.
- **My Clutter**: large and old files, duplicates, similar images, downloads, and project build folders (node_modules, target, .venv and similar) in the folder you choose. Only those of projects untouched for three months are preselected.
- **Space Lens**: a bubble map of what takes up space on your disk. Selections carry across folders and are reviewed together before they go to the Trash; essential folders are locked, system folders come with a warning, purgeable space is shown, and every removal lands in a log.
- **My Tools**: single-purpose tools with search, favorites and last-scan dates.
- **My Activity**: Mac health with recommendations, space cleaned, time saved, malware scan history. Recommendations also cover pending app updates, apps unused for six months, a restart after a week of uptime and a failing drive; skip one for the day or hide them all. Opening My Activity runs the update check at most once a day.
- **Screen Cleaning Mode**: locks the keyboard and trackpad and blanks the screen so you can wipe it.
- **Menu bar**: Mac Health at a glance, live storage, memory, battery, CPU and network with charts, Wi-Fi security, a speed test, top consumers, external drives with eject, connected Bluetooth devices, drive health, and recommendations you can act on or ignore for a while. The icon gets a dot when something needs attention.
- **Background alerts**: notifications for low disk space, a full Trash, heavy memory use, critical battery health, new threats, overfilled external drives, low device batteries, hung apps (with Force Quit All), Chrome using too much memory, apps moved to the Trash, and a Smart Care reminder every 3, 7, 14 or 30 days. Thresholds are configurable in Settings (⌘,).
- **General settings**: sounds when a scan or cleanup finishes, Reduce Motion (System, Enabled, Disabled), keep the Dock icon after the window closes, show or hide the recommendations, and empty a drive's Trash when you eject it from the menu (off by default, the files are deleted for good).
- **Integrations**: right-click an app in Finder › Services (or Quick Actions) › Uninstall with TidyMac. Shortcuts can do the same with "Open URLs" on `tidymac://uninstall?path=/Applications/Name.app`. On launch outside the Applications folder, TidyMac offers to move itself there.
- **Ignore List**: right-click an item in the review sheet to keep it out of future scans; manage the list by category in Settings › Ignore List.

## Requirements

- macOS 13 or later
- Swift 5.9 or later (Xcode 15+ or the Command Line Tools)

## Build and run

```bash
swift build          # build
swift test           # run the tests
./bundle.sh          # wrap the executable in build/TidyMac.app
open build/TidyMac.app
```

Run it as an app bundle rather than with `swift run`: notifications and Open at Login need a bundle identifier.

## Permissions

- **Full Disk Access** is needed to read the Trash and some protected caches. Without it those items are skipped. TidyMac notices when you grant it: results offer a new scan, and items macOS blocked during a cleanup are removed as long as you stay on that screen.
- **Notifications** have to be allowed for TidyMac in System Settings › Notifications for alerts to show up.
- Administrator tasks, such as freeing RAM or flushing DNS, ask for your password once through the standard macOS prompt. There is no privileged helper.

## Safety

- Files go to the Trash instead of being deleted, except items already in a Trash bin.
- The executor refuses to trash anything outside your home folder.
- Before any removal, a last check refuses system folders, other users' files and the live data of iCloud sync, including through symbolic links. Items macOS protects (SIP, locked files) are not offered, so no password is asked for a removal that cannot work.
- A duplicate only goes to the Trash after both files are read again, to confirm the copy being kept is still there, separate and identical. Hard links are not counted as duplicates.
- Nothing is removed until you review the results and confirm.
- Malware detection is a heuristic over launch items (missing or unsigned executables, hidden or temporary locations). It is not an antivirus engine.
- Language files and universal binaries inside app bundles are left alone, since changing them breaks code signatures.

## Layout

```
Sources/TidyCore   scan engines, actions, history, system readings, alert rules
Sources/TidyMac    SwiftUI app: screens, menu bar tray, background monitor, settings
Tests/             unit tests for the core library
bundle.sh          builds build/TidyMac.app
```

## Command line helpers

These print results and quit. They never run a cleaning action.

```bash
build/TidyMac.app/Contents/MacOS/TidyMac --scan <module>   # smartCare, cleanup, protection, performance, applications, clutter
build/TidyMac.app/Contents/MacOS/TidyMac --health-check    # current readings and active alerts
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
