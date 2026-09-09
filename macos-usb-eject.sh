#!/bin/sh
# Clean, verify, and eject a TouchTune USB on macOS.
#
# Locate the volume by its TouchTune identity marker. Remove Finder metadata,
# verify the release files, and eject the volume. AppleDouble files named
# "._<launcher>.up" can prevent the CMU from detecting the update.
#
# Usage: ./macos-usb-eject.sh [/Volumes/NAME]
#        ./macos-usb-eject.sh --verify-only PATH

set -eu

FLAG=TOUCHTUNE.ID

hash_file() {
    command=/usr/bin/openssl
    [ -x "$command" ] || command=$(command -v openssl 2>/dev/null || true)
    [ -n "$command" ] && [ -x "$command" ] || return 1
    output=$("$command" dgst -sha256 "$1") || return 1
    printf '%s\n' "${output##* }"
}

regular_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }

verify_no_extra_patches() {
    volume="$1"
    # Old installers load every patch in this directory. Refuse leftovers here;
    # unrelated user files elsewhere do not affect the TouchTune payload.
    for path in "$volume"/patches/*.sh; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        relative=${path#"$volume"/}
        case "$relative" in
            patches/touch-while-driving.sh) ;;
            *) echo "ERROR: unexpected patch: $relative" >&2; return 1 ;;
        esac
    done
}

verify_volume() {
    volume="$1"
    manifest="$volume/PAYLOAD.SHA256"
    for directory in lib patches; do
        [ -d "$volume/$directory" ] && [ ! -L "$volume/$directory" ] || {
            echo "ERROR: invalid payload directory: $directory" >&2; return 1
        }
    done
    regular_file "$manifest" || { echo "ERROR: PAYLOAD.SHA256 is missing or invalid." >&2; return 1; }
    regular_file "$volume/LAUNCHER.NAME" || { echo "ERROR: LAUNCHER.NAME is missing or invalid." >&2; return 1; }
    launcher_name=$(tr -d '\r\n' < "$volume/LAUNCHER.NAME")
    launcher_lines=$(wc -l < "$volume/LAUNCHER.NAME" | tr -d '[:space:]')
    case "$launcher_name" in ''|*/*) echo "ERROR: LAUNCHER.NAME is invalid." >&2; return 1 ;; esac
    case "$launcher_name" in '$('*').up') ;; *) echo "ERROR: LAUNCHER.NAME is not a TouchTune launcher." >&2; return 1 ;; esac
    [ "$launcher_lines" = 1 ] || { echo "ERROR: LAUNCHER.NAME must contain one filename." >&2; return 1; }

    entries=0
    seen=' '
    while read -r expected relative extra; do
        [ -n "$expected" ] || continue
        [ -z "$extra" ] || { echo "ERROR: malformed PAYLOAD.SHA256." >&2; return 1; }
        case "$relative" in
            TOUCHTUNE.ID|VERSION|LAUNCHER.NAME|install-patches.sh|jci-autoupdate|lib/touchtune-helpers.sh|patches/touch-while-driving.sh)
                payload_path="$volume/$relative"
                ;;
            @launcher)
                payload_path="$volume/$launcher_name"
                ;;
            *) echo "ERROR: unexpected manifest entry: $relative" >&2; return 1 ;;
        esac
        case "$seen" in
            *" $relative "*) echo "ERROR: duplicate manifest entry: $relative" >&2; return 1 ;;
        esac
        seen="$seen$relative "
        regular_file "$payload_path" || { echo "ERROR: missing payload file: $relative" >&2; return 1; }
        actual=$(hash_file "$payload_path") || return 1
        [ "$actual" = "$expected" ] || { echo "ERROR: payload digest mismatch: $relative" >&2; return 1; }
        entries=$((entries + 1))
    done < "$manifest"
    [ "$entries" -eq 8 ] || { echo "ERROR: manifest must contain exactly eight entries." >&2; return 1; }

    [ "$(tr -d '\r\n' < "$volume/TOUCHTUNE.ID")" = touchtune-oss-v2 ] || {
        echo "ERROR: TouchTune media identity is invalid." >&2
        return 1
    }
    [ ! -s "$volume/jci-autoupdate" ] || { echo "ERROR: jci-autoupdate must be empty." >&2; return 1; }

    launchers=0
    for launcher in "$volume"/*.[uU][pP] "$volume"/.*.[uU][pP]; do
        [ -e "$launcher" ] || [ -L "$launcher" ] || continue
        launchers=$((launchers + 1))
        [ "${launcher##*/}" = "$launcher_name" ] || {
            echo "ERROR: undeclared launcher: ${launcher##*/}" >&2
            return 1
        }
    done
    [ "$launchers" -eq 1 ] || { echo "ERROR: expected one declared launcher; found $launchers." >&2; return 1; }
    verify_no_extra_patches "$volume" || return 1
    echo "TouchTune USB verified."
}

if [ "${1:-}" = --verify-only ]; then
    [ "$#" -eq 2 ] || { echo "Usage: $0 --verify-only PATH" >&2; exit 2; }
    verify_volume "$2"
    exit 0
fi

if [ "$(uname)" != Darwin ]; then
    echo "This helper runs on macOS. Use --verify-only PATH on other systems." >&2
    exit 1
fi

volume="${1:-}"
if [ -n "$volume" ]; then
    [ -f "$volume/$FLAG" ] || { echo "ERROR: $volume has no $FLAG." >&2; exit 1; }
else
    found=
    for marker in /Volumes/*/"$FLAG"; do
        [ -f "$marker" ] || continue          # Skip the literal path from an unmatched glob.
        if [ -n "$found" ]; then
            echo "ERROR: more than one TouchTune USB is mounted. Pass one volume path." >&2
            echo "  $found" >&2
            echo "  $(dirname "$marker")" >&2
            exit 1
        fi
        found=$(dirname "$marker")
    done
    [ -n "$found" ] || { echo "ERROR: no TouchTune USB is mounted." >&2; exit 1; }
    volume=$found
fi

echo "TouchTune USB: $volume"
echo "Cleaning macOS metadata..."
find "$volume" -name '.DS_Store' -type f -delete 2>/dev/null || true
find "$volume" -name '._*' -type f -delete 2>/dev/null || true
for junk in .Spotlight-V100 .Trashes .fseventsd .TemporaryItems .apdisk; do
    rm -rf "${volume:?}/$junk" 2>/dev/null || true
done

verify_volume "$volume"
echo "Ejecting $volume..."
diskutil eject "$volume"
echo "Ejected. You can remove the USB."
