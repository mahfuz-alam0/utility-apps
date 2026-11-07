#!/bin/sh
# Builds .build/Borno.app + build/Borno.dmg, an input method (arm64 + x86_64). Ad-hoc signed by default;
# SIGN_ID="Developer ID Application: Name (TEAMID)" signs for distribution.
#   ./bundle.sh borno           build .build/Borno.app + build/Borno.dmg (drag to Applications, open once)
#   ./bundle.sh borno app       .app only
#   ./bundle.sh borno install   .app, then copy to ~/Library/Input Methods and register (same as opening Borno once)
# Notarize (needs a Developer ID SIGN_ID and a keychain profile from `xcrun notarytool store-credentials`):
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=borno ./bundle.sh borno
# Version comes from Scripts/borno/VERSION; the build number is the git commit count.
# After install: System Settings > Keyboard > Text Input > Input Sources > + > Bangla > Borno, then switch to it
# from the menu bar (or Ctrl+Space). If it does not show up, log out and in once.
set -e
cd "$(dirname "$0")/../.."

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product Borno
BIN=$(swift build -c release $ARCHS --show-bin-path)

ID=com.mahfuz.inputmethod.Borno
VERSION=$(tr -d '[:space:]' < Scripts/borno/VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_ID" ]; then echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)" >&2; exit 1; fi
APP=.build/Borno.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Borno" "$APP/Contents/MacOS/"
cp Resources/borno/* "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>Borno</string>
  <key>CFBundleDisplayName</key><string>Borno</string>
  <key>CFBundleExecutable</key><string>Borno</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mahfuz Alam</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>InputMethodConnectionName</key><string>Borno_Connection</string>
  <key>InputMethodServerControllerClass</key><string>BornoInputController</string>
  <key>tsInputMethodCharacterRepertoireKey</key><array><string>Beng</string></array>
  <key>tsInputMethodIconFileKey</key><string>menu.tiff</string>
  <key>ComponentInputModeDict</key>
  <dict>
    <key>tsVisibleInputModeOrderedArrayKey</key><array><string>$ID.Bangla</string></array>
    <key>tsInputModeListKey</key>
    <dict>
      <key>$ID.Bangla</key>
      <dict>
        <key>TISInputSourceID</key><string>$ID.Bangla</string>
        <key>TISIntendedLanguage</key><string>bn</string>
        <key>TISIconIsTemplate</key><true/>
        <key>tsInputModeScriptKey</key><string>smUnicodeScript</string>
        <key>tsInputModeIsVisibleKey</key><true/>
        <key>tsInputModePrimaryInRomanKey</key><false/>
        <key>tsInputModeMenuIconFileKey</key><string>menu.tiff</string>
        <key>tsInputModePaletteIconFileKey</key><string>menu.tiff</string>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

# Input Sources picker shows the mode ID unless InfoPlist.strings names it.
mkdir -p "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"$ID.Bangla" = "Borno";
CFBundleName = "Borno";
CFBundleDisplayName = "Borno";
STRINGS

# Notarization needs a secure timestamp, which only a real identity can get.
if [ -n "$SIGN_ID" ]; then TS=--timestamp; else TS=--timestamp=none; fi
codesign --force --deep --options runtime $TS -s "${SIGN_ID:--}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Borno: $(lipo -archs "$APP/Contents/MacOS/Borno")"

# Apple scans the app, then the ticket is stapled so it also passes Gatekeeper offline.
Scripts/notarize.sh "$APP"
echo "built $APP ($VERSION, build $BUILD)"

if [ "$1" != "app" ] && [ "$1" != "install" ]; then
  BG=$(mktemp -t borno-bg).png
  swift Scripts/prompter/makedmgbg.swift "$BG" Borno "Then open it once to add the keyboard"
  NAME=Borno BG="$BG" Scripts/clipboard/make-dmg.sh "$APP"
  rm -f "$BG"
  if [ -n "$SIGN_ID" ]; then codesign --force --timestamp -s "$SIGN_ID" build/Borno.dmg; fi
  Scripts/notarize.sh build/Borno.dmg
fi

if [ "$1" = "install" ]; then
  DEST="$HOME/Library/Input Methods"
  pkill -x Borno 2>/dev/null || true
  sleep 0.5
  mkdir -p "$DEST"
  rm -rf "$DEST/Borno.app"
  cp -R "$APP" "$DEST/"
  "$DEST/Borno.app/Contents/MacOS/Borno" --register
  echo "Installed $DEST/Borno.app"
fi
