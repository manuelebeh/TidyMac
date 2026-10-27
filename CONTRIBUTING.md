# Contributing to TidyMac

Thanks for helping out. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with:

- your macOS version and Mac model,
- what you did, what you expected and what happened,
- whether Full Disk Access and notifications are allowed for TidyMac,
- for a wrong scan result, the output of `build/TidyMac.app/Contents/MacOS/TidyMac --scan <module>` (it never changes anything).

Please do not paste personal file names or paths you would rather keep private.

## Setting up

You need macOS 13 or later and Swift 5.9 or later.

```bash
git clone git@github.com:manuelebeh/TidyMac.git
cd TidyMac
swift build
swift test
./bundle.sh && open build/TidyMac.app
```

Use the app bundle rather than `swift run`: notifications and Open at Login need a bundle identifier.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep the change focused. One fix or feature per pull request.
3. Add or update tests in `Tests/TidyCoreTests` when you change logic in `Sources/TidyCore`. Rules that decide what is shown, selected or reported should be pure functions that can be tested without touching the real system.
4. Run `swift test` and make sure the app still builds with `./bundle.sh`.
5. Open a pull request that explains what changed and why. Screenshots help for UI changes.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary in the imperative>
```

Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `chore`. Scopes in use: `core`, `ui`, `tray`. Keep commits small and each one buildable.

## Code guidelines

- Match the style of the surrounding code: naming, comment density and idioms.
- `TidyCore` holds logic and has no UI. `TidyMac` holds SwiftUI views and system integration.
- Comments explain why, not what.

## Safety rules

TidyMac deletes files on people's machines, so these are not negotiable:

- Every action goes through `Executor`. Do not delete, move or run commands from anywhere else.
- Files go to the Trash. Permanent deletion is only for items already inside a Trash bin.
- Nothing outside the user's home folder is trashed.
- Nothing is selected by default unless it is clearly safe to remove, and nothing runs without the user's review.
- Tests must never touch real user files. Use a temporary directory, as the existing tests do.
- Do not read or send personal data off the machine. There is no telemetry and no network access beyond what a feature explicitly needs, such as update checks.

## What not to include

- Code, binaries, images, icons or strings copied from other applications.
- Decompiled or disassembled output of third-party software.
- Anything you do not have the right to license under the [MIT license](LICENSE).

By contributing, you agree that your contribution is released under the same license.
