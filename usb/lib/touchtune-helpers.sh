#!/bin/sh
# TouchTune patch helpers — the functions every patch script calls (mzd_backup,
# mzd_backup_nvram, mzd_log, ...). install-patches.sh sources this, runs
# mzd_ensure_data_dir + mzd_init before applying patches, and mzd_finalize + mzd_reboot
# after. Paths like /jci and /data are head-unit paths.

# On-CMU runtime state. Path shared with paid ScreenTune so an upgrade reuses the same
# backups. Override before sourcing if needed.
TOUCHTUNE_DIR="${TOUCHTUNE_DIR:-/data/screentune}"
MZD_BACKUP_DIR="${MZD_BACKUP_DIR:-$TOUCHTUNE_DIR/backups/files}"
MZD_NVRAM_BACKUP_DIR="${MZD_NVRAM_BACKUP_DIR:-$TOUCHTUNE_DIR/backups/nvram}"
# Stock JCI helper scripts. Override for off-target testing.
MZD_JCI_SCRIPTS="${MZD_JCI_SCRIPTS:-/jci/scripts}"
# nv-config sysfs key/value store (persists across reboots). Override for off-target.
MZD_NVRAM_DIR="${MZD_NVRAM_DIR:-/sys/class/nvram/nv-config}"
# Only firmware these patches were validated on; the installer refuses any other.
MZD_SUPPORTED_BASE_FW="74.00.324"
MZD_SUPPORTED_FW="74.00.324A"
MZD_VERSION_INI="/jci/version.ini"

# mzd_log MESSAGE — print a tagged progress line.
mzd_log() { echo "[touchtune] $1"; }

# mzd_touchtune_installed — true when TouchTune's public patch marker is present.
# Using the patch's own marker keeps the standalone installer self-contained.
mzd_touchtune_installed() {
    local target="/jci/gui/common/js/Common.js"
    [ -r "$target" ] && grep -q 'MZD_TOUCH_WHILE_DRIVING' "$target"
}

# mzd_choose_action INSTALLED — echo install, uninstall, or cancel from a synchronous
# CMU dialog. Fresh units get a simple confirmation; installed units get the same
# repair/remove/cancel choice used by ScreenTune. Test mode accepts an action through
# TOUCHTUNE_TEST_ACTION and never opens a real dialog.
mzd_choose_action() {
    local installed="${1:-0}"
    local code

    if [ "${MZD_TEST_MODE:-0}" = "1" ]; then
        case "${TOUCHTUNE_TEST_ACTION:-install}" in
            install|uninstall|cancel) printf '%s\n' "${TOUCHTUNE_TEST_ACTION:-install}" ;;
            *) echo "ERROR: invalid TOUCHTUNE_TEST_ACTION" >&2; return 1 ;;
        esac
        return 0
    fi

    if [ ! -x /jci/tools/jci-dialog ]; then
        echo "ERROR: /jci/tools/jci-dialog not found; refusing to choose an action" >&2
        return 1
    fi

    killall -q jci-dialog 2>/dev/null || true
    if [ "$installed" = "1" ]; then
        /jci/tools/jci-dialog \
            --3-button-dialog \
            --title="TOUCHTUNE" \
            --text="TouchTune is installed.\nChoose an action." \
            --ok-label="REPAIR" \
            --cancel-label="REMOVE" \
            --button3-label="CANCEL" \
            >/dev/null 2>&1
        code=$?
        case "$code" in
            0) echo install ;;
            1) echo uninstall ;;
            2) echo cancel ;;
            *) echo "ERROR: TouchTune action dialog failed with $code" >&2; return 1 ;;
        esac
    else
        /jci/tools/jci-dialog \
            --confirm \
            --title="TOUCHTUNE" \
            --text="Install TouchTune?" \
            --ok-label="INSTALL" \
            --cancel-label="CANCEL" \
            >/dev/null 2>&1
        code=$?
        case "$code" in
            0) echo install ;;
            1) echo cancel ;;
            *) echo "ERROR: TouchTune action dialog failed with $code" >&2; return 1 ;;
        esac
    fi
}

# mzd_popup TEXT — fullscreen dialog on the head unit (no-op off-CMU). Replaces any
# previous popup.
mzd_popup() {
    [ "${MZD_TEST_MODE:-0}" = "1" ] && return 0
    [ -x /jci/tools/jci-dialog ] || return 0
    killall -q jci-dialog 2>/dev/null || true
    /jci/tools/jci-dialog --info --title="TouchTune" --text="$1" --no-cancel \
        >/dev/null 2>&1 &
}

# mzd_current_firmware — echo the CMU firmware (e.g. 74.00.324A) from version.ini, or
# nothing if unreadable. Region/flavor text precedes the final underscore and is not
# part of the build number. Some regional files omit the patch field, and some tools
# include it in JCI_SW_VER, so avoid appending the same suffix twice.
mzd_current_firmware() {
    [ -r "$MZD_VERSION_INI" ] || return 0
    local ver patch
    ver=$(grep '^JCI_SW_VER=' "$MZD_VERSION_INI" | cut -d'"' -f2 | tr -d '\r' | tr 'a-z' 'A-Z')
    ver=${ver##*_}
    patch=$(grep '^JCI_SW_VER_PATCH=' "$MZD_VERSION_INI" | cut -d'"' -f2 | tr -d '\r' | tr 'a-z' 'A-Z')
    if [ -n "$ver" ] && [ -n "$patch" ]; then
        case "$ver" in
            *"$patch") ;;
            *) ver="${ver}${patch}" ;;
        esac
    fi
    [ -n "$ver" ] && printf '%s\n' "$ver"
}

# mzd_require_firmware — non-zero (and on-screen warning) unless on the supported fw.
mzd_require_firmware() {
    local fw
    fw=$(mzd_current_firmware)
    if [ -z "$fw" ]; then
        mzd_log "ERROR: cannot read firmware version from $MZD_VERSION_INI — refusing to run"
        mzd_popup "Could not read firmware version.\n\nTouchTune only runs on $MZD_SUPPORTED_FW.\nNothing was changed."
        return 1
    fi
    case "$fw" in
        "$MZD_SUPPORTED_BASE_FW"|"$MZD_SUPPORTED_FW") ;;
        *)
            mzd_log "ERROR: firmware $fw is not supported — TouchTune targets $MZD_SUPPORTED_FW only"
            mzd_popup "Unsupported firmware.\n\nThis CMU is on $fw.\nTouchTune only supports $MZD_SUPPORTED_FW.\nNothing was changed."
            return 1
            ;;
    esac
    mzd_log "firmware $fw — supported"
    return 0
}

# mzd_init — create the backup tree TouchTune writes to. Call once before applying.
mzd_init() {
    mkdir -p "$MZD_BACKUP_DIR" "$MZD_NVRAM_BACKUP_DIR" 2>/dev/null || true
}

# mzd_ensure_data_dir — make the backup root real before backing up. /data is a runtime
# symlink (/data -> /mnt/data -> /tmp/mnt/data) and mkdir -p won't create a symlink's
# missing target, so pre-create it by name. No-op off-CMU.
mzd_ensure_data_dir() {
    [ -d /jci ] || return 0
    mkdir -p /tmp/mnt/data 2>/dev/null || true
    [ -e /data ] || ln -s /tmp/mnt/data /data 2>/dev/null || mkdir -p /data
}

# mzd_backup FILE — save the factory copy of FILE before its first edit, mirrored under
# $MZD_BACKUP_DIR. Never overwritten, so the factory version is always recoverable.
mzd_backup() {
    local src="$1"
    [ -f "$src" ] || return 0
    local dest="$MZD_BACKUP_DIR$src"
    [ -f "$dest" ] && return 0
    mkdir -p "$(dirname "$dest")"
    cp -p "$src" "$dest"
}

# mzd_backup_nvram KEY [FACTORY_VALUE] — nvram analogue of mzd_backup. Snapshot KEY's
# value before a patch changes it; taken once, never overwritten.
#   mzd_backup_nvram KEY                # snapshot the live value
#   mzd_backup_nvram KEY FACTORY_VALUE  # record a known factory value instead (so an
#                                       #   already-modified unit still reverts to factory)
mzd_backup_nvram() {
    local key="$1"
    local factory="$2"
    local src="$MZD_NVRAM_DIR/keys/$key"
    local dest="$MZD_NVRAM_BACKUP_DIR/$key"
    [ -f "$dest" ] && return 0
    mkdir -p "$MZD_NVRAM_BACKUP_DIR"
    if [ -n "$factory" ]; then
        printf '%s\n' "$factory" > "$dest"
        return 0
    fi
    [ -r "$src" ] || { mzd_log "WARN: nvram key '$key' not readable; not backed up"; return 0; }
    cat "$src" > "$dest"
}

# mzd_restore_all — copy every backed-up file back over its original. nvram is handled
# separately by mzd_restore_nvram.
mzd_restore_all() {
    [ -d "$MZD_BACKUP_DIR" ] || { mzd_log "no file backups at $MZD_BACKUP_DIR"; return 0; }
    find "$MZD_BACKUP_DIR" -type f | while read -r bak; do
        orig="${bak#$MZD_BACKUP_DIR}"
        cp -p "$bak" "$orig"
    done
    mzd_log "factory restore complete"
}

# mzd_restore_nvram — write every snapshotted nv-config key back via add/key/commit
# (the sequence the stock set_*_config.sh scripts use). No-op for keys never backed up.
mzd_restore_nvram() {
    [ -d "$MZD_NVRAM_BACKUP_DIR" ] || return 0
    local bak key val
    for bak in "$MZD_NVRAM_BACKUP_DIR"/*; do
        [ -f "$bak" ] || continue
        key=$(basename "$bak")
        val=$(cat "$bak")
        if [ ! -w "$MZD_NVRAM_DIR/add" ]; then
            mzd_log "WARN: nvram not writable; cannot restore '$key'"
            continue
        fi
        printf '%s=%s\n' "$key" "$val" > "$MZD_NVRAM_DIR/add"
        printf '%s\n' "$val" > "$MZD_NVRAM_DIR/keys/$key"
        printf '\n' > "$MZD_NVRAM_DIR/commit"
        mzd_log "nvram restored: $key=$val"
    done
}

# mzd_finalize — safe state after an apply/restore: flush, re-enable the watchdog,
# remount / read-only. Does not reboot. No-op off-CMU.
mzd_finalize() {
    [ -d /jci ] || return 0
    sync
    mzd_log "re-enabling watchdog"
    [ -e "/sys/class/gpio/Watchdog Disable/value" ] && \
        echo 0 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null || true
    mzd_log "remounting / read-only"
    [ "${MZD_TEST_MODE:-0}" = "1" ] || mount -o ro,remount / 2>/dev/null || true
    sync
}

# mzd_reboot — final popup + restart so changes take effect. No-op off-CMU.
mzd_reboot() {
    [ -d /jci ] || return 0
    [ "${MZD_TEST_MODE:-0}" = "1" ] && { mzd_log "test mode: skipping reboot"; return 0; }
    mzd_popup "Restarting..."
    mzd_log "rebooting the head unit"
    sleep 2
    reboot
}
