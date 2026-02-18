#!/bin/bash
# download_ffmpeg.sh — Downloads static ffmpeg + ffprobe binaries for macOS
#
# These are universal (arm64 + x86_64) static builds from evermeet.cx,
# a well-known trusted source for macOS ffmpeg binaries.
#
# Usage:
#   ./scripts/download_ffmpeg.sh
#
# The binaries are placed in ImmichVault/Resources/Binaries/ and will be
# included in the app bundle at build time via project.yml resource config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BINARIES_DIR="$PROJECT_ROOT/ImmichVault/Resources/Binaries"

# ffmpeg version to download (update as needed)
FFMPEG_VERSION="7.1"

# Evermeet.cx URLs for static macOS builds
FFMPEG_URL="https://evermeet.cx/ffmpeg/ffmpeg-${FFMPEG_VERSION}.zip"
FFPROBE_URL="https://evermeet.cx/ffmpeg/ffprobe-${FFMPEG_VERSION}.zip"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ImmichVault ffmpeg Downloader ===${NC}"
echo ""

# Create binaries directory
mkdir -p "$BINARIES_DIR"

# Temp directory for downloads
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Function to download and extract
download_binary() {
    local name="$1"
    local url="$2"
    local dest="$BINARIES_DIR/$name"

    if [ -f "$dest" ]; then
        echo -e "${YELLOW}[skip]${NC} $name already exists at $dest"
        echo "       Delete it first if you want to re-download."
        return 0
    fi

    echo -e "${GREEN}[download]${NC} Downloading $name from evermeet.cx..."
    local zip_file="$TEMP_DIR/${name}.zip"

    if ! curl -L --fail --progress-bar -o "$zip_file" "$url"; then
        echo -e "${RED}[error]${NC} Failed to download $name from $url"
        echo ""
        echo "If evermeet.cx is unavailable, you can manually place a static"
        echo "ffmpeg/ffprobe binary at: $dest"
        echo ""
        echo "Alternative sources:"
        echo "  - https://www.osxexperts.net/"
        echo "  - Build from source: brew install ffmpeg"
        echo "    Then copy: cp \$(which $name) $dest"
        return 1
    fi

    echo -e "${GREEN}[extract]${NC} Extracting $name..."
    unzip -o -q "$zip_file" -d "$TEMP_DIR"

    if [ ! -f "$TEMP_DIR/$name" ]; then
        echo -e "${RED}[error]${NC} Expected binary $name not found in archive"
        return 1
    fi

    mv "$TEMP_DIR/$name" "$dest"
    chmod +x "$dest"

    echo -e "${GREEN}[done]${NC} $name installed at $dest"
}

# Download both binaries
download_binary "ffmpeg" "$FFMPEG_URL"
echo ""
download_binary "ffprobe" "$FFPROBE_URL"

echo ""
echo -e "${GREEN}=== Verification ===${NC}"

# Verify the binaries work
if [ -f "$BINARIES_DIR/ffmpeg" ]; then
    FFMPEG_VER=$("$BINARIES_DIR/ffmpeg" -version 2>&1 | head -1 || echo "unknown")
    echo -e "ffmpeg:  ${GREEN}$FFMPEG_VER${NC}"
else
    echo -e "ffmpeg:  ${RED}NOT FOUND${NC}"
fi

if [ -f "$BINARIES_DIR/ffprobe" ]; then
    FFPROBE_VER=$("$BINARIES_DIR/ffprobe" -version 2>&1 | head -1 || echo "unknown")
    echo -e "ffprobe: ${GREEN}$FFPROBE_VER${NC}"
else
    echo -e "ffprobe: ${RED}NOT FOUND${NC}"
fi

echo ""
echo -e "${GREEN}=== File sizes ===${NC}"
if [ -f "$BINARIES_DIR/ffmpeg" ]; then
    FFMPEG_SIZE=$(du -h "$BINARIES_DIR/ffmpeg" | cut -f1)
    echo -e "ffmpeg:  $FFMPEG_SIZE"
fi
if [ -f "$BINARIES_DIR/ffprobe" ]; then
    FFPROBE_SIZE=$(du -h "$BINARIES_DIR/ffprobe" | cut -f1)
    echo -e "ffprobe: $FFPROBE_SIZE"
fi

echo ""
echo -e "${GREEN}Done!${NC} Binaries are ready for inclusion in the app bundle."
echo "Run 'xcodegen generate' to update the Xcode project."
