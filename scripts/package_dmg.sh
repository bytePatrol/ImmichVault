#!/bin/bash
# package_dmg.sh — Creates a styled ImmichVault.dmg for distribution
#
# Uses create-dmg (brew install create-dmg) for reliable styling.
#
# Produces a DMG with:
#   - Light background with a chevron arrow (drag to install)
#   - ImmichVault.app on the left, Applications symlink on the right
#   - Custom volume icon from the app logo
#
# Usage:
#   ./scripts/package_dmg.sh
#
# Prerequisites:
#   - Run build_release.sh first to produce dist/ImmichVault.app
#   - brew install create-dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_PATH="$DIST_DIR/ImmichVault.app"
DMG_PATH="$DIST_DIR/ImmichVault.dmg"
VOLUME_NAME="ImmichVault"
VOLUME_ICON="$SCRIPT_DIR/VolumeIcon.icns"
BG_IMAGE="$SCRIPT_DIR/dmg_background.png"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== ImmichVault DMG Packager ===${NC}"
echo ""

# ------------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------------

if ! command -v create-dmg &>/dev/null; then
    echo -e "${RED}[error]${NC} create-dmg not found."
    echo "       Install it with: brew install create-dmg"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}[error]${NC} ImmichVault.app not found at: $APP_PATH"
    echo "       Run './scripts/build_release.sh' first to build the app."
    exit 1
fi
echo -e "  App found: ${GREEN}$APP_PATH${NC}"

if [ ! -f "$VOLUME_ICON" ]; then
    echo -e "${YELLOW}[warn]${NC} Volume icon not found at: $VOLUME_ICON"
fi

if [ ! -f "$BG_IMAGE" ]; then
    echo -e "${YELLOW}[warn]${NC} Background image not found at: $BG_IMAGE"
fi
echo ""

# ------------------------------------------------------------------
# Prepare staging folder (create-dmg copies everything from source)
# ------------------------------------------------------------------

echo -e "${GREEN}[1/3]${NC} Preparing staging directory..."

STAGING=$(mktemp -d)
trap "rm -rf $STAGING" EXIT

cp -R "$APP_PATH" "$STAGING/ImmichVault.app"
echo -e "      Copied ImmichVault.app"
echo ""

# ------------------------------------------------------------------
# Remove any previous DMG
# ------------------------------------------------------------------

echo -e "${GREEN}[2/3]${NC} Creating styled DMG with create-dmg..."
rm -f "$DMG_PATH"

# ------------------------------------------------------------------
# Build the DMG with create-dmg
# ------------------------------------------------------------------

# Assemble create-dmg arguments
CREATE_DMG_ARGS=(
    --volname "$VOLUME_NAME"
    --window-pos 200 120
    --window-size 660 400
    --icon-size 128
    --icon "ImmichVault.app" 165 180
    --app-drop-link 495 180
    --hide-extension "ImmichVault.app"
    --no-internet-enable
    --format UDZO
)

# Add optional background
if [ -f "$BG_IMAGE" ]; then
    CREATE_DMG_ARGS+=(--background "$BG_IMAGE")
    echo -e "      Using background: $BG_IMAGE"
fi

# Add optional volume icon
if [ -f "$VOLUME_ICON" ]; then
    CREATE_DMG_ARGS+=(--volicon "$VOLUME_ICON")
    echo -e "      Using volume icon: $VOLUME_ICON"
fi

# Run create-dmg
create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$STAGING"

echo ""
echo -e "      ${GREEN}DMG created.${NC}"
echo ""

# ------------------------------------------------------------------
# Verify and summarize
# ------------------------------------------------------------------

echo -e "${GREEN}[3/3]${NC} Verifying DMG integrity..."
if hdiutil verify "$DMG_PATH" &>/dev/null; then
    echo -e "      ${GREEN}DMG verified successfully.${NC}"
else
    echo -e "      ${RED}[error]${NC} DMG verification failed."
    exit 1
fi
echo ""

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
