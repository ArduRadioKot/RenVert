# Renvert

![head.png]

Native macOS menu-bar utility: **rename a file in Finder to convert its contents**.

Authors: **FrogeeSoft**.

Renvert is an independent implementation inspired by the public Consul 2.x workflow. It does not include Consul code, assets, or license checks. Files never leave the Mac.

Requires **macOS 14+**. Builds as a Universal Binary (`arm64` + `x86_64`).

## What works in this drop

- Menu bar app with pause, progress, recent undo, settings, onboarding
- FSEvents watching of Desktop / Downloads / Documents (and any folder you add)
- Content-based format detection (magic bytes + ZIP containers)
- Real conversions for the first scenarios: HEIC↔JPEG, PNG↔WebP/JPEG, MOV→MP4, WAV→M4A/MP3, DOCX→PDF, PDF→PNG, XLSX→CSV, JSON→YAML, folder→ZIP
- Filename grammar (`+q80`, `+min`, `+mute`, `+page2-5`, `photo.png,webp`, `Photos.folder,zip`, `!`)
- Backups, undo, crash journal
- English and Russian UI strings
- Finder **Services** entry (“Convert with Renvert”)

See `docs/capabilities.md` for the honest matrix. Renvert does not claim Consul’s full 5,211 pairs.

## Build

```bash
# Core tests
swift test

# App
chmod +x scripts/build.sh scripts/package-dmg.sh
./scripts/build.sh
open dist/Renvert.app
```

Xcode: open `Renvert.xcodeproj` or `Package.swift`.

The Release script signs ad-hoc (`-`) and can copy a local `ffmpeg` into the bundle if Homebrew has one. Notarization needs your Developer ID; the project does not invent certificates.

```bash
./scripts/package-dmg.sh
```

## Use

1. Launch Renvert. It lives in the menu bar (no Dock icon).
2. Pick folders during onboarding. macOS will ask for access to those folders.
3. Rename `photo.heic` to `photo.jpg` in Finder.
4. In **Ask first** mode, confirm from the menu. In automatic mode, conversion starts after the file is stable.
5. Undo from the menu bar or Settings → History.

Full Disk Access is **not** required for the default Desktop / Downloads / Documents set. Enable it only if you want to watch locations the sandbox-style prompts cannot reach.

## Tests

`Tests/RenvertCoreTests` writes real files and checks magic bytes, not just extensions. OCR and Speech tests are not forced on CI because they need extra TCC prompts.

## Layout

```
Sources/RenvertCore   conversion engine, monitor, parser
Sources/Renvert       menu bar app, settings, onboarding
Tests/RenvertCoreTests
docs/                 research, progress, capabilities, licenses
scripts/              Xcode project generator, app build, DMG, icon generator
```

## Icon

`logoR.png` is the source artwork. After changing it, regenerate the app icon, the in-app logo and the menu bar glyph:

```bash
python3 scripts/make_icon.py
```
