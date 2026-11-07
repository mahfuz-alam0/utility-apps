# ClipboardManager

Win+V-style clipboard history for macOS. Swift, AppKit + SwiftUI, no dependencies.

## Target platform

macOS 14+. Swift with AppKit/SwiftUI does not run on Windows 11, and Windows 11 already ships this feature (Win+V). If you need it on Windows, use C#/WinUI 3 (or WPF) with:

| Piece | Windows API |
|---|---|
| Clipboard monitor | `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE` |
| Global hotkey | `RegisterHotKey` (Win+V is reserved by the shell; use e.g. Ctrl+Shift+V) |
| Caret position | `GetGUIThreadInfo` → `rcCaret`, `ClientToScreen` |
| Auto-paste | `SetForegroundWindow` on the saved window, then `SendInput` Ctrl+V |
| Acrylic | `DesktopAcrylicBackdrop` (WinUI 3) |
| Privacy | skip items carrying format `ExcludeClipboardContentFromMonitorProcessing`, or `CanIncludeInClipboardHistory` = 0 |

## Architecture

Menu-bar agent (`LSUIElement`, no Dock icon). One target, one file per component. App icon: [Scripts/make-icon.swift](Scripts/make-icon.swift) draws it, [Resources/AppIcon.icns](Resources/AppIcon.icns) is the committed result.

| File | Role |
|---|---|
| [main.swift](Sources/ClipboardManager/main.swift) | App entry, status-item menu (Show / Pause / Clear / Quit), wiring |
| [Monitor.swift](Sources/ClipboardManager/Monitor.swift) | Polls `NSPasteboard.changeCount` every 0.4 s; skips paused, own writes, concealed types |
| [Store.swift](Sources/ClipboardManager/Store.swift) | History (pinned first, then newest; dedupe, size cap), JSON + PNG persistence, thumbnails |
| [Settings.swift](Sources/ClipboardManager/Settings.swift) | All preferences (UserDefaults-backed): limit, theme, shortcut, privacy, login item |
| [SettingsView.swift](Sources/ClipboardManager/SettingsView.swift) | Settings window (native grouped `Form`) + shortcut recorder |
| [HotKey.swift](Sources/ClipboardManager/HotKey.swift) | Global ⌃⇧V via Carbon `RegisterEventHotKey` |
| [Caret.swift](Sources/ClipboardManager/Caret.swift) | Accessibility lookup of caret bounds in the frontmost app |
| [Popup.swift](Sources/ClipboardManager/Popup.swift) | Non-activating `NSPanel`, vibrancy, SwiftUI list, keyboard handling, positioning |
| [Emoji.swift](Sources/ClipboardManager/Emoji.swift) | Emoji list built from `Unicode.Scalar.Properties` |
| [Paste.swift](Sources/ClipboardManager/Paste.swift) | Simulated ⌘V via `CGEvent` |

Flow: hotkey → remember frontmost app → caret rect (else mouse) → show panel. Panel is key but the app never activates, so the target app stays frontmost. Enter/click → write item to pasteboard (mark `ownChange`) → hide → 80 ms later post ⌘V.

Data: `~/Library/Application Support/ClipboardManager/history.json` + `images/*.png`. Cap: Settings → Maximum items (default 25, like Windows; 1–500).

## Permissions

| Permission | Why | How requested |
|---|---|---|
| Accessibility | Posting ⌘V and reading caret position | `AXIsProcessTrustedWithOptions` prompt at launch. Grant in System Settings → Privacy & Security → Accessibility |
| Input Monitoring | **Not needed.** Hotkey uses Carbon (no event tap); ⌘V is posted, not listened to | — |

Without Accessibility the popup still works but falls back to the mouse position and pasting fails silently (item is on the clipboard, press ⌘V yourself).

## UI spec

Mirrors the Windows 11 clipboard-history flyout.

- Panel 360 × 480, corner radius 8, `NSVisualEffectView` `.popover` material (blur), 1 pt hairline border, system shadow, level `.popUpMenu`.
- Header 48 pt: "Clipboard history" 14 pt semibold; "Clear all" 12 pt accent (keeps pinned items).
- Cards: 8 pt outer inset, 6 pt gap, 12 × 10 padding, radius 4. Text 13 pt, 4 lines max. Images fit, max 140 pt tall. Timestamp 11 pt secondary ("5 minutes ago"), toggle in Settings.
- Colors (dynamic, follow light/dark): card fill white 70% (light) / white 6% (dark); hover white 95% / 10%; 1 pt hairline stroke; **selected = 2 pt system-accent border**.
- Hovered/selected card shows Pin and ✕ buttons; pinned cards show a pin glyph.
- Animations: open = fade + scale 0.96→1 from top, 120 ms ease-out; selection scroll 100 ms.
- States: **empty** (icon + "Nothing copied yet"), **paused** (orange banner with Resume), **selected**. No loading state: history loads synchronously from a small JSON file.
- Keys: ↑/↓ move, Enter paste, Esc close, Delete/⌦ remove, P pin/unpin. Click card = paste. ⇥ switches Clipboard/Emoji tab.
- Emoji tab: grid of system emoji (generated from Unicode tables, no skin tones/flags/ZWJ), type to search by name, arrows move, Enter/click pastes. Not added to history. Click outside = close. Hotkey again = close.
- Position: below the caret if the app exposes it, else below the mouse (or always mouse, per Settings); flips above if it doesn't fit; clamped to the screen's visible frame.
- Menu-bar icon is a template image, so it tints for light/dark menu bars.

## Settings (menu-bar icon → Settings…, ⌘,)

| Section | Controls |
|---|---|
| General | Launch at login (on by default after first run) · Open popup at text cursor / mouse pointer · Shortcut (click, press combo; Esc cancels; Reset) |
| Appearance | Theme: System / Light / Dark (applies app-wide) · Show timestamps |
| History | Maximum items (type or stepper, 1–500) · Keep history after quitting · Record text · Record images · Pause recording · Clear History |
| Save images | Folder that gets a PNG copy of every recorded image (screenshots included). Off by default. |
| Privacy | Ignore password-manager content (`org.nspasteboard.ConcealedType` etc.) |

Pinned items don't count toward the limit and survive Clear. Turning "Keep history after quitting" off deletes the saved history file; session images are removed at next launch.

## Build and run

Needs the Swift toolchain only (Command Line Tools is enough; Xcode not required).

```sh
./bundle.sh     # builds .build/ClipboardManager.app + build/ClipboardManager.dmg; does not launch or install (open the .app or drag it from the dmg yourself, grant Accessibility when prompted)
swift test      # store/settings tests: dedupe, pin, cap, persistence, clamp
```

Then copy some text, focus a text field, press ⌃⇧V.

`bundle.sh` signs with an identifier-only requirement, so the Accessibility grant survives rebuilds. Grant it once; if it ever re-prompts, run `tccutil reset Accessibility com.local.ClipboardManager`, relaunch and grant again. If macOS still re-prompts on every build, sign with a self-signed code-signing certificate (Keychain Access → Certificate Assistant → Create a Certificate → Code Signing) and use `--sign "<cert name>"` in `bundle.sh`.

Change the hotkey in Settings → Shortcut. Default is ⌃⇧V.

To redraw the icon, edit [Scripts/make-icon.swift](Scripts/make-icon.swift), delete `Resources/AppIcon.icns`, run `./bundle.sh`.

If `swift test` fails once with `plugin for module 'TestingMacros' not found`, run it again (Command Line Tools quirk).

## Known limitations

- Items: text and images only. Files, rich text and HTML are not stored. Add a `ClipItem` case and write all pasteboard types in `copyToPasteboard`.
- Caret lookup needs the target app to expose Accessibility text bounds. Chrome/Electron/some terminals don't (falls back to mouse). Zero-length selections return empty bounds in some apps.
- Images are not deduped; repeat copies add repeat items.
- History is stored unencrypted on disk. Secrets that aren't marked concealed by their source app will be recorded. Move storage to Keychain-wrapped encryption if that matters.
- Polling at 0.4 s: two copies within one interval record only the last. The timer also pauses while the menu-bar menu is open.
- ⌘V is sent by key position (ANSI V); layouts where V is elsewhere may misfire.
- Recent macOS versions can prompt for pasteboard access by other apps. If history stays empty, check System Settings → Privacy & Security for a paste-access entry.
- Interactive behavior (hotkey, caret placement, paste, settings window) is untested here: it needs the Accessibility grant and a GUI session. Verified: build, store/settings tests, launch, card rendering in light and dark.
- Not a pixel-exact Windows clone: no Emoji/GIF/Symbols tabs, SF Pro instead of Segoe UI, macOS accent color and blur.

## Extend

Search field, per-app ignore list (check `NSWorkspace.frontmostApplication.bundleIdentifier` in `ClipboardMonitor.poll`), launch at login (`SMAppService.mainApp.register()`), user-configurable hotkey/size, emoji categories/skin tones/recents, symbol tabs.

# Downloader

IDM-style download accelerator for macOS. Swift, SwiftUI + URLSession, no dependencies. `./bundle.sh downloader` builds `build/Downloader.dmg` (and `.build/Downloader.app`); `./bundle.sh downloader install` also installs it to /Applications and launches it.

- Splits a file into ranged pieces and fetches them over several connections at once (Settings in the footer: 1–32, default 8). Pieces are smaller than the connection count, so a finished connection picks up the next piece.
- Pause/resume, also across quits. Progress is saved in `~/Library/Application Support/Downloader/downloads.json`; the partial file is `<name>.part` in the save folder. Resume restarts from zero if the server's size or ETag changed.
- Add with ⌘N (pre-fills a URL from the clipboard), drop a link on the window, or capture from the browser (below). Retries a failed piece 4 times.
- Servers without `Range` support download over one connection and cannot resume.

## Browser capture

Off by default. Turn on the **Capture browser downloads** switch in the app window; while it is on (and the app is running, window open or not) the extension hands every browser download to the app. Switch off, or app not running: the browser downloads as usual.

Install the extension once (Chrome, Edge, Brave, Arc, Opera): `chrome://extensions` (Brave: `brave://extensions`) → Developer mode → Load unpacked → pick the folder. The line under the switch tells you what is missing: "Off", "On, but no browser extension has connected yet" (orange), or "On: browser extension connected" (the extension pings the app about once a minute). In the app, File → Show Browser Extension in Finder opens it; in the repo it is [Resources/downloader/extension/](Resources/downloader/extension/). Safari and Firefox are not covered.

How it works: the app listens on `127.0.0.1:48620` (loopback only, [Server.swift](Sources/Downloader/Server.swift)). The extension's `downloads.onCreated` handler asks `GET /status`; if capture is on it sends `POST /add` with the URL, referrer and the browser's cookies for that URL, and only then cancels the browser's own download. The app sends the cookie and referrer on every request, so login-protected downloads work. `/add` rejects any request whose `Origin` is not `chrome-extension://` or `moz-extension://`, so a web page cannot add downloads to your app. Cookies are dropped on a redirect to another host (CDN).

- The cookies are stored in plain text in `downloads.json` so a resume after quitting still works. Remove the item to delete them.
- The extension asks for `<all_urls>` and `cookies` because it needs the cookies of whatever site you download from.
- Form/POST downloads and `blob:` downloads cannot be re-fetched by URL; the browser keeps those.
- Any installed extension can use `/add`, not only this one. Pin the extension ID in `Server.swift` if that matters.
- The port is fixed. If another program holds 48620, capture silently does nothing.

How a download runs: `probe` sends `Range: bytes=0-0` (206 + `Content-Range` gives size and range support, `suggestedFilename` gives the name) → `Job` splits, preallocates the `.part` file, and each connection writes its piece with `pwrite` at the right offset → rename when all pieces are done. Each connection has its own `URLSession`: over HTTP/2 one shared session would multiplex everything onto a single TCP connection and the speedup would vanish.

Tests: `swift test --filter DownloaderTests` runs against a local range-capable server (byte-exact result, resume skips finished bytes, no-Range fallback). Measured against a local server capped at ~1.3 MB/s per connection: 8 MB took 6.4 s on 1 connection, 0.9 s on 8.

## Downloader limitations

- Faster only when the server throttles per connection (most file hosts and CDNs do). A server that caps your total bandwidth, or a link that is already saturated, gains nothing.
- Links that expire or are single-use (some "click to download" pages) can fail on resume or on the extra probe request.
- No queue/scheduler, speed limit, proxy settings, checksum check, or segment re-splitting while running.
- Not code-signed beyond ad-hoc. The first download into `~/Downloads` triggers the macOS folder-access prompt.
- Verified: build, tests, launch, window size, and the app's side of capture with `curl` posing as the extension (switch off/on, bad origin, cookie + referrer reach the file server, byte-identical result). Not verified: the extension inside a real browser, the UI visually (no screen capture available), real internet servers.

# Adwall

System-wide ad/tracker blocker for macOS: a local filtering DNS service plus a menu-bar app. Swift, no dependencies. Sources in [Sources/Adwall/](Sources/Adwall/), one binary.

`./bundle.sh adwall` builds `build/Adwall.dmg` (drag-to-Applications installer) and `.build/Adwall.app` (arm64 + x86_64, hardened runtime, ad-hoc signed; `SIGN_ID="Developer ID Application: …"` to sign for distribution); `./bundle.sh adwall install` skips the dmg, copies the app to /Applications and launches it. Install first: the daemon restores DNS and removes itself if the app it was set up from disappears. `swift test --filter AdwallTests` runs parser, matcher, script-quoting and DNS-proxy tests.

- Menu bar → **Turn On Protection…** asks for your admin password once, then `Adwall install` (run as root) copies the binary to `/Library/Application Support/Adwall/adwalld`, installs a launch daemon, and points every network service's DNS at `127.0.0.1`. **Turn Off Protection…** restores the original DNS and removes everything.
- The same binary is the CLI: `Adwall serve | install | uninstall`; no argument starts the menu-bar app.
- Blocklists: HaGeZi Pro + StevenBlack, refreshed every 24 h (`config.json` in the support folder also sets upstreams, default DoH to 1.1.1.1 / 9.9.9.9). Menu: pause/resume, recently blocked (click to allow), Edit Allowlist / Custom Blocklist (`rules/*.txt`, picked up within 2 s).
- Not verified here: turning protection on (needs the admin prompt and changes system DNS).

# Borno

Bangla typing on any Mac keyboard, modeled on Avro Keyboard's Avro Phonetic. A real macOS input method (InputMethodKit), so it works in every app. Swift, AppKit, no dependencies.

Type `ami tomake bhalobashi`, get `আমি তোমাকে ভালোবাসি`. The word so far shows inline (underlined) and in a candidate list under the caret.

## Install

```
./bundle.sh borno             # builds .build/Borno.app + build/Borno.dmg
./bundle.sh borno install     # same .app, installed straight from the terminal
```

Open `build/Borno.dmg`, drag Borno into Applications, then open it once (it is an input method, so it never appears as a running app; it lives in the menu-bar input menu): it copies itself to `~/Library/Input Methods` (macOS only loads input methods from there), registers, and shows a dialog. The copy in Applications can then be deleted. Then System Settings → Keyboard → Text Input → Input Sources → + → Bangla → Borno, and switch with the menu-bar input menu or Ctrl+Space. Log out and in once if it is not listed. `./bundle.sh borno app` builds the `.app` only.

Version is in `Scripts/borno/VERSION`; the build number is the git commit count. For a release that opens without the Gatekeeper warning, sign and notarize (needs a paid Apple Developer ID; one-time `xcrun notarytool store-credentials borno`):

```
SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=borno ./bundle.sh borno
```

## Keys

| Key | Action |
|---|---|
| letters, digits | build the word (digits become ০-৯, `.` becomes ।, `$` becomes ৳) |
| ↓ ↑ / Tab, ⇧Tab | choose a candidate |
| ⌥1 … ⌥9 | commit that candidate (the numbers show in the list) |
| Space, Return | commit the highlighted candidate (Space adds a space) |
| Esc / Delete | cancel / erase one letter |
| click | commit that candidate |
| other punctuation, arrows, ⌘⌃⌥ shortcuts | commit the word, key goes through |

Rules are Avro's: `o a i I u U e O OI OU rri`, conjuncts form automatically (`kkh` → ক্ষ), the backtick separates letters (``ek`i`` → একই, ``am`ra`` → আমরা), `y Z w r` after a consonant make ফলা, `rr` before a consonant makes reph, `ng ^ :` give ং ঁ ঃ, `t` plus two backticks gives ৎ, `,,` is hasanta.

## Menu and custom words

Borno's entry in the menu-bar input menu has **Edit Custom Words…**, **Clear Learned Words…** and **About Borno**.

Custom words: one Bangla word per line in `~/Library/Application Support/Borno/user-words.txt` (names, places, slang; `#` starts a comment). They join the dictionary, so a loose spelling finds them like any other word. Saved edits load the next time you click into a text field.

## Architecture

| File | Role |
|---|---|
| [Phonetic.swift](Sources/Borno/Phonetic.swift) | Roman → Bangla. Longest-match tokens plus a small context state (after consonant / vowel / inherent o) |
| [Lexicon.swift](Sources/Borno/Lexicon.swift) | 159k-word dictionary indexed by a loose phonetic key (o-vowel, hasanta, ন/ণ, স/শ/ষ, ত/ট, ড়/র… merged). Binary search: ~0.3 ms per key. Also autocorrect and learned picks |
| [InputController.swift](Sources/Borno/InputController.swift) | `IMKInputController`: key handling, marked text, commit |
| [CandidatePanel.swift](Sources/Borno/CandidatePanel.swift) | Non-activating blurred panel, light/dark, placed under the caret (flips above at the screen edge) |
| [Menu.swift](Sources/Borno/Menu.swift) | Input-menu items: custom words, clear learned, about |
| [main.swift](Sources/Borno/main.swift) | `IMKServer`; `--register` enables the input source |

Candidate order: words you committed for that spelling (most-committed first), Avro autocorrect, the literal phonetic result, dictionary words with the same key (closest spelling first), then longer words that start the same. So `bhalo` shows ভাল, ভালো, … and every commit counts, so once you pick ভালো more often than ভাল it comes first (`~/Library/Application Support/Borno/learned.json`, written in the background, capped at 20,000 spellings).

English words work too: `suggestion` → সাজেশন, `station` → স্টেশন, `teacher` → টিচার. If the plain phonetic result is not the start of any dictionary word, Borno respells the input the way English sounds (`tion`→শন, soft `g`/`c`, `ch`→চ, …) and looks that up. No translation (suggestion → পরামর্শ): that needs a multi-MB English–Bangla dictionary.

Data: [Resources/borno/words.txt](Resources/borno/words.txt) and `autocorrect.txt` come from the Avro Keyboard 5.6.0 installer (OmicronLab, MPL 1.1) via [make-dictionary.py](Scripts/borno/make-dictionary.py) (download the installer from OmicronLab; it is not kept in this repo). The licence notice ships inside the app as `NOTICE.txt`. [makeicon.swift](Scripts/borno/makeicon.swift) draws the icons.

## Borno limitations

- Apps that report no caret position get the list near the mouse.
- No settings window, no fixed (non-phonetic) layouts.
- Conjuncts follow Avro's table only (`kn` stays ক + ন).
