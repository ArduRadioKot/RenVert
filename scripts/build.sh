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

if [[ -x /opt/homebrew/bin/ffmpeg ]]; then
  mkdir -p "$DEST/Contents/Resources/bin" "$DEST/Contents/Frameworks"
  cp -L /opt/homebrew/bin/ffmpeg "$DEST/Contents/Resources/bin/ffmpeg"
  python3 "$ROOT/scripts/bundle_dylibs.py" \
    "$DEST/Contents/Resources/bin/ffmpeg" \
    "$DEST/Contents/Frameworks"
fi

FFENT="$(mktemp)"
cat > "$FFENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
EOF
if [[ -d "$DEST/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' lib; do
    codesign --force --sign - "$lib"
  done < <(find "$DEST/Contents/Frameworks" -type f -print0)
fi
if [[ -x "$DEST/Contents/Resources/bin/ffmpeg" ]]; then
  codesign --force --sign - --entitlements "$FFENT" "$DEST/Contents/Resources/bin/ffmpeg"
fi
rm -f "$FFENT"
codesign --force --sign - --options runtime --entitlements "$ROOT/Sources/Renvert/Renvert.entitlements" "$DEST"
echo "Built $DEST"
lipo -info "$DEST/Contents/MacOS/Renvert" || true
if [[ -x "$DEST/Contents/Resources/bin/ffmpeg" ]]; then
  env -i "$DEST/Contents/Resources/bin/ffmpeg" -hide_banner -version
fi
