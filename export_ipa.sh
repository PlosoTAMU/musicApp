#!/bin/bash
set -e

# ============================================================
#  export_ipa.sh
#  Run from the musicApp directory.
#  Finds the most recent Xcode archive, converts it to a
#  sideloadable IPA, and writes Pulsor.ipa next to this script.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_IPA="$SCRIPT_DIR/Pulsor.ipa"
ARCHIVES_ROOT="$HOME/Library/Developer/Xcode/Archives"
WORK_DIR="$(mktemp -d)"

echo "🔍 Searching for the most recent Xcode archive..."

# Find the most recently modified .xcarchive across all date folders
LATEST_ARCHIVE=$(find "$ARCHIVES_ROOT" -maxdepth 2 -name "*.xcarchive" -print0 \
    | xargs -0 ls -dt \
    | head -n 1)

if [ -z "$LATEST_ARCHIVE" ]; then
    echo "❌ No .xcarchive found under $ARCHIVES_ROOT"
    exit 1
fi

echo "📦 Using archive: $LATEST_ARCHIVE"

APP_SOURCE="$LATEST_ARCHIVE/Products/Applications/Pulsor.app"

if [ ! -d "$APP_SOURCE" ]; then
    echo "❌ Pulsor.app not found at expected path:"
    echo "   $APP_SOURCE"
    echo "   Available apps:"
    ls "$LATEST_ARCHIVE/Products/Applications/" 2>/dev/null || echo "   (directory not readable)"
    exit 1
fi

# ── Check dependencies ─────────────────────────────────────
if ! command -v ldid &>/dev/null; then
    echo "❌ ldid is not installed. Run:  brew install ldid"
    exit 1
fi

if ! command -v codesign &>/dev/null; then
    echo "❌ codesign not found (requires macOS with Xcode Command Line Tools)"
    exit 1
fi

# ── Step 1: Copy app to temp working directory ─────────────
WORK_APP="$WORK_DIR/Pulsor.app"
echo "📋 Copying Pulsor.app to temp directory..."
cp -r "$APP_SOURCE" "$WORK_APP"

# ── Step 2: Remove all existing signatures ─────────────────
echo "🔏 Removing existing code signatures..."
find "$WORK_APP" -name "_CodeSignature" -exec rm -rf {} \; 2>/dev/null || true
find "$WORK_APP" -name "embedded.mobileprovision" -delete 2>/dev/null || true
codesign --remove-signature "$WORK_APP" 2>/dev/null || true

APPEX="$WORK_APP/PlugIns/ShareToPulsor.appex"
if [ -d "$APPEX" ]; then
    codesign --remove-signature "$APPEX" 2>/dev/null || true
fi

# ── Step 3: Pre-sign with ldid (CRITICAL for SideStore) ────
echo "✍️  Pre-signing binaries with ldid..."

MAIN_BIN="$WORK_APP/Pulsor"
if [ ! -f "$MAIN_BIN" ]; then
    echo "❌ Main binary not found at $MAIN_BIN"
    exit 1
fi
ldid -S "$MAIN_BIN"
echo "   ✅ Signed: Pulsor"

APPEX_BIN="$APPEX/ShareToPulsor"
if [ -d "$APPEX" ]; then
    if [ ! -f "$APPEX_BIN" ]; then
        echo "❌ Extension binary not found at $APPEX_BIN"
        exit 1
    fi
    ldid -S "$APPEX_BIN"
    echo "   ✅ Signed: ShareToPulsor"
fi

# ── Step 4: Package into IPA ────────────────────────────────
echo "📦 Creating Payload and zipping IPA..."
PAYLOAD_DIR="$WORK_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -r "$WORK_APP" "$PAYLOAD_DIR/"

# Remove any existing output IPA
rm -f "$OUTPUT_IPA"

(cd "$WORK_DIR" && zip -ry "$OUTPUT_IPA" Payload)

# ── Cleanup ─────────────────────────────────────────────────
rm -rf "$WORK_DIR"

echo ""
echo "✅ Done! IPA exported to:"
echo "   $OUTPUT_IPA"
echo ""
echo "📱 Transfer to your iPhone and open in SideStore."
echo "   When prompted, select 'Keep app extensions (use main profile)'."
