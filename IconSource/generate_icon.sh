#!/bin/bash
# Drop your 1024x1024 PNG icon in this folder as "icon.png", then run this script.
# It generates all required sizes and copies them into the asset catalog.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/icon.png"
DEST="$SCRIPT_DIR/../Executer/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SRC" ]; then
    echo "ERROR: Place your 1024x1024 icon as 'icon.png' in this folder first."
    echo "  Path: $SCRIPT_DIR/icon.png"
    exit 1
fi

echo "Generating icon sizes from $SRC..."

for size in 16 32 64 128 256 512 1024; do
    sips -z $size $size "$SRC" --out "$DEST/icon_${size}x${size}.png" > /dev/null 2>&1
    echo "  ${size}x${size} done"
done

echo ""
echo "All sizes generated in:"
echo "  $DEST"
echo ""
echo "Now rebuild the app (Cmd+B in Xcode or run xcodebuild)."
