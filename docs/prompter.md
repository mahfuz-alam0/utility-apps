# Prompter

On-screen script prompter for calls and recordings. A floating overlay shows one step of your script at a time, and can hide itself from screen sharing. Swift, AppKit + SwiftUI, no dependencies. Sources in [Sources/Prompter/](../Sources/Prompter/).

`./bundle.sh prompter` builds `build/Prompter.dmg`; `./bundle.sh prompter install` installs to /Applications and launches it; `./bundle.sh prompter app` builds the `.app` only. `swift test --filter PrompterTests` runs the script-parsing tests.

## Scripts

A script is plain text. A `# Title` line starts a step. Without headings, each blank-line separated paragraph is one step.

| Syntax | Meaning |
|---|---|
| `# Title` | new step |
| text | what to say; blank line = new paragraph |
| `- item` / `* item` | bullet |
| `> Show: x` | on-screen cue (what to show, not say) |
| `> Time: 30` | seconds for this step (Auto mode) |

Import and export plain `.txt` files from the editor. Scripts and settings live in `~/Library/Application Support/Prompter/`.

## Modes

- **Manual**: you move between steps with the shortcuts.
- **Auto**: steps advance on a timer. A step uses its `> Time:` value, or an estimate from word count and the words-per-minute setting.

## Shortcuts (while running)

| Default | Action |
|---|---|
| ⌘N / ⌘⇧N | next / previous step |
| ⌘⌥A | play / pause (Auto) |
| ⌘⌥P | show / hide overlay |
| ⌘⌥L | lock / unlock overlay (locked = clicks pass through) |
| ⌘⌥Q | stop, back to editor |

Change them in `config.json` (editor → Display → Edit shortcuts). Keys are `next`, `prev`, `toggleAuto`, `toggleVisible`, `toggleLock`, `stop`; the default file is [Resources/prompter/config.json](../Resources/prompter/config.json). Shortcuts use Carbon hot keys, so no Accessibility permission is needed.

## Hide from screen recordings

On by default. The overlay window is excluded from screen capture (`NSWindow.sharingType = .none`), so viewers on a call do not see it. Some capture tools ignore this flag; test with your own tool before relying on it.
