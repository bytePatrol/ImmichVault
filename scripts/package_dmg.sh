#!/bin/bash
# package_dmg.sh — Creates ImmichVault.dmg for distribution
#
# Packages ImmichVault.app (from dist/), README.txt, and sample-export.json
# into a DMG with an /Applications symlink for drag-and-drop installation.
#
# Usage:
#   ./scripts/package_dmg.sh
#
# Prerequisites:
#   Run build_release.sh first to produce dist/ImmichVault.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_PATH="$DIST_DIR/ImmichVault.app"
DMG_PATH="$DIST_DIR/ImmichVault.dmg"
VOLUME_NAME="ImmichVault"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ImmichVault DMG Packager ===${NC}"
echo ""

# ------------------------------------------------------------------
# Check for built app
# ------------------------------------------------------------------

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}[error]${NC} ImmichVault.app not found at: $APP_PATH"
    echo "       Run './scripts/build_release.sh' first to build the app."
    exit 1
fi

echo -e "  App found: ${GREEN}$APP_PATH${NC}"
echo ""

# ------------------------------------------------------------------
# [1/4] Create staging directory
# ------------------------------------------------------------------

echo -e "${GREEN}[1/4]${NC} Preparing staging directory..."

STAGING=$(mktemp -d)
trap "rm -rf $STAGING" EXIT

# Copy the app bundle
cp -R "$APP_PATH" "$STAGING/ImmichVault.app"
echo -e "      Copied ImmichVault.app"

# Copy README.txt (optional — warn if missing)
if [ -f "$DIST_DIR/README.txt" ]; then
    cp "$DIST_DIR/README.txt" "$STAGING/README.txt"
    echo -e "      Copied README.txt"
else
    echo -e "      ${YELLOW}[warn]${NC} README.txt not found in dist/ — skipping"
fi

# Copy sample-export.json (optional — warn if missing)
if [ -f "$DIST_DIR/sample-export.json" ]; then
    cp "$DIST_DIR/sample-export.json" "$STAGING/sample-export.json"
    echo -e "      Copied sample-export.json"
else
    echo -e "      ${YELLOW}[warn]${NC} sample-export.json not found in dist/ — skipping"
fi

# Create Applications symlink for drag-and-drop install
ln -s /Applications "$STAGING/Applications"
echo -e "      Created /Applications symlink"
echo ""

# ------------------------------------------------------------------
# [2/4] Create DMG
# ------------------------------------------------------------------

echo -e "${GREEN}[2/4]${NC} Creating DMG..."

# Remove old DMG if exists
rm -f "$DMG_PATH"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""

# ------------------------------------------------------------------
# [3/4] Verify DMG
# ------------------------------------------------------------------

echo -e "${GREEN}[3/4]${NC} Verifying DMG integrity..."
if hdiutil verify "$DMG_PATH" &>/dev/null; then
    echo -e "      ${GREEN}DMG verified successfully.${NC}"
else
    echo -e "      ${RED}[error]${NC} DMG verification failed."
    exit 1
fi
echo ""

# ------------------------------------------------------------------
# [4/4] Summary
# ------------------------------------------------------------------

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)

echo -e "${GREEN}=== DMG Summary ===${NC}"
echo -e "  DMG:    $DMG_PATH"
echo -e "  Size:   $DMG_SIZE"
echo -e "  Volume: $VOLUME_NAME"
echo ""
echo -e "${GREEN}Done!${NC} DMG is ready for distribution."
echo ""
echo "To mount and inspect:"
echo "  hdiutil attach \"$DMG_PATH\""
