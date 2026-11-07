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
| [Phonetic.swift](../Sources/Borno/Phonetic.swift) | Roman → Bangla. Longest-match tokens plus a small context state (after consonant / vowel / inherent o) |
| [Lexicon.swift](../Sources/Borno/Lexicon.swift) | 159k-word dictionary indexed by a loose phonetic key (o-vowel, hasanta, ন/ণ, স/শ/ষ, ত/ট, ড়/র… merged). Binary search: ~0.3 ms per key. Also autocorrect and learned picks |
| [InputController.swift](../Sources/Borno/InputController.swift) | `IMKInputController`: key handling, marked text, commit |
| [CandidatePanel.swift](../Sources/Borno/CandidatePanel.swift) | Non-activating blurred panel, light/dark, placed under the caret (flips above at the screen edge) |
| [Menu.swift](../Sources/Borno/Menu.swift) | Input-menu items: custom words, clear learned, about |
| [main.swift](../Sources/Borno/main.swift) | `IMKServer`; `--register` enables the input source |

Candidate order: words you committed for that spelling (most-committed first), Avro autocorrect, the literal phonetic result, dictionary words with the same key (closest spelling first), then longer words that start the same. So `bhalo` shows ভাল, ভালো, … and every commit counts, so once you pick ভালো more often than ভাল it comes first (`~/Library/Application Support/Borno/learned.json`, written in the background, capped at 20,000 spellings).

English words work too: `suggestion` → সাজেশন, `station` → স্টেশন, `teacher` → টিচার. If the plain phonetic result is not the start of any dictionary word, Borno respells the input the way English sounds (`tion`→শন, soft `g`/`c`, `ch`→চ, …) and looks that up. No translation (suggestion → পরামর্শ): that needs a multi-MB English–Bangla dictionary.

Data: [Resources/borno/words.txt](../Resources/borno/words.txt) and `autocorrect.txt` come from the Avro Keyboard 5.6.0 installer (OmicronLab, MPL 1.1) via [make-dictionary.py](../Scripts/borno/make-dictionary.py) (download the installer from OmicronLab; it is not kept in this repo). The licence notice ships inside the app as `NOTICE.txt`. [makeicon.swift](../Scripts/borno/makeicon.swift) draws the icons.

## Borno limitations

- Apps that report no caret position get the list near the mouse.
- No settings window, no fixed (non-phonetic) layouts.
- Conjuncts follow Avro's table only (`kn` stays ক + ন).
