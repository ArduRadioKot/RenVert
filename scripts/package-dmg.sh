#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Renvert.app}"
if [[ ! -d "$APP/Contents/MacOS" ]]; then
  echo "App not found: $APP" >&2
  echo "Build it first: ./scripts/build.sh" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/Renvert-${VERSION}.dmg"
VOL="Renvert"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/renvert-dmg.XXXXXX")"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
DEVICE=""
MOUNT=""

cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
  elif [[ -n "$MOUNT" && -d "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$STAGE/.background" "$ROOT/dist"
python3 "$ROOT/scripts/make_dmg_background.py" \
  "$STAGE/.background/background.png" \
  "$STAGE/.background/background@2x.png"

ICONSET="$WORK/Renvert.iconset"
mkdir -p "$ICONSET"
cp "$ROOT/Sources/Renvert/Assets.xcassets/AppIcon.appiconset"/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$WORK/Renvert.icns"

ditto "$APP" "$STAGE/Renvert.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEVICE="$(printf '%s\n' "$ATTACH" | awk '/Apple_HFS|Apple_APFS/ { print $1; exit }')"
MOUNT="$(printf '%s\n' "$ATTACH" | python3 -c '
import sys
for line in sys.stdin:
    if "/Volumes/" not in line:
        continue
    mount = line.rstrip("\n").split("\t")[-1].strip()
    if mount.startswith("/Volumes/"):
        print(mount)
        break
')"
if [[ -z "$DEVICE" || -z "$MOUNT" || ! -d "$MOUNT" ]]; then
  echo "Could not mount $RW" >&2
  printf '%s\n' "$ATTACH" >&2
  exit 1
fi

chflags hidden "$MOUNT/.background" || true

python3 - "${MOUNT:t}" <<'PY' || echo "Finder layout was skipped; the disk image still contains Renvert.app and Applications."
import subprocess, sys
vol = sys.argv[1]
script = f'''
tell application "Finder"
  tell disk "{vol}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {{240, 120, 900, 520}}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    delay 1
    set background picture of viewOptions to file ".background:background.png"
    delay 1
    set position of item "Renvert.app" of container window to {{180, 168}}
    set position of item "Applications" of container window to {{480, 168}}
    update without registering applications
    delay 2
    close
  end tell
end tell
'''
subprocess.run(["osascript", "-e", script], check=True, timeout=30)
PY

sync
for _ in {1..20}; do
  [[ -f "$MOUNT/.DS_Store" ]] && break
  sleep 0.25
done
# Finder drops .VolumeIcon.icns if it is present while the window is being arranged.
cp "$WORK/Renvert.icns" "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a V "$MOUNT/.background" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT"
else
  chflags hidden "$MOUNT/.VolumeIcon.icns" || true
fi
sync
if [[ ! -f "$MOUNT/.VolumeIcon.icns" ]]; then
  echo "Volume icon is missing from $MOUNT" >&2
  exit 1
fi

hdiutil detach "$DEVICE" >/dev/null
DEVICE=""
MOUNT=""

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "Created $DMG"
echo "Ad-hoc signature only. Notarization needs a Developer ID certificate:"
echo "  xcrun notarytool submit \"$DMG\" --keychain-profile \"AC_PROFILE\" --wait"
echo "  xcrun stapler staple \"$DMG\""
