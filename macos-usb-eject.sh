#!/bin/sh
# macos-usb-eject.sh — clean macOS cruft off the TouchTune USB and eject it (macOS).
#
# Finds the stick by its jci-autoupdate flag, deletes the dotfiles macOS writes to
# FAT32 volumes (.DS_Store, ._* AppleDouble files, .Spotlight-V100, .Trashes,
# .fseventsd, ...), then ejects. The ._* cleanup matters: a stray "._<launcher>.up"
# sidecar can make the CMU skip the update. Run after copying usb/ to the stick.
#
# Usage: ./macos-usb-eject.sh [/Volumes/NAME]   (auto-detects if no volume given)

set -eu

FLAG="jci-autoupdate"

if [ "$(uname)" != "Darwin" ]; then
    echo "This helper is macOS-only (it uses /Volumes and diskutil)." >&2
    exit 1
fi

# Pick the volume: an explicit arg, else auto-detect by the flag file.
vol="${1:-}"
if [ -n "$vol" ]; then
    [ -f "$vol/$FLAG" ] || { echo "ERROR: $vol is not a TouchTune USB (no $FLAG)." >&2; exit 1; }
else
    found=
    for f in /Volumes/*/"$FLAG"; do
        [ -f "$f" ] || continue          # unmatched glob stays literal — skip it
        if [ -n "$found" ]; then
            echo "ERROR: more than one TouchTune USB is mounted — pass the one to eject:" >&2
            echo "  $found" >&2
            echo "  $(dirname "$f")" >&2
            exit 1
        fi
        found=$(dirname "$f")
    done
    [ -n "$found" ] || { echo "ERROR: no TouchTune USB found (no /Volumes/*/$FLAG). Is it mounted?" >&2; exit 1; }
    vol=$found
fi

echo "TouchTune USB: $vol"

echo "Cleaning macOS dotfiles..."
find "$vol" -name '.DS_Store' -type f -delete 2>/dev/null || true
find "$vol" -name '._*' -type f -delete 2>/dev/null || true
for junk in .Spotlight-V100 .Trashes .fseventsd .TemporaryItems .apdisk; do
    rm -rf "${vol:?}/$junk" 2>/dev/null || true
done

echo "Ejecting $vol..."
diskutil eject "$vol"
echo "Done — safe to remove the stick."
