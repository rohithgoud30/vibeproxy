#!/bin/bash

# Local release creation script.
# Builds the app and packages it in the same shape as upstream releases:
# per-arch DMG + ZIP, each with a matching .sha256, plus formatted release
# notes. This fork ships arm64 binaries (cli-proxy-api-plus, cloudflared),
# so only the arm64 artifacts are produced.

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=${1:-"dev"}
VERSION_NUM="${VERSION#v}"
# The bundle's CFBundleShortVersionString must be a clean numeric version, so
# strip any -rg30.<date>.<n> suffix; the full label lives on the tag/notes.
APP_VERSION_CLEAN="${VERSION_NUM%%-*}"
ARCH="arm64"
DIST_DIR="$PROJECT_DIR/dist"

echo -e "${BLUE}📦 Creating VibeProxy Release ${VERSION} (${ARCH})${NC}"
echo ""

cd "$PROJECT_DIR"
echo -e "${BLUE}🧹 Cleaning previous builds...${NC}"
rm -rf VibeProxy.app "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build the app (inject the clean base version into Info.plist)
echo -e "${BLUE}🔨 Building VibeProxy (app version ${APP_VERSION_CLEAN})...${NC}"
APP_VERSION="$APP_VERSION_CLEAN" ./create-app-bundle.sh

if [ ! -d "VibeProxy.app" ]; then
    echo -e "${RED}❌ Build failed - VibeProxy.app not found${NC}"
    exit 1
fi

ZIP_NAME="VibeProxy-${ARCH}.zip"
DMG_NAME="VibeProxy-${ARCH}.dmg"

# ZIP (preserves code signature / resource forks)
echo -e "${BLUE}📦 Creating ZIP archive...${NC}"
ditto -c -k --sequesterRsrc --keepParent "VibeProxy.app" "$DIST_DIR/$ZIP_NAME"

# DMG with an Applications symlink for drag-to-install
echo -e "${BLUE}💿 Creating DMG...${NC}"
DMG_STAGE="$(mktemp -d)"
cp -R "VibeProxy.app" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "VibeProxy" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST_DIR/$DMG_NAME" >/dev/null
rm -rf "$DMG_STAGE"

# Checksums (filename-only, matching upstream's .sha256 sidecar files)
echo -e "${BLUE}🔐 Calculating checksums...${NC}"
( cd "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" | awk -v f="$ZIP_NAME" '{print $1"  "f}' > "$ZIP_NAME.sha256" )
( cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" | awk -v f="$DMG_NAME" '{print $1"  "f}' > "$DMG_NAME.sha256" )

# Release notes in the upstream layout
NOTES="$DIST_DIR/release-notes.md"
cat > "$NOTES" <<EOF
## VibeProxy ${VERSION_NUM} (Cursor Relay build)

Personal fork build with the built-in **Codex Proxy for Cursor** (authenticated public relay + bundled cloudflared). See [CURSOR_SETUP.md](https://github.com/rohithgoud30/vibeproxy/blob/main/CURSOR_SETUP.md).

### Downloads

| Architecture | DMG | ZIP |
|--------------|-----|-----|
| **Apple Silicon** (M1/M2/M3) | \`${DMG_NAME}\` | \`${ZIP_NAME}\` |

> Intel (x86_64) is not built — the bundled proxy and tunnel binaries are arm64-only.

### Installation

1. Download \`${DMG_NAME}\` (or \`${ZIP_NAME}\`)
2. For DMG: mount and drag VibeProxy to Applications
3. For ZIP: extract and drag VibeProxy to Applications
4. First launch: right-click → Open (this build is ad-hoc signed, not notarized)

### What's New

- Built-in **Codex Proxy for Cursor**: API-key-authenticated relay exposed via a Cloudflare quick tunnel, so Cursor can reach VibeProxy.
- \`cloudflared\` bundled in the app — no install required.
- \`-extra\` model aliases (e.g. \`gpt-5.5-extra\`) force maximum reasoning effort.
EOF

echo ""
echo -e "${GREEN}✅ Release artifacts created in dist/:${NC}"
( cd "$DIST_DIR" && ls -lh )
echo ""
echo -e "${YELLOW}Publish to your fork:${NC}"
echo "  gh release create ${VERSION} \\"
echo "    --repo rohithgoud30/vibeproxy \\"
echo "    --title \"${VERSION}\" \\"
echo "    --notes-file dist/release-notes.md \\"
echo "    dist/${DMG_NAME} dist/${DMG_NAME}.sha256 dist/${ZIP_NAME} dist/${ZIP_NAME}.sha256"
echo ""
