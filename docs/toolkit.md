# Toolkit

One app that carries all four (Clipboard Manager, Prompter, Adwall, Borno) in `Contents/Helpers`. Its window lists them with **Open / Quit** buttons; Borno gets **Install**, which runs Borno's own installer into `~/Library/Input Methods` (macOS only loads input methods from there, so it cannot run from inside another app). Sources: [Sources/Toolkit/](../Sources/Toolkit/).

`./bundle.sh toolkit` builds `build/Toolkit.dmg` (universal, signed ad hoc; same `SIGN_ID` / `NOTARY_PROFILE` as the others, one notarization covers all four). `./bundle.sh toolkit app` builds the `.app` only. The standalone apps and their dmgs are unchanged; Toolkit embeds copies built from the same source.

- Embedded apps keep their own bundle ids, so Toolkit and a standalone install of the same app are one app to macOS (same permissions, same data).
- Adwall: protection installed from the embedded copy stops working if Toolkit is deleted.
