#!/bin/sh
# Notarize: SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<keychain profile> ./bundle.sh clipboard
# Version: Scripts/clipboard/VERSION; build number = git commit count.
# Builds .build/ClipboardManager.app + build/ClipboardManager.dmg (menu-bar agent, no Dock icon). Does not launch or install.
set -e
cd "$(dirname "$0")/../.."
swift build -c release --product ClipboardManager
[ -f Resources/clipboard/AppIcon.icns ] && [ -f Resources/clipboard/dmg-background.png ] || swift Scripts/clipboard/make-assets.swift  # committed; delete to regenerate
VERSION=$(tr -d '[:space:]' < Scripts/clipboard/VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_ID" ]; then echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)" >&2; exit 1; fi
APP=.build/ClipboardManager.app  # not in build/, so build/ holds only the .dmg
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClipboardManager "$APP/Contents/MacOS/"
cp Resources/clipboard/AppIcon.icns Resources/clipboard/NOTICE.txt "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.ClipboardManager</string>
  <key>CFBundleName</key><string>ClipboardManager</string>
  <key>CFBundleDisplayName</key><string>Clipboard Manager</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ClipboardManager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mahfuz Alam</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Plain ad-hoc signing pins the Accessibility grant to this exact binary's hash, so every rebuild re-prompts.
# An identifier-only requirement keeps the grant valid across rebuilds.
# With SIGN_ID (distribution) the Developer ID identity pins the grant instead.
if [ -n "$SIGN_ID" ]; then codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
else codesign --force --sign - -r='designated => identifier "com.local.ClipboardManager"' "$APP"; fi
Scripts/notarize.sh "$APP"
echo "built $APP ($VERSION, build $BUILD)"

Scripts/clipboard/make-dmg.sh "$APP"
if [ -n "$SIGN_ID" ]; then codesign --force --timestamp -s "$SIGN_ID" build/ClipboardManager.dmg; fi
Scripts/notarize.sh build/ClipboardManager.dmg

