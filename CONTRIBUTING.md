# Contributing to TidyMac

Thanks for helping out. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with:

- your macOS version and Mac model,
- what you did, what you expected and what happened,
- whether Full Disk Access and notifications are allowed for TidyMac,
- for a wrong scan result, the output of `build/TidyMac.app/Contents/MacOS/TidyMac --scan <module>` (it never changes anything).

Please do not paste personal file names or paths you would rather keep private.

For a security problem, do not open a public issue: follow [SECURITY.md](SECURITY.md).

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
5. Open a pull request that explains what changed and why. Screenshots help for UI changes. GitHub Actions runs the build and tests on it.

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

## Translations

The English text in the code is the key. `Text("Scan")` and similar SwiftUI literals are translated as they are. A `String` that ends up on screen goes through `String(localized: "Scan")`, including the ones in `TidyCore`.

- Write whole sentences. Do not assemble a text from pieces, since word order changes between languages.
- Never compare a displayed text in code or save it as a setting. Keep a fixed value and give it a `title` for display.
- Add a new text's translation to `Localization/fr.lproj/Localizable.strings`. A text with a count goes in `Localizable.stringsdict`, for both English and French.
- Run `Packaging/check-translations.sh`. CI runs it too. It fails on a missing or outdated translation, and on format specifiers that do not match.

To add a language, create `Localization/<code>.lproj` with the same files as `fr.lproj` and add the code to `CFBundleLocalizations` in `bundle.sh`.

## Safety rules

TidyMac deletes files on people's machines, so these are not negotiable:

- Every action goes through `Executor`. Do not delete, move or run commands from anywhere else. Installing TidyMac itself (`MoveToApplications`) is the one exception, and it applies the same `RemovalGuard` check.
- An action's command is a `Command` with a list of arguments. Never build shell text from something read from the disk or the network. Root is only reached through `Shell.runAsAdministrator`.
- Files go to the Trash. Permanent deletion is only for items already inside a Trash bin and for what needs root, which `RemovalGuard` limits to `permanentRoots` and app bundles. Add to that list only for something a scan really offers.
- Nothing outside the user's home folder is trashed, apart from apps in `/Applications`.
- Nothing is selected by default unless it is clearly safe to remove, and nothing runs without the user's review. The one exception is an Automations rule the user created and set to clean automatically, and those never use the administrator password.
- Tests must never touch real user files. Use a temporary directory, as the existing tests do.
- Do not read or send personal data off the machine. There is no telemetry and no network access beyond what a feature explicitly needs, such as update checks.

## What not to include

- Code, binaries, images, icons or strings copied from other applications.
- Decompiled or disassembled output of third-party software.
- Anything you do not have the right to license under the [MIT license](LICENSE).

By contributing, you agree that your contribution is released under the same license.

## Releasing

1. Set the new version in the `VERSION` file and merge that to `main`.
2. Tag that commit and push the tag: `git tag v1.2.3 && git push origin v1.2.3`. The tag has to match `VERSION`.
3. The Release workflow runs the tests, then creates a draft release with the DMG, the ZIP, `SHA256SUMS.txt` and `tidymac.rb`. Review it and publish it. The app's update check only sees published releases.
4. Copy `tidymac.rb` to `Casks/` in a repository named `homebrew-tap`, so that `brew install --cask manuelebeh/tap/tidymac` installs that version.

Running the workflow by hand from the Actions tab builds the same files as an artifact and publishes nothing. `Packaging/package.sh` does the same locally, into `dist/`.

Signing and notarization need a paid Apple Developer account and a Developer ID Application certificate. The workflow uses them once these secrets exist. Without them, the app is signed ad hoc and people have to approve it by hand in System Settings.

Create them as secrets of an environment named `release` (Settings › Environments), not as repository secrets, and limit that environment to tags matching `v*` so no other branch can reach them. Only a tag build uses them: running the workflow by hand always signs ad hoc. The tag build also attaches a build provenance attestation to the ZIP and the DMG.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | the certificate and its key exported as `.p12`, encoded with `base64` |
| `DEVELOPER_ID_CERT_PASSWORD` | the password of that `.p12` |
| `APPLE_ID` | the Apple ID of the developer account |
| `APPLE_TEAM_ID` | the team ID |
| `APPLE_APP_PASSWORD` | an app-specific password for that Apple ID |
