#!/bin/sh
# Builds .build/Downloader.app and build/Downloader.dmg (native Swift + SwiftUI, no dependencies).
#   ./bundle.sh downloader           build both
#   ./bundle.sh downloader install   also install to /Applications and launch
set -e
cd "$(dirname "$0")/../.."
APP=.build/Downloader.app

if [ ! -f Resources/downloader/AppIcon.icns ]; then
  swiftc -O -swift-version 5 Scripts/downloader/makeicon.swift -o /tmp/downloader-makeicon
  /tmp/downloader-makeicon /tmp/AppIcon.iconset
  iconutil -c icns /tmp/AppIcon.iconset -o Resources/downloader/AppIcon.icns
  rm -rf /tmp/AppIcon.iconset /tmp/downloader-makeicon
fi

swift build -c release --product Downloader
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Downloader "$APP/Contents/MacOS/"
cp Resources/downloader/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/downloader/extension "$APP/Contents/Resources/"  # app menu: File → Show Browser Extension in Finder
# NSAllowsArbitraryLoads: a download manager has to fetch plain http:// links too
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Downloader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.downloader.app</string>
  <key>CFBundleName</key><string>Downloader</string>
  <key>CFBundleDisplayName</key><string>Downloader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
du -sh "$APP"

# plain drag-to-Applications disk image (no Finder window layout, so it also works without a desktop session)
TMP=$(mktemp -d)
mkdir -p build
cp -R "$APP" "$TMP/"
ln -s /Applications "$TMP/Applications"
rm -f build/Downloader.dmg
hdiutil create -quiet -volname Downloader -srcfolder "$TMP" -fs HFS+ -format UDZO -o build/Downloader.dmg
rm -rf "$TMP"
echo "Built $(pwd)/build/Downloader.dmg"

if [ "$1" = "install" ]; then
  pkill -x Downloader 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Downloader.app
  cp -R "$APP" /Applications/
  open /Applications/Downloader.app
  echo "Installed /Applications/Downloader.app"
fi
