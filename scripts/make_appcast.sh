#!/usr/bin/env bash
#
# make_appcast.sh — produce a signed Sparkle appcast.xml for a release (MAS-142).
#
# Run this AFTER scripts/package_app.sh has built dist/Pathstitch-<version>.dmg.
# It locates Sparkle's `generate_appcast` tool (fetched by SPM into DerivedData),
# signs the dmg with the EdDSA private key in your login Keychain, and writes
# dist/appcast.xml with enclosure URLs pointing at the GitHub release assets.
#
# Then create the GitHub release for tag v<version> and upload BOTH
# dist/Pathstitch-<version>.dmg and dist/appcast.xml as assets. The app's
# SUFeedURL (.../releases/latest/download/appcast.xml) resolves to the newest
# release's appcast, so existing installs see the update.
#
# Usage:   bash scripts/make_appcast.sh <version>      # e.g. 1.1.0
#
set -euo pipefail

VERSION="${1:?usage: make_appcast.sh <version>   (e.g. 1.1.0)}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"
OWNER_REPO="Mason363/pathstitch"
DL_PREFIX="https://github.com/$OWNER_REPO/releases/download/v$VERSION/"

[ -d "$DIST" ] || { echo "✗ $DIST not found — run scripts/package_app.sh first"; exit 1; }

# Locate generate_appcast from the resolved Sparkle package.
GEN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -name generate_appcast 2>/dev/null | head -n1 || true)"
[ -x "$GEN" ] || { echo "✗ generate_appcast not found. Open the project in Xcode once to resolve Sparkle, then retry."; exit 1; }

echo "▶ generate_appcast: $GEN"
echo "▶ download prefix:  $DL_PREFIX"

# generate_appcast scans the folder for archives, signs them, and writes
# appcast.xml referencing <prefix><filename>.
"$GEN" --download-url-prefix "$DL_PREFIX" "$DIST"

echo "✓ Wrote $DIST/appcast.xml"
echo
echo "Next:"
echo "  gh release create v$VERSION \"$DIST/Pathstitch-$VERSION.dmg\" \"$DIST/appcast.xml\" \\"
echo "     --title \"Pathstitch $VERSION\" --notes \"…\""
