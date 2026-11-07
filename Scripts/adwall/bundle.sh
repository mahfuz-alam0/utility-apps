#!/bin/sh
# Builds .build/Adwall.app + build/Adwall.dmg (arm64 + x86_64, hardened runtime). Ad-hoc signed by default;
# SIGN_ID="Developer ID Application: Name (TEAMID)" signs for distribution.
#   ./bundle.sh adwall           build .build/Adwall.app + build/Adwall.dmg (drag-to-Applications installer)
#   ./bundle.sh adwall app       .app only
#   ./bundle.sh adwall install   build .app, then install to /Applications and launch
# Notarize: SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`> ./bundle.sh adwall
# Version: Scripts/adwall/VERSION; build number = git commit count.
# Install before turning protection on: the daemon removes itself if the app it was set up from disappears.
set -e
cd "$(dirname "$0")/../.."

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product Adwall
BIN=$(swift build -c release $ARCHS --show-bin-path)

VERSION=$(tr -d '[:space:]' < Scripts/adwall/VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_ID" ]; then echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)" >&2; exit 1; fi
APP=.build/Adwall.app  # not in build/, so build/ holds only the .dmg
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Adwall" "$APP/Contents/MacOS/"
cp Resources/adwall/* "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIdentifier</key><string>com.adwall.app</string>
  <key>CFBundleName</key><string>Adwall</string>
  <key>CFBundleDisplayName</key><string>Adwall</string>
  <key>CFBundleExecutable</key><string>Adwall</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mahfuz Alam</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Notarization needs a secure timestamp, which only a real identity can get.
if [ -n "$SIGN_ID" ]; then TS=--timestamp; else TS=--timestamp=none; fi
codesign --force --deep --options runtime $TS -s "${SIGN_ID:--}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Adwall: $(lipo -archs "$APP/Contents/MacOS/Adwall")"
Scripts/notarize.sh "$APP"
echo "built $APP ($VERSION, build $BUILD)"

if [ "$1" != "app" ] && [ "$1" != "install" ]; then
  BG=$(mktemp -t adwall-bg).png
  swift Scripts/prompter/makedmgbg.swift "$BG" Adwall
  NAME=Adwall BG="$BG" Scripts/clipboard/make-dmg.sh "$APP"
  rm -f "$BG"
  if [ -n "$SIGN_ID" ]; then codesign --force --timestamp -s "$SIGN_ID" build/Adwall.dmg; fi
  Scripts/notarize.sh build/Adwall.dmg
fi

if [ "$1" = "install" ]; then
  pkill -x Adwall 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Adwall.app
  cp -R "$APP" /Applications/
  open /Applications/Adwall.app
  echo "Installed /Applications/Adwall.app"
fi
