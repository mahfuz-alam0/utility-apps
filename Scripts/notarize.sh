#!/bin/sh
# Usage: NOTARY_PROFILE=name Scripts/notarize.sh <App.app|App.dmg>   (run from the repo root)
# Sends it to Apple's notary service, then staples the ticket so Gatekeeper passes offline. No-op without NOTARY_PROFILE.
set -e
[ -n "$NOTARY_PROFILE" ] || exit 0
SUBMIT=$1
if [ -d "$1" ]; then SUBMIT=build/notarize.zip; mkdir -p build; rm -f "$SUBMIT"; ditto -c -k --keepParent "$1" "$SUBMIT"; fi
xcrun notarytool submit "$SUBMIT" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$1"
[ "$SUBMIT" = "$1" ] || rm -f "$SUBMIT"
