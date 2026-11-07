#!/bin/sh
# Builds .build/Borno.app, an input method (arm64 + x86_64). Ad-hoc signed by default;
# SIGN_ID="Developer ID Application: Name (TEAMID)" signs for distribution.
#   ./bundle.sh borno           build .build/Borno.app
#   ./bundle.sh borno install   build, copy to ~/Library/Input Methods, register + enable the input source
# After install: System Settings > Keyboard > Text Input > Input Sources > + > Bangla > Borno, then switch to it
# from the menu bar (or Ctrl+Space). If it does not show up, log out and in once.
set -e
cd "$(dirname "$0")/../.."

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product Borno
BIN=$(swift build -c release $ARCHS --show-bin-path)

ID=com.mahfuz.inputmethod.Borno
APP=.build/Borno.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Borno" "$APP/Contents/MacOS/"
cp Resources/borno/* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Borno</string>
  <key>CFBundleDisplayName</key><string>Borno</string>
  <key>CFBundleExecutable</key><string>Borno</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
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

# Notarization needs a secure timestamp, which only a real identity can get.
if [ -n "$SIGN_ID" ]; then TS=--timestamp; else TS=--timestamp=none; fi
codesign --force --deep --options runtime $TS -s "${SIGN_ID:--}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Borno: $(lipo -archs "$APP/Contents/MacOS/Borno")"
echo "built $APP"

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
