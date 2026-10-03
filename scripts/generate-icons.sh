#!/bin/bash
# ============================================================================
# Generate every macOS app-icon size from the 1024×1024 master.
#
#   master  RosettaStone/Resources/AppIcon.png        (1024×1024, committed by hand)
#   output  RosettaStone/Support/AppIcon.appiconset/ (10 PNGs + the Contents.json
#                                                       that is also committed)
#
# Why this is a script and not checked-in binaries:
#   * The master is the single source of truth. Re-running this after a design tweak
#     regenerates every size at once, so the icon set can never be half-updated.
#   * Ten PNGs is exactly the file set `actool` requires for a macOS app icon; the
#     mapping is mechanical and reviewable, which a binary blob is not.
#
# Requires ImageMagick (`brew install imagemagick`). Run from the repository root:
#
#     bash scripts/generate-icons.sh
#
# The generated PNGs are committed, so a normal `xcodebuild` never needs ImageMagick
# — this script only has to run when the master icon changes.
# ============================================================================
set -euo pipefail

MASTER="RosettaStone/Resources/AppIcon.png"
OUTPUT="RosettaStone/Support/AppIcon.appiconset"

# --- Preflight --------------------------------------------------------------
# Fail loudly and specifically rather than emitting a confusing `convert` error,
# because there are three distinct ways to be in this state and each has a
# different fix.
if [ ! -f "$MASTER" ]; then
    echo "Error: $MASTER not found. Please push the master icon file." >&2
    exit 1
fi

if ! command -v convert >/dev/null 2>&1; then
    echo "Error: ImageMagick's 'convert' is not on PATH. Install it with:" >&2
    echo "         brew install imagemagick" >&2
    exit 1
fi

if [ ! -d "$OUTPUT" ]; then
    echo "Error: $OUTPUT not found. The appiconset folder must exist." >&2
    exit 1
fi

# --- Generate ---------------------------------------------------------------
# `-background none -alpha set` keeps the master's transparency. Dropping it here
# would flatten the alpha channel against black and leave a dark box around the
# glyph in every size — the exact defect that only shows up on a light wallpaper.
#
# `-strip` drops the metadata so the outputs are byte-stable across runs on
# different machines, which keeps `git status` clean when nothing actually changed.
convert "$MASTER" -background none -alpha set -strip -resize 16x16   "$OUTPUT/AppIcon-16.png"
convert "$MASTER" -background none -alpha set -strip -resize 32x32   "$OUTPUT/AppIcon-16@2x.png"
convert "$MASTER" -background none -alpha set -strip -resize 32x32   "$OUTPUT/AppIcon-32.png"
convert "$MASTER" -background none -alpha set -strip -resize 64x64   "$OUTPUT/AppIcon-32@2x.png"
convert "$MASTER" -background none -alpha set -strip -resize 128x128 "$OUTPUT/AppIcon-128.png"
convert "$MASTER" -background none -alpha set -strip -resize 256x256 "$OUTPUT/AppIcon-128@2x.png"
convert "$MASTER" -background none -alpha set -strip -resize 256x256 "$OUTPUT/AppIcon-256.png"
convert "$MASTER" -background none -alpha set -strip -resize 512x512 "$OUTPUT/AppIcon-256@2x.png"
convert "$MASTER" -background none -alpha set -strip -resize 512x512 "$OUTPUT/AppIcon-512.png"
convert "$MASTER" -background none -alpha set -strip -resize 1024x1024 "$OUTPUT/AppIcon-512@2x.png"

echo "Generated all icon sizes in $OUTPUT"

# --- Verify -----------------------------------------------------------------
# Every file the committed Contents.json references must now exist. A missing one
# is an `actool` error at build time, so it is far cheaper to catch it here and
# name the file that is absent.
MISSING=0
for f in AppIcon-16.png AppIcon-16@2x.png AppIcon-32.png AppIcon-32@2x.png \
         AppIcon-128.png AppIcon-128@2x.png AppIcon-256.png AppIcon-256@2x.png \
         AppIcon-512.png AppIcon-512@2x.png; do
    if [ ! -s "$OUTPUT/$f" ]; then
        echo "Error: $OUTPUT/$f is missing or empty." >&2
        MISSING=1
    fi
done

if [ "$MISSING" -ne 0 ]; then
    exit 1
fi

echo "Verified: all 10 icon files present."