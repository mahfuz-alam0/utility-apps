#!/bin/sh
# Stops the running copy, builds .build/ClipboardManager.app + build/ClipboardManager.dmg (menu-bar agent, no Dock icon), launches it.
set -e
cd "$(dirname "$0")"
pkill -x ClipboardManager || true  # old copy still holds the ⌘⇧V hotkey
swift build -c release
[ -f Resources/AppIcon.icns ] && [ -f Resources/dmg-background.png ] || swift Scripts/make-assets.swift  # committed; delete to regenerate
APP=.build/ClipboardManager.app  # not in build/, so build/ holds only the .dmg
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClipboardManager "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.ClipboardManager</string>
  <key>CFBundleName</key><string>ClipboardManager</string>
  <key>CFBundleDisplayName</key><string>Clipboard Manager</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ClipboardManager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Plain ad-hoc signing pins the Accessibility grant to this exact binary's hash, so every rebuild re-prompts.
# An identifier-only requirement keeps the grant valid across rebuilds.
codesign --force --sign - -r='designated => identifier "com.local.ClipboardManager"' "$APP"
echo "built $APP"

Scripts/make-dmg.sh "$APP"

open "$APP"
