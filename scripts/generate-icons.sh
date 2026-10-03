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
# Cross-platform: macOS and Linux use ImageMagick. Windows usually has no
# ImageMagick, and `convert.exe` there is the NTFS filesystem converter rather
# than ImageMagick, so on Windows this delegates to scripts/generate-icons.ps1,
# which resizes with System.Drawing and needs nothing installed. Both paths
# produce the same ten files and both verify the result.
#
# Run from the repository root:
#
#     bash scripts/generate-icons.sh
#
# The generated PNGs are committed, so a normal `xcodebuild` never needs ImageMagick
# — this script only has to run when the master icon changes.
# ============================================================================
set -euo pipefail

MASTER="RosettaStone/Resources/AppIcon.png"
OUTPUT="RosettaStone/Support/AppIcon.appiconset"

# --- Dispatch ---------------------------------------------------------------
# Windows (Git Bash / MSYS / Cygwin) goes to the PowerShell backend, which
# needs no third-party dependency. Everything else uses ImageMagick below.
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        PS_SCRIPT="$SCRIPT_DIR/generate-icons.ps1"

        if [ ! -f "$PS_SCRIPT" ]; then
            echo "Error: $PS_SCRIPT not found. Cannot fall back on Windows." >&2
            exit 1
        fi

        if command -v powershell.exe >/dev/null 2>&1; then
            POWERSHELL="powershell.exe"
        elif command -v powershell >/dev/null 2>&1; then
            POWERSHELL="powershell"
        else
            echo "Error: PowerShell not found on PATH. It ships with Windows and" >&2
            echo "       is required for the System.Drawing fallback." >&2
            exit 1
        fi

        exec "$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$PS_SCRIPT" "$@"
        ;;
esac

# --- Preflight --------------------------------------------------------------
# Fail loudly and specifically rather than emitting a confusing `convert` error,
# because there are three distinct ways to be in this state and each has a
# different fix.
if [ ! -f "$MASTER" ]; then
    echo "Error: $MASTER not found. Please push the master icon file." >&2
    exit 1
fi

# ImageMagick 7 ships `magick`; 6 and earlier ship `convert`. Prefer `magick`,
# but fall back to `convert`, which is still correct on the POSIX platforms.
if command -v magick >/dev/null 2>&1; then
    CONVERT="magick"
elif command -v convert >/dev/null 2>&1; then
    CONVERT="convert"
else
    echo "Error: ImageMagick not found. Install it with:" >&2
    echo "         brew install imagemagick        # macOS" >&2
    echo "         sudo apt install imagemagick    # Debian/Ubuntu" >&2
    echo "       Or run this from Git Bash on Windows, which needs no" >&2
    echo "       ImageMagick and uses the System.Drawing fallback instead." >&2
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
#
# The resize walks a ladder of halvings rather than jumping straight to the
# target. A single 1024->16 reduction averages ~64 source pixels into each
# output pixel, and no single-pass kernel represents that, so the thin white
# glyph bands alias into noise; each rung is a ~2x reduction, which every filter
# handles cleanly. The PowerShell backend uses the same ladder, which is what
# makes the ten outputs reproducible on either platform.
WORK_A="$(mktemp "${TMPDIR:-/tmp}/rs-icon-a-XXXXXX.png")"
WORK_B="$(mktemp "${TMPDIR:-/tmp}/rs-icon-b-XXXXXX.png")"
trap 'rm -f "$WORK_A" "$WORK_B"' EXIT

emit() {
    local size="$1"
    local out="$2"
    local rung=1024
    local prev="$MASTER"
    local cur="$WORK_A"
    local nxt="$WORK_B"

    # Step down the ladder until the next halving would undershoot the target.
    # Each rung reads the previous rung's file and writes the other buffer:
    # reading and writing one file in the same command truncates it before
    # ImageMagick has read it.
    while [ $((rung / 2)) -ge "$size" ] && [ "$rung" -gt 1 ]; do
        rung=$((rung / 2))
        "$CONVERT" "$prev" -background none -alpha set -strip \
            -resize "${rung}x${rung}" "$cur"
        if [ "$rung" -eq "$size" ]; then
            cp "$cur" "$out"
            return
        fi
        prev="$cur"
        cur="$nxt"
        nxt="$prev"
    done

    # Reached when the target is 1024 itself: the loop never ran, so the final
    # step still has to read the master rather than an untouched temp file.
    "$CONVERT" "$prev" -background none -alpha set -strip \
        -resize "${size}x${size}" "$out"
}

emit 16   "$OUTPUT/AppIcon-16.png"
emit 32   "$OUTPUT/AppIcon-16@2x.png"
emit 32   "$OUTPUT/AppIcon-32.png"
emit 64   "$OUTPUT/AppIcon-32@2x.png"
emit 128  "$OUTPUT/AppIcon-128.png"
emit 256  "$OUTPUT/AppIcon-128@2x.png"
emit 256  "$OUTPUT/AppIcon-256.png"
emit 512  "$OUTPUT/AppIcon-256@2x.png"
emit 512  "$OUTPUT/AppIcon-512.png"
emit 1024 "$OUTPUT/AppIcon-512@2x.png"

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