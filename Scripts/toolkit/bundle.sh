#!/bin/sh
# Builds .build/Toolkit.app + build/Toolkit.dmg: one app that opens, quits and installs Clipboard Manager, Prompter,
# Adwall and Borno. It carries a signed copy of each in Contents/Helpers. The standalone builds are unchanged.
#   ./bundle.sh toolkit        .app + .dmg
#   ./bundle.sh toolkit app    .app only
# Notarize: SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<keychain profile> ./bundle.sh toolkit
# (one submission covers the embedded apps). Version: Scripts/toolkit/VERSION; build number = git commit count.
set -e
cd "$(dirname "$0")/../.."

VERSION=$(tr -d '[:space:]' < Scripts/toolkit/VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_ID" ]; then echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)" >&2; exit 1; fi

# Notarizing happens once, on the outer app, so the inner builds skip it.
for t in clipboard prompter adwall borno; do NOTARY_PROFILE= Scripts/$t/bundle.sh app; done

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product Toolkit
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=.build/Toolkit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Toolkit" "$APP/Contents/MacOS/"
cp Resources/toolkit/* "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
for a in ClipboardManager Prompter Adwall Borno; do cp -R ".build/$a.app" "$APP/Contents/Helpers/"; done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIdentifier</key><string>com.mahfuz.toolkit</string>
  <key>CFBundleName</key><string>Toolkit</string>
  <key>CFBundleDisplayName</key><string>Toolkit</string>
  <key>CFBundleExecutable</key><string>Toolkit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mahfuz Alam</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Inner apps are already signed; sign only the outer one (no --deep, it would re-sign them).
if [ -n "$SIGN_ID" ]; then TS=--timestamp; else TS=--timestamp=none; fi
codesign --force --options runtime $TS -s "${SIGN_ID:--}" "$APP"
codesign --verify --deep --strict "$APP"
Scripts/notarize.sh "$APP"
echo "built $APP ($VERSION, build $BUILD)"

if [ "$1" != "app" ]; then
  BG=$(mktemp -t toolkit-bg).png
  swift Scripts/prompter/makedmgbg.swift "$BG" Toolkit
  NAME=Toolkit BG="$BG" Scripts/clipboard/make-dmg.sh "$APP"
  rm -f "$BG"
  if [ -n "$SIGN_ID" ]; then codesign --force --timestamp -s "$SIGN_ID" build/Toolkit.dmg; fi
  Scripts/notarize.sh build/Toolkit.dmg
fi
