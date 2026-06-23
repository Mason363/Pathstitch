#!/usr/bin/env bash
#
# package_app.sh — build a self-contained, distributable Pathstitch.app + .dmg.
#
# It bundles a trimmed copy of the Python backend (interpreter + pathstitch_core +
# all packages) inside Contents/Resources so the app runs on any Apple-Silicon Mac
# with NO conda/repo installed. Ad-hoc signed (no Apple Developer ID required) —
# recipients bypass Gatekeeper once (see README ▸ Installing a non-notarized app).
#
# Usage:   bash scripts/package_app.sh
# Output:  dist/Pathstitch-<version>.dmg
#
set -euo pipefail

# ---- config -----------------------------------------------------------------
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONDA_ENV="${CONDA_ENV:-/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch}"
SCHEME="Pathstitch"
PROJ="$REPO/Pathstitch/Pathstitch.xcodeproj"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print MARKETING_VERSION' /dev/stdin 2>/dev/null <<<'' || true)"
VERSION="${VERSION:-1.0}"
DIST="$REPO/dist"
APP_OUT="$DIST/Pathstitch.app"
DMG_OUT="$DIST/Pathstitch-$VERSION.dmg"

echo "▶ Repo:     $REPO"
echo "▶ Conda env: $CONDA_ENV"
[ -x "$CONDA_ENV/bin/python3.11" ] || { echo "✗ python3.11 not found in $CONDA_ENV"; exit 1; }

# ---- 1. build the Release .app ----------------------------------------------
echo "▶ Building Release .app …"
rm -rf "$REPO/Pathstitch/build"
xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$REPO/Pathstitch/build" clean build >/dev/null
BUILT="$REPO/Pathstitch/build/Build/Products/Release/Pathstitch.app"
[ -d "$BUILT" ] || { echo "✗ build did not produce $BUILT"; exit 1; }

rm -rf "$DIST"; mkdir -p "$DIST"
cp -R "$BUILT" "$APP_OUT"
RES="$APP_OUT/Contents/Resources"

# ---- 2. bundle a trimmed Python env -----------------------------------------
echo "▶ Bundling Python env (trimming dev-only bloat) …"
rsync -a \
  --exclude 'include/' --exclude 'conda-meta/' \
  --exclude 'share/man/' --exclude 'share/doc/' --exclude 'share/gtk-doc/' \
  --exclude 'share/locale/' --exclude 'share/cmake/' \
  --exclude '__pycache__/' --exclude '*.a' \
  --exclude 'lib/cmake/' --exclude 'lib/pkgconfig/' \
  --exclude 'libLLVM*' --exclude 'libclang*' \
  --exclude 'qt6/' --exclude 'libQt6*' \
  --exclude 'libopenvino*' --exclude 'openvino*' \
  --exclude 'libvtk*' \
  --exclude 'libav*' --exclude 'libpostproc*' --exclude 'libswscale*' --exclude 'libswresample*' --exclude 'ffmpeg' \
  "$CONDA_ENV/" "$RES/pyenv/"

# ---- 3. bundle the geometry engine ------------------------------------------
echo "▶ Bundling pathstitch_core …"
rsync -a --exclude '__pycache__/' "$REPO/pathstitch_core/" "$RES/pathstitch_core/"

# ---- 4. ad-hoc sign (no Developer ID; hardened runtime stays off) -----------
echo "▶ Ad-hoc signing (this is the slow part) …"
codesign --force --deep --sign - "$APP_OUT"
codesign --verify --verbose=1 "$APP_OUT" || true

# ---- 5. build the drag-install .dmg -----------------------------------------
# A styled window (leather background + positioned icons + Applications arrow)
# when scripts/dmg/background.png exists; otherwise a plain drag-install DMG so
# packaging never depends on the artwork being present. Layout constants here
# MUST match scripts/dmg/background-template.svg.
echo "▶ Building .dmg …"
STAGE="$(mktemp -d)"
cp -R "$APP_OUT" "$STAGE/Pathstitch.app"
ln -s /Applications "$STAGE/Applications"

DMG_BG="$REPO/scripts/dmg/background.png"
VOL="Pathstitch"
WIN_W=600; WIN_H=400          # window content size (points)
APP_X=150;  APP_Y=190         # Pathstitch.app icon center
APPL_X=450; APPL_Y=190        # Applications shortcut icon center
ICON_SIZE=100

build_plain_dmg() {
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG_OUT" >/dev/null
}

build_styled_dmg() {
  mkdir -p "$STAGE/.background"
  cp "$DMG_BG" "$STAGE/.background/background.png" || return 1

  local rw="$DIST/Pathstitch-rw.dmg"
  rm -f "$rw"
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW "$rw" >/dev/null || return 1

  local dev
  dev=$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | grep -E '^/dev/' | head -1 | awk '{print $1}')
  [ -n "$dev" ] || return 1
  sleep 2

  osascript <<OSA || { hdiutil detach "$dev" >/dev/null 2>&1 || true; return 1; }
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set background picture of opts to file ".background:background.png"
    set position of item "Pathstitch.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPL_X, $APPL_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

  sync
  hdiutil detach "$dev" >/dev/null 2>&1 || true
  hdiutil convert "$rw" -format UDZO -ov -o "$DMG_OUT" >/dev/null || { rm -f "$rw"; return 1; }
  rm -f "$rw"
}

if [ -f "$DMG_BG" ]; then
  echo "  • styling DMG with scripts/dmg/background.png …"
  build_styled_dmg || { echo "  • styled DMG failed — falling back to a plain drag-install DMG"; build_plain_dmg; }
else
  echo "  • no scripts/dmg/background.png — plain drag-install DMG (see scripts/dmg/README.md to add the leather background)"
  build_plain_dmg
fi
rm -rf "$STAGE"

echo "✓ Done:"
echo "  app: $APP_OUT"
echo "  dmg: $DMG_OUT  ($(du -sh "$DMG_OUT" | cut -f1))"
