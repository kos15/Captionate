#!/usr/bin/env bash
# Builds Captionate.app and Captionate.dmg.
# Requirements: macOS 14+ and Xcode Command Line Tools (xcode-select --install).
# Usage:  ./build.sh            -> native arch (Apple Silicon or Intel)
#         UNIVERSAL=1 ./build.sh  -> arm64 + x86_64 (needs full Xcode)
#
# DMG window background (DMG_BACKGROUND):
#   dots (default) | grid | diagonal | waves  -> built-in patterns in Resources/dmg
#   /path/to/image.png                        -> your own image (scaled to 660x400)
#   e.g.  DMG_BACKGROUND=waves ./build.sh
#         DMG_BACKGROUND=~/Pictures/bg.png ./build.sh
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
DMG="$OUT/$APP.dmg"
RW_DMG="$OUT/$APP-rw.dmg"
STAGE="$OUT/dmg"
ICON="Resources/AppIcon.icns"
BG_CHOICE="${DMG_BACKGROUND:-dots}"
rm -rf "$STAGE" "$DMG" "$RW_DMG"
mkdir -p "$STAGE/.background"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Volume icon: Finder shows the Captionate icon for the mounted disk, not a generic drive.
cp "$ICON" "$STAGE/.VolumeIcon.icns"

# Window background: a built-in pattern, or a custom image.
case "$BG_CHOICE" in
  dots|grid|diagonal|waves)
    # Merge 1x + 2x into one Retina-aware TIFF.
    tiffutil -cathidpicheck "Resources/dmg/background-$BG_CHOICE.png" \
      "Resources/dmg/background-$BG_CHOICE@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
    ;;
  *)
    BG_PATH="${BG_CHOICE/#\~/$HOME}"
    if [[ ! -f "$BG_PATH" ]]; then
      echo "✗ DMG_BACKGROUND: '$BG_CHOICE' is not a built-in pattern (dots, grid, diagonal, waves) or an existing image file." >&2
      exit 1
    fi
    sips -s format png -z 400 660 "$BG_PATH" --out "$STAGE/.background/background.png" >/dev/null
    ;;
esac
BG_FILE="$(basename "$(ls "$STAGE/.background/"background.*)")"

# Leave headroom so Finder can write its .DS_Store layout file.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW_DMG" >/dev/null
rm -rf "$STAGE"

# Mount read-write, flag the custom volume icon and lay out the Finder window.
hdiutil detach "/Volumes/$APP" -force >/dev/null 2>&1 || true
MOUNT_DIR="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[[ -d "$MOUNT_DIR" ]] || { echo "✗ Couldn't mount $RW_DMG" >&2; exit 1; }
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_DIR"
else
  # kHasCustomIcon bit in the volume root's FinderInfo.
  xattr -wx com.apple.FinderInfo \
    "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT_DIR"
fi

if ! osascript <<OSA
tell application "Finder"
  tell disk "$(basename "$MOUNT_DIR")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:$BG_FILE"
    set position of item "$APP.app" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
then
  echo "  ⚠ Finder layout skipped (allow Terminal to control Finder in System Settings → Privacy → Automation)."
fi

chmod -Rf go-w "$MOUNT_DIR" || true
sync
hdiutil detach "$MOUNT_DIR" >/dev/null || hdiutil detach "$MOUNT_DIR" -force >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"

# Give the .dmg file itself the Captionate icon (shown in Finder before it's opened).
osascript -l JavaScript >/dev/null <<JXA || echo "  ⚠ Couldn't set the .dmg file icon."
ObjC.import('AppKit');
const img = $.NSImage.alloc.initWithContentsOfFile('$PWD/$ICON');
if (!$.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, '$PWD/$DMG', 0)) { throw new Error('setIcon failed'); }
JXA

echo ""
echo "✅ Done"
echo "   App: $BUNDLE"
echo "   DMG: $DMG  (background: $BG_CHOICE)"
echo "   Open the DMG and drag Captionate into Applications."
