#!/bin/bash
# build_release.sh — Builds ImmichVault.app in Release configuration
#
# Generates the Xcode project via xcodegen, resolves SPM dependencies,
# builds a Release configuration, and copies the .app to dist/.
#
# Usage:
#   ./scripts/build_release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
BUILD_DIR="$PROJECT_ROOT/build"
BINARIES_DIR="$PROJECT_ROOT/ImmichVault/Resources/Binaries"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ImmichVault Release Build ===${NC}"
echo ""

# ------------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------------

echo -e "${GREEN}Checking prerequisites...${NC}"

if ! command -v xcodegen &>/dev/null; then
    echo -e "${RED}[error]${NC} xcodegen is not installed."
    echo "       Install with: brew install xcodegen"
    exit 1
fi
echo -e "  xcodegen: ${GREEN}found${NC}"

if ! command -v xcodebuild &>/dev/null; then
    echo -e "${RED}[error]${NC} xcodebuild is not installed."
    echo "       Install Xcode from the App Store or: xcode-select --install"
    exit 1
fi
echo -e "  xcodebuild: ${GREEN}found${NC}"

# Check for ffmpeg/ffprobe binaries
if [ ! -f "$BINARIES_DIR/ffmpeg" ] || [ ! -f "$BINARIES_DIR/ffprobe" ]; then
    echo -e "${YELLOW}[warn]${NC} ffmpeg/ffprobe binaries not found in $BINARIES_DIR"
    echo -e "       Running download_ffmpeg.sh automatically..."
    echo ""
    "$SCRIPT_DIR/download_ffmpeg.sh"
    echo ""
    # Verify they exist now
    if [ ! -f "$BINARIES_DIR/ffmpeg" ] || [ ! -f "$BINARIES_DIR/ffprobe" ]; then
        echo -e "${RED}[error]${NC} ffmpeg/ffprobe still missing after download attempt."
        echo "       Please place binaries manually in: $BINARIES_DIR"
        exit 1
    fi
fi
echo -e "  ffmpeg:     ${GREEN}found${NC}"
echo -e "  ffprobe:    ${GREEN}found${NC}"
echo ""

# ------------------------------------------------------------------
# [1/5] Generate Xcode project
# ------------------------------------------------------------------

echo -e "${GREEN}[1/5]${NC} Generating Xcode project..."
cd "$PROJECT_ROOT"
xcodegen generate
echo -e "      ${GREEN}Done.${NC}"
echo ""

# ------------------------------------------------------------------
# [2/5] Resolve SPM dependencies
# ------------------------------------------------------------------

echo -e "${GREEN}[2/5]${NC} Resolving Swift Package Manager dependencies..."
xcodebuild -resolvePackageDependencies \
    -project ImmichVault.xcodeproj \
    -scheme ImmichVault \
    -quiet
echo -e "      ${GREEN}Done.${NC}"
echo ""

# ------------------------------------------------------------------
# [3/5] Build Release
# ------------------------------------------------------------------

echo -e "${GREEN}[3/5]${NC} Building Release configuration..."
xcodebuild \
    -project ImmichVault.xcodeproj \
    -scheme ImmichVault \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    ONLY_ACTIVE_ARCH=NO \
    -quiet
echo -e "      ${GREEN}Done.${NC}"
echo ""

# ------------------------------------------------------------------
# Locate built .app
# ------------------------------------------------------------------

APP_PATH=$(find "$BUILD_DIR/Build/Products/Release" -name "ImmichVault.app" -maxdepth 1 -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}[error]${NC} ImmichVault.app not found in build products."
    echo "       Expected at: $BUILD_DIR/Build/Products/Release/ImmichVault.app"
    echo "       Check xcodebuild output above for build errors."
    exit 1
fi

echo -e "  Built app: ${GREEN}$APP_PATH${NC}"
echo ""

# ------------------------------------------------------------------
# [4/5] Verify code signature
# ------------------------------------------------------------------

echo -e "${GREEN}[4/5]${NC} Verifying code signature..."
if codesign --verify --deep --strict "$APP_PATH" 2>&1; then
    echo -e "      ${GREEN}Code signature valid.${NC}"
else
    echo -e "      ${YELLOW}[warn]${NC} Code signature verification had issues (ad-hoc signing is expected)."
    echo "       The app will still run locally but may trigger Gatekeeper warnings."
fi
echo ""

# ------------------------------------------------------------------
# [5/5] Copy to dist/
# ------------------------------------------------------------------

echo -e "${GREEN}[5/5]${NC} Copying to dist/..."
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/ImmichVault.app"
cp -R "$APP_PATH" "$DIST_DIR/ImmichVault.app"
echo -e "      ${GREEN}Done.${NC}"
echo ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------

APP_SIZE=$(du -sh "$DIST_DIR/ImmichVault.app" | cut -f1)

echo -e "${GREEN}=== Build Summary ===${NC}"
echo -e "  App:  $DIST_DIR/ImmichVault.app"
echo -e "  Size: $APP_SIZE"
echo ""
echo -e "${GREEN}Done!${NC} Release build is ready at dist/ImmichVault.app"
echo "Run './scripts/package_dmg.sh' to create a distributable DMG."
