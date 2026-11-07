#!/bin/sh
# Notarize: SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<keychain profile> ./bundle.sh prompter
# Version: Scripts/prompter/VERSION; build number = git commit count.
# Builds .build/Prompter.app (native Swift + SwiftUI, no dependencies).
#   ./bundle.sh prompter           build .build/Prompter.app
#   ./bundle.sh prompter install   build, then install to /Applications and launch
#   ./bundle.sh prompter dmg       build, then make build/Prompter.dmg (drag-to-Applications installer)
set -e
cd "$(dirname "$0")/../.."
APP=.build/Prompter.app  # not in build/, so build/ holds only the .dmg

if [ ! -f Resources/prompter/AppIcon.icns ]; then
  swiftc -O -swift-version 5 Scripts/prompter/makeicon.swift -o /tmp/prompter-makeicon
  /tmp/prompter-makeicon /tmp/AppIcon.iconset
  iconutil -c icns /tmp/AppIcon.iconset -o Resources/prompter/AppIcon.icns
  rm -rf /tmp/AppIcon.iconset /tmp/prompter-makeicon
fi

VERSION=$(tr -d '[:space:]' < Scripts/prompter/VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_ID" ]; then echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)" >&2; exit 1; fi
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product Prompter
BIN=$(swift build -c release $ARCHS --show-bin-path)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Prompter" "$APP/Contents/MacOS/"
cp Resources/prompter/* "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Prompter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.prompter.overlay</string>
  <key>CFBundleName</key><string>Prompter</string>
  <key>CFBundleDisplayName</key><string>Prompter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mahfuz Alam</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
if [ -n "$SIGN_ID" ]; then codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"; else codesign --force --sign - "$APP"; fi
Scripts/notarize.sh "$APP"
du -sh "$APP"

if [ "$1" = "dmg" ]; then
  # Installer window: app on the left, Applications on the right, arrow background.
  # Layout is set through Finder (AppleScript), so this needs a logged-in desktop session.
  VOL=/Volumes/Prompter
  TMP=$(mktemp -d)
  trap 'hdiutil detach "$VOL" -force >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
  hdiutil detach "$VOL" -force >/dev/null 2>&1 || true
  mkdir -p "$TMP/stage/.background"
  swiftc -O -swift-version 5 Scripts/prompter/makedmgbg.swift -o "$TMP/makedmgbg"
  "$TMP/makedmgbg" "$TMP/stage/.background/bg.png"
  cp -R "$APP" "$TMP/stage/"
  ln -s /Applications "$TMP/stage/Applications"
  hdiutil create -quiet -volname Prompter -srcfolder "$TMP/stage" -fs HFS+ -format UDRW -ov "$TMP/rw.dmg"
  hdiutil attach -quiet -noautoopen "$TMP/rw.dmg"
  sleep 2
  osascript <<'EOF' || echo "warning: could not style the DMG window (needs a Finder session); the dmg still works" >&2
tell application "Finder"
  tell disk "Prompter"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 542}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:bg.png"
    set position of item "Prompter.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
  cp Resources/prompter/AppIcon.icns "$VOL/.VolumeIcon.icns"
  SetFile -a C "$VOL" 2>/dev/null || true
  sync
  sleep 2
  hdiutil detach -quiet "$VOL"
  mkdir -p build
  rm -f build/Prompter.dmg
  hdiutil convert -quiet "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o build/Prompter.dmg
  if [ -n "$SIGN_ID" ]; then codesign --force --timestamp -s "$SIGN_ID" build/Prompter.dmg; fi
  Scripts/notarize.sh build/Prompter.dmg
  echo "Built $(pwd)/build/Prompter.dmg"
fi

if [ "$1" = "install" ]; then
  pkill -x Prompter 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Prompter.app
  cp -R "$APP" /Applications/
  open /Applications/Prompter.app
  echo "Installed /Applications/Prompter.app"
fi
