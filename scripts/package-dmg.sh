#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Renvert.app}"
DMG="$ROOT/dist/Renvert-1.0.0.dmg"
mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -volname Renvert -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Created $DMG"
echo "Notarization is not run here. Use your Developer ID certificate:"
echo "  xcrun notarytool submit \"$DMG\" --keychain-profile \"AC_PROFILE\" --wait"
echo "  xcrun stapler staple \"$DMG\""
