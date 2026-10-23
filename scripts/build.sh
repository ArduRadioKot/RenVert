#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 "$ROOT/scripts/generate_xcodeproj.py"

DEST="${1:-$ROOT/dist/Renvert.app}"
mkdir -p "$(dirname "$DEST")"

# Prefer a real Xcode .app when the generated project builds.
if xcodebuild \
  -project "$ROOT/Renvert.xcodeproj" \
  -scheme Renvert \
  -configuration Release \
  -destination 'platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY='-' \
  -derivedDataPath "$ROOT/.derivedData" \
  build
then
  BUILT="$ROOT/.derivedData/Build/Products/Release/Renvert.app"
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  cp -R "$BUILT" "$DEST"
else
  echo "xcodebuild failed; wrapping the SwiftPM executable."
  swift build -c release --product Renvert
  BIN="$(swift build -c release --product Renvert --show-bin-path)/Renvert"
  rm -rf "$DEST"
  mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
  cp "$BIN" "$DEST/Contents/MacOS/Renvert"
  cp "$ROOT/Sources/Renvert/Info.plist" "$DEST/Contents/Info.plist"
  echo -n 'APPL????' > "$DEST/Contents/PkgInfo"
fi

if [[ -x /opt/homebrew/bin/ffmpeg ]] && /opt/homebrew/bin/ffmpeg -version >/dev/null 2>&1; then
  mkdir -p "$DEST/Contents/Resources/bin"
  cp /opt/homebrew/bin/ffmpeg "$DEST/Contents/Resources/bin/ffmpeg" || true
fi

codesign --force --deep --sign - --entitlements "$ROOT/Sources/Renvert/Renvert.entitlements" "$DEST"
echo "Built $DEST"
lipo -info "$DEST/Contents/MacOS/Renvert" || true
