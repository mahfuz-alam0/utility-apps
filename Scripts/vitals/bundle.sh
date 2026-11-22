#!/bin/sh
# Builds .build/Vitals.app + build/Vitals.dmg (arm64 + x86_64, hardened runtime; temperature reads on Apple Silicon only). Ad-hoc signed by default;
# SIGN_ID="Developer ID Application: Name (TEAMID)" signs for distribution.
#   ./bundle.sh vitals           build .build/Vitals.app + build/Vitals.dmg (drag-to-Applications installer)
#   ./bundle.sh vitals app       .app only
#   ./bundle.sh vitals install   build .app, then install to /Applications and launch
# Notarize: SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`> ./bundle.sh vitals
# Version: Scripts/vitals/VERSION; build number = git commit count.
set -e
cd "$(dirname "$0")/../.."

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product Vitals
BIN=$(swift build -c release $ARCHS --show-bin-path)

VERSION=$(tr -d '[:space:]' < Scripts/vitals/VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_ID" ]; then echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)" >&2; exit 1; fi
APP=.build/Vitals.app  # not in build/, so build/ holds only the .dmg
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Vitals" "$APP/Contents/MacOS/"
cp Resources/vitals/* "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIdentifier</key><string>com.vitals.app</string>
  <key>CFBundleName</key><string>Vitals</string>
  <key>CFBundleDisplayName</key><string>Vitals</string>
  <key>CFBundleExecutable</key><string>Vitals</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mahfuz Alam</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
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
echo "Vitals: $(lipo -archs "$APP/Contents/MacOS/Vitals")"
Scripts/notarize.sh "$APP"
echo "built $APP ($VERSION, build $BUILD)"

if [ "$1" != "app" ] && [ "$1" != "install" ]; then
  BG=$(mktemp -t vitals-bg).png
  swift Scripts/prompter/makedmgbg.swift "$BG" Vitals
  NAME=Vitals BG="$BG" Scripts/clipboard/make-dmg.sh "$APP"
  rm -f "$BG"
  if [ -n "$SIGN_ID" ]; then codesign --force --timestamp -s "$SIGN_ID" build/Vitals.dmg; fi
  Scripts/notarize.sh build/Vitals.dmg
fi

if [ "$1" = "install" ]; then
  pkill -x Vitals 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Vitals.app
  cp -R "$APP" /Applications/
  open /Applications/Vitals.app
  echo "Installed /Applications/Vitals.app"
fi
