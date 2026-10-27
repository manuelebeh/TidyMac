# TidyMac

A native macOS app to clean, protect and speed up your Mac, built with SwiftUI. Everything runs locally, with no account and no telemetry.

TidyMac is an independent project. It is not affiliated with or endorsed by any other Mac utility vendor.

## Features

- **Smart Care**: one scan across cleanup, protection, performance, applications and clutter, then one button to run it all.
- **Cleanup**: system junk, AI tool caches and logs, mail attachments, Trash bins.
- **Protection**: suspicious launch agents and daemons, browser privacy data, application permissions.
- **Performance**: maintenance tasks, login items, background items, Time Machine snapshots.
- **Applications**: uninstaller with leftovers, updates, unused installers.
- **My Clutter**: large and old files, duplicates, similar images, downloads.
- **Space Lens**: a bubble map of what takes up space on your disk.
- **My Tools**: single-purpose tools with search, favorites and last-scan dates.
- **My Activity**: Mac health with recommendations, space cleaned, time saved, malware scan history.
- **Screen Cleaning Mode**: locks the keyboard and trackpad and blanks the screen so you can wipe it.
- **Menu bar**: live storage, memory, battery, CPU and network, top consumers, external drives with eject, connected Bluetooth devices, drive health.
- **Background alerts**: notifications for low disk space, a full Trash, heavy memory use, critical battery health, new threats, overfilled external drives and low device batteries. Thresholds are configurable in Settings (⌘,).

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

- **Full Disk Access** is needed to read the Trash and some protected caches. Without it those items are skipped.
- **Notifications** have to be allowed for TidyMac in System Settings › Notifications for alerts to show up.
- Administrator tasks, such as freeing RAM or flushing DNS, ask for your password once through the standard macOS prompt. There is no privileged helper.

## Safety

- Files go to the Trash instead of being deleted, except items already in a Trash bin.
- The executor refuses to trash anything outside your home folder.
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
