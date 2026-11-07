# Utility Apps

Small, native macOS utilities. Swift, AppKit + SwiftUI, **zero third-party dependencies**, MIT licensed. Each app is one SwiftPM target you can read in an afternoon.

| App | What it does | Docs |
|---|---|---|
| **Clipboard Manager** | Win+V-style clipboard history and emoji picker. Press ⌃⇧V. | [docs/clipboard.md](docs/clipboard.md) |
| **Prompter** | On-screen script prompter for calls and recordings, hidden from screen sharing. | [docs/prompter.md](docs/prompter.md) |
| **Adwall** | System-wide ad and tracker blocker (local filtering DNS + menu-bar app). | [docs/adwall.md](docs/adwall.md) |
| **Borno** | Bangla phonetic keyboard (Avro-style) as a real macOS input method. | [docs/borno.md](docs/borno.md) |
| **Toolkit** | One app that bundles all four. | [docs/toolkit.md](docs/toolkit.md) |

## Download

Grab a `.dmg` from [Releases](https://github.com/mahfuz-alam0/utility-apps/releases/latest): one per app (`ClipboardManager`, `Prompter`, `Adwall`, `Borno`), or `Toolkit.dmg` for all four in one app. Builds are ad-hoc signed, not notarized: first open with right-click → Open.

## Build

macOS 14+ and the Swift toolchain (Command Line Tools is enough, Xcode not required).

```sh
git clone https://github.com/mahfuz-alam0/utility-apps
cd utility-apps
swift test                       # all tests
./bundle.sh clipboard            # or: prompter | adwall | borno | toolkit
```

Each build writes `.build/<App>.app` and `build/<App>.dmg`. `./bundle.sh <app> install` installs and launches it (Prompter, Adwall; Borno copies to `~/Library/Input Methods`; Clipboard Manager: drag it from the dmg). Builds are ad-hoc signed, so macOS may warn on first open; right-click → Open. Signing and notarizing: set `SIGN_ID` and `NOTARY_PROFILE` (see `Scripts/<app>/bundle.sh`).

## Layout

```
Sources/<App>/       the app (one file per component)
Tests/<App>Tests/    unit tests
Resources/<app>/     icons, data, NOTICE.txt
Scripts/<app>/       bundle.sh, VERSION, icon generators
docs/                one page per app
bundle.sh            single entry point for all builds
```

## Contribute

New apps, fixes, docs and ideas are all welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md): it has the build loop, the checklist for adding an app, and a list of good first issues. Found a bug? [Open an issue](https://github.com/mahfuz-alam0/utility-apps/issues/new/choose). Security problem? See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Third-party material is credited in each app's `NOTICE.txt`:

| App | What | Licence |
|---|---|---|
| Borno | `words.txt`, `autocorrect.txt` derived from Avro Keyboard (OmicronLab) | MPL 1.1 (those two files only) |
| Adwall | HaGeZi and StevenBlack blocklists, downloaded at runtime, not bundled | GPL-3.0 / MIT, theirs |
| Clipboard Manager, Prompter | nothing | |
