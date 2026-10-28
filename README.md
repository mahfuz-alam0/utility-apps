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
| [HotKey.swift](Sources/ClipboardManager/HotKey.swift) | Global ⌘⇧V via Carbon `RegisterEventHotKey` |
| [Caret.swift](Sources/ClipboardManager/Caret.swift) | Accessibility lookup of caret bounds in the frontmost app |
| [Popup.swift](Sources/ClipboardManager/Popup.swift) | Non-activating `NSPanel`, vibrancy, SwiftUI list, keyboard handling, positioning |
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
- Keys: ↑/↓ move, Enter paste, Esc close, Delete/⌦ remove, P pin/unpin. Click card = paste. Click outside = close. Hotkey again = close.
- Position: below the caret if the app exposes it, else below the mouse (or always mouse, per Settings); flips above if it doesn't fit; clamped to the screen's visible frame.
- Menu-bar icon is a template image, so it tints for light/dark menu bars.

## Settings (menu-bar icon → Settings…, ⌘,)

| Section | Controls |
|---|---|
| General | Launch at login · Open popup at text cursor / mouse pointer · Shortcut (click, press combo; Esc cancels; Reset) |
| Appearance | Theme: System / Light / Dark (applies app-wide) · Show timestamps |
| History | Maximum items (type or stepper, 1–500) · Keep history after quitting · Record text · Record images · Pause recording · Clear History |
| Privacy | Ignore password-manager content (`org.nspasteboard.ConcealedType` etc.) |

Pinned items don't count toward the limit and survive Clear. Turning "Keep history after quitting" off deletes the saved history file; session images are removed at next launch.

## Build and run

Needs the Swift toolchain only (Command Line Tools is enough; Xcode not required).

```sh
./bundle.sh     # stops old copy, builds build/ClipboardManager.app, launches it; grant Accessibility when prompted
swift test      # store/settings tests: dedupe, pin, cap, persistence, clamp
```

Then copy some text, focus a text field, press ⌘⇧V.

Rebuilds change the ad-hoc signature, so macOS may drop the Accessibility grant. If paste stops working: toggle the app off/on in the Accessibility list, or `tccutil reset Accessibility com.local.ClipboardManager` and relaunch. A stable self-signed code-signing certificate avoids this (`codesign --sign "<cert>"` in `bundle.sh`).

Change the hotkey in Settings → Shortcut. The default ⌘⇧V is "paste and match style" in Chrome/Slack, which it shadows; pick another combo if that matters.

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

Search field, per-app ignore list (check `NSWorkspace.frontmostApplication.bundleIdentifier` in `ClipboardMonitor.poll`), launch at login (`SMAppService.mainApp.register()`), user-configurable hotkey/size, emoji/symbol tabs.
