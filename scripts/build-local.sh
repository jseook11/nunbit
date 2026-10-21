#!/bin/bash
# Nunbit — local build without Xcode (Command Line Tools only).
#
# Full Xcode is not required on this machine: swiftc compiles every source file and the
# app bundle is assembled by hand (Info.plist + iconutil icon + ad-hoc signature).
# See docs/BLOCKING.md B-005 for the signing/Xcode background.
#
# Usage:
#   ./scripts/build-local.sh              # build build/Nunbit.app
#   ./scripts/build-local.sh --debug      # -Onone -DDEBUG (print() diagnostics)
#   ./scripts/build-local.sh --install    # also replace /Applications/Nunbit.app
#   ./scripts/build-local.sh --run        # install, then launch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Nunbit.app"
DEBUG=0
INSTALL=0
RUN=0

for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=1 ;;
    --install) INSTALL=1 ;;
    --run) INSTALL=1; RUN=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

SDK="$(xcrun --show-sdk-path)"

SWIFT_FLAGS=(
  -swift-version 6 -strict-concurrency=minimal
  -target arm64-apple-macos14.0 -sdk "$SDK"
  -import-objc-header "$ROOT/Nunbit/Nunbit-Bridging-Header.h"
  -parse-as-library -module-name Nunbit
)
if [ "$DEBUG" = 1 ]; then
  SWIFT_FLAGS+=(-Onone -DDEBUG)
else
  SWIFT_FLAGS+=(-O)
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Nunbit" -name '*.swift' | sort)

echo "==> Compiling ${#SOURCES[@]} Swift files with swiftc…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${SWIFT_FLAGS[@]}" -o "$APP/Contents/MacOS/Nunbit" "${SOURCES[@]}"

echo "==> Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Nunbit</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.jseook11.nunbit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Nunbit</string>
	<key>CFBundleDisplayName</key>
	<string>Nunbit</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Nunbit - Free &amp; Open Source</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> Building AppIcon.icns…"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$ROOT/scripts/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ROOT/scripts/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ROOT/scripts/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ROOT/scripts/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ROOT/scripts/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ROOT/scripts/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ROOT/scripts/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ROOT/scripts/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ROOT/scripts/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ROOT/scripts/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Signing (ad-hoc)…"
codesign --force --sign - --entitlements "$ROOT/Nunbit/Nunbit.entitlements" \
  --identifier com.jseook11.nunbit "$APP"

if [ "$INSTALL" = 1 ]; then
  echo "==> Installing to /Applications…"
  osascript -e 'quit app "Nunbit"' >/dev/null 2>&1 || true
  pkill -x Nunbit >/dev/null 2>&1 || true
  sleep 0.5
  rm -rf /Applications/Nunbit.app
  ditto "$APP" /Applications/Nunbit.app
fi

if [ "$RUN" = 1 ]; then
  echo "==> Launching…"
  open -a /Applications/Nunbit.app
fi

echo ""
echo "Done: $APP"
if [ "$INSTALL" = 1 ]; then echo "Installed: /Applications/Nunbit.app"; fi
echo "Note: ad-hoc signed — re-approve Accessibility after a rebuild if the brightness keys stop working."
