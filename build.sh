#!/bin/zsh
# Builds "File Utilities.app" in this folder.
set -euo pipefail
cd "$(dirname "$0")"

APP="File Utilities.app"
BUILD=.build/release

echo "▸ Compiling (release)…"
swift build -c release --arch arm64 2>&1 | grep -E "error:|Compiling|Build complete" || true
[[ -x "$BUILD/FileUtilities" ]] || { echo "Build failed"; exit 1; }

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/FileUtilities" "$APP/Contents/MacOS/FileUtilities"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ Drawing icon…"
  mkdir -p Resources
  TMP=$(mktemp -d)
  swift Scripts/make_icon.swift "$TMP/icon.png"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle ffmpeg and all its libraries so the app works on Macs without Homebrew.
FFMPEG=""
for candidate in Resources/ffmpeg /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  if [[ -x "$candidate" ]]; then FFMPEG="$candidate"; break; fi
done
if [[ -n "$FFMPEG" ]]; then
  echo "▸ Bundling ffmpeg from $FFMPEG…"
  python3 Scripts/bundle_ffmpeg.py "$FFMPEG" "$APP"
else
  echo "▸ ffmpeg not found — building without it (MKV/WebM/MP3… will be unavailable)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>File Utilities</string>
  <key>CFBundleDisplayName</key><string>File Utilities</string>
  <key>CFBundleIdentifier</key><string>com.alpbayrak.fileutilities</string>
  <key>CFBundleExecutable</key><string>FileUtilities</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - "$APP" >/dev/null
echo "✓ Built $(pwd)/$APP"
