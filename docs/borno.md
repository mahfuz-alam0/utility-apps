# Borno

Bangla typing on any Mac keyboard that works like iAvro 1.5 (OmicronLab's Avro Phonetic for Mac): same rules, same dictionary, same candidates in the same order, same remembered picks. A real macOS input method (InputMethodKit), so it works in every app. Swift, AppKit, no third-party dependencies.

Type `ami tOmake bhalobashi`, get `আমি তোমাকে ভালোবাসি`. As in iAvro, the roman text stays inline (underlined) and the Bangla candidates show in a list under the caret.

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
| letters, digits, punctuation | build the word (digits become ০-৯, `.` becomes ।); leading and trailing punctuation stays out of the dictionary lookup, as in iAvro |
| ↓ ↑ | choose a candidate |
| Space, Return, Tab | commit the highlighted candidate (Space and Tab are typed after it; Return adds no new line) |
| ⌥1 … ⌥9, click | commit that candidate (Borno extra) |
| Esc / Delete | cancel (Borno extra) / erase one letter |
| ⌘ ⌃ shortcuts | go to the app |
| click elsewhere, switch input source | the roman text is inserted as typed (iAvro does the same) |

Rules are Avro's: `o a i I u U e O OI OU rri`, conjuncts form automatically (`kkh` → ক্ষ), the backtick separates letters (``ek`i`` → একই, ``am`ra`` → আমরা), `y Z w r` after a consonant make ফলা, `rr` before a consonant makes reph, `ng ^ :` give ং ঁ ঃ, `t` plus two backticks gives ৎ, `,,` is hasanta.

## Menu and custom words

Borno's entry in the menu-bar input menu has **Edit Custom Words…**, **Forget Remembered Words…** and **About Borno**.

Custom words (Borno extra): one Bangla word per line in `~/Library/Application Support/Borno/user-words.txt` (names, places, slang; `#` starts a comment). They are searched like iAvro's dictionary, so any spelling iAvro would accept finds them. Saved edits load the next time you click into a text field.

## Architecture

| File | Role |
|---|---|
| [Phonetic.swift](../Sources/Borno/Phonetic.swift) | Port of iAvro's AvroParser/RegexParser: one rule matcher; `data.json` gives Bangla, `regex.json` gives a regex for dictionary lookup |
| [Lexicon.swift](../Sources/Borno/Lexicon.swift) | Port of iAvro's Suggestion/Database/AutoCorrect/CacheManager: 159k words from `database.db3`, autocorrect, suffixes, remembered picks |
| [InputController.swift](../Sources/Borno/InputController.swift) | `IMKInputController`, behaving like iAvro's AvroKeyboardController: keys, inline roman text, candidates, commit |
| [CandidatePanel.swift](../Sources/Borno/CandidatePanel.swift) | Non-activating blurred panel, light/dark, placed under the caret (flips above at the screen edge) |
| [Menu.swift](../Sources/Borno/Menu.swift) | Input-menu items: custom words, forget remembered, about |
| [main.swift](../Sources/Borno/main.swift) | `IMKServer`; `--register` enables the input source |

Candidate order (iAvro's): the autocorrect entry (`facebook` → ফেইসবুক), dictionary words that the regex form of the input matches, closest to the phonetic result first, then words built from a shorter dictionary word plus a suffix (`manusher` → মানুষের), then the phonetic result if it is not already listed. So `bhalo` shows ভাল, ভালো, … The row you highlight is remembered for that spelling and highlighted first next time (`~/Library/Application Support/Borno/weight.plist`; on first run Borno takes over iAvro's own `weight.plist` if it finds one).

Data: `data.json`, `regex.json`, `autodict.plist` and `database.db3` in [Resources/borno](../Resources/borno) are iAvro 1.5's files, unchanged (OmicronLab, MPL 1.1; the ported Swift files are MPL 1.1 too). The licence notice ships inside the app as `NOTICE.txt`. [makeicon.swift](../Scripts/borno/makeicon.swift) draws the icons.

## Borno limitations

- Apps that report no caret position get the list near the mouse.
- No settings window, no fixed (non-phonetic) layouts. iAvro's settings are fixed at its defaults: dictionary on, Return adds no new line.
- Candidate list is Borno's own panel, not the system one iAvro uses; it looks different, the rows are the same.
