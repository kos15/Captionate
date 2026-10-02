#!/usr/bin/env bash
# Builds Captionate.app and Captionate.dmg.
# Requirements: macOS 14+ and Xcode Command Line Tools (xcode-select --install).
# Usage:  ./build.sh            -> native arch (Apple Silicon or Intel)
#         UNIVERSAL=1 ./build.sh  -> arm64 + x86_64 (needs full Xcode)
set -euo pipefail
cd "$(dirname "$0")"

APP="Captionate"
OUT="build"
BUNDLE="$OUT/$APP.app"

echo "▸ Compiling (release)…"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=()
fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▸ Assembling $APP.app…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --verbose "$BUNDLE"

echo "▸ Creating DMG…"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$OUT/$APP.dmg"
mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$APP.dmg" >/dev/null
rm -rf "$STAGE"

echo ""
echo "✅ Done"
echo "   App: $BUNDLE"
echo "   DMG: $OUT/$APP.dmg"
echo "   Open the DMG and drag Captionate into Applications."
