#!/bin/sh
# Usage: Scripts/make-dmg.sh build/ClipboardManager.app
# Builds build/ClipboardManager.dmg: drag-to-Applications installer window (660x400, background art, volume icon).
# Window layout is set through Finder (AppleScript); macOS may ask once to let your terminal/editor control Finder.
set -e
cd "$(dirname "$0")/.."
APP=$1
NAME="Clipboard Manager"
OUT=build/ClipboardManager.dmg
RW=build/rw.dmg
STAGE=build/dmg
MNT="/Volumes/$NAME"

# a mounted copy (e.g. the previous installer) would make the new volume mount as "Clipboard Manager 1"
hdiutil detach -quiet "$MNT" 2>/dev/null || hdiutil detach -quiet -force "$MNT" 2>/dev/null || true
rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.png "$STAGE/.background/bg.png"

hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
rm -rf "$STAGE"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"

# bounds are {left, top, right, bottom}: 660 wide, 400 content + 22 title bar. Icon positions match the Prompter DMG.
osascript <<EOF || echo "warning: could not style the DMG window; allow your terminal/editor to control Finder and rebuild" >&2
delay 1
tell application "Finder"
  tell disk "$NAME"
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
    set position of item "ClipboardManager.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

# volume icon goes in last: hdiutil -srcfolder drops it, and Finder deletes it / resets the flag while styling
sleep 2
cp Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"
sync
sleep 1
hdiutil detach -quiet "$MNT" || { sleep 2; hdiutil detach -quiet -force "$MNT"; }
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm "$RW"
echo "built $OUT"
