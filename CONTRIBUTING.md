# Contributing

Thanks for helping. Small PRs that do one thing get merged fastest.

## Setup

macOS 14+, Swift toolchain. No other dependencies.

```sh
swift test                       # run before every PR
swift test --filter PrompterTests
./bundle.sh <app> app            # build one .app (clipboard | prompter | adwall | borno)
```

CI (`.github/workflows/ci.yml`) runs `swift test` and builds every app on each PR.

If `swift test` fails once with `plugin for module 'TestingMacros' not found`, run it again (Command Line Tools quirk).

## Ground rules

- **No third-party dependencies.** Apple frameworks and the Swift stdlib only. This is the project's selling point.
- One file per component, short files, comments only where the *why* is not obvious.
- Logic that can be tested without a GUI (parsers, stores, matchers) gets a test in `Tests/<App>Tests/`.
- Say what you could not verify (hotkeys, Accessibility, GUI behavior) in the PR. Screenshots help.
- Keep PRs focused; do not mix a refactor with a feature.

## Add a new app

1. `Sources/<App>/` with the code. Add an `executableTarget` (and a `testTarget` if it has testable logic) in [Package.swift](Package.swift).
2. `Scripts/<app>/bundle.sh` and `Scripts/<app>/VERSION`. Copy `Scripts/prompter/` as a template.
3. `Resources/<app>/NOTICE.txt` (copy Prompter's; list any third-party material) and an `AppIcon.icns` (a `makeicon.swift` in `Scripts/<app>/` can draw it).
4. Register the app in the top-level [bundle.sh](bundle.sh) (`case` line and usage comment).
5. Add a build step to [.github/workflows/ci.yml](.github/workflows/ci.yml).
6. `docs/<app>.md` and a row in the README table.

Open an issue first if the idea is big, so we can agree on scope before you build it. App ideas that fit: small, offline, native, no account, no telemetry.

## Release (maintainers)

```sh
git tag v0.1.0 && git push origin v0.1.0
```

[release.yml](.github/workflows/release.yml) runs the tests, builds the app dmgs, and attaches them to a new GitHub Release. Per-app versions live in `Scripts/<app>/VERSION`.

## Good first issues

- Clipboard Manager: text search, per-app ignore list, emoji skin tones/categories/recents, store files and rich text.
- Borno: settings window, fixed (non-phonetic) layouts, conjuncts beyond Avro's table.
- Any app: tests for the GUI-only paths listed under "Known limitations" in its doc.

## Licensing

By contributing you agree your work is released under the [MIT License](LICENSE). Do not copy code or data you cannot relicense; flag third-party material in the app's `NOTICE.txt`.
