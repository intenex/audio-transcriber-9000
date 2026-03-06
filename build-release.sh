#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
APP_NAME="Audio Transcriber 9000"
SCHEME="AudioTranscriber9000"
PROJECT="AudioTranscriber9000.xcodeproj"
BUILD_DIR="build"
DMG_NAME="AudioTranscriber9000"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[build]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Clean ────────────────────────────────────────────────────────────────────
log "Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ─── Build Release ────────────────────────────────────────────────────────────
log "Building release..."
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | tail -3

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Build failed — app not found at $APP_PATH${NC}"
    exit 1
fi

log "App built at: $APP_PATH"

# ─── Copy scripts into the app bundle ─────────────────────────────────────────
log "Bundling Python scripts..."
RESOURCES_DIR="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES_DIR/scripts"
cp scripts/transcribe.py "$RESOURCES_DIR/scripts/"
cp scripts/generate.py "$RESOURCES_DIR/scripts/"
cp scripts/requirements.txt "$RESOURCES_DIR/scripts/"

# ─── Create DMG ───────────────────────────────────────────────────────────────
log "Creating DMG..."

DMG_PATH="$BUILD_DIR/${DMG_NAME}.dmg"
DMG_TEMP="$BUILD_DIR/dmg_staging"

rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"
cp -R "$APP_PATH" "$DMG_TEMP/"

# Create a symlink to /Applications for drag-install
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH" 2>&1 | tail -2

rm -rf "$DMG_TEMP"

# ─── Done ─────────────────────────────────────────────────────────────────────
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Build complete!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}DMG:${NC}  $DMG_PATH ($DMG_SIZE)"
echo -e "  ${GREEN}App:${NC}  $APP_PATH"
echo ""
echo -e "${YELLOW}Distribution notes:${NC}"
echo "  This build is ad-hoc signed (not notarized)."
echo "  Recipients will need to right-click > Open the first time."
echo ""
echo "  For notarized distribution (no Gatekeeper warnings):"
echo "    1. Get an Apple Developer account (\$99/year)"
echo "    2. Set DEVELOPMENT_TEAM in project.yml"
echo "    3. Sign with: codesign --deep --force --sign 'Developer ID Application: <name>' '$APP_PATH'"
echo "    4. Notarize: xcrun notarytool submit '$DMG_PATH' --apple-id <email> --team-id <team>"
echo "    5. Staple: xcrun stapler staple '$DMG_PATH'"
echo ""
