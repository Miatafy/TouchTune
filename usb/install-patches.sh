#!/bin/sh
# Install or remove TouchTune on Mazda Connect 74.00.324 and 74.00.324A.
# TouchTune has no warranty. See LICENSE, NOTICE, and SOURCE.txt on this USB.

REPO_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
cd "$REPO_DIR" || exit 1
MZD_TEST_MODE="${MZD_TEST_MODE:-0}"
TOUCHTUNE_LOG_ACTIVE=0
TOUCHTUNE_GUARD_CREATED=0
TOUCHTUNE_HELPER_LOADED=0
TOUCHTUNE_FINALIZE_NEEDED=0

# Used on both normal completion and catchable interruptions. Remove temporary
# files while root is writable, then restore the mount and watchdog.
touchtune_cleanup() {
    local failures=0
    if [ "$MZD_TRANSACTION_ACTIVE" = 1 ]; then
        rollback_touch_transaction || failures=1
    fi
    if [ -n "$MZD_COMMON_STAGE" ]; then
        if mzd_remove_stage_file "$MZD_COMMON_STAGE"; then MZD_COMMON_STAGE=; else failures=1; fi
    fi
    if [ -n "$MZD_BACKUP_STAGE" ]; then
        if mzd_discard_backup_stage "$MZD_BACKUP_STAGE"; then MZD_BACKUP_STAGE=; else failures=1; fi
    fi
    if [ "$TOUCHTUNE_FINALIZE_NEEDED" = 1 ]; then
        if mzd_finalize; then TOUCHTUNE_FINALIZE_NEEDED=0; else failures=1; fi
    fi
    return "$failures"
}

touchtune_exit() {
    status=$?
    # Finish catchable interruptions once; SIGKILL and power loss cannot run this.
    trap - 0
    trap '' HUP INT TERM
    if [ "$TOUCHTUNE_HELPER_LOADED" = 1 ]; then
        touchtune_cleanup || { [ "$status" -ne 0 ] || status=1; }
    fi
    [ "$TOUCHTUNE_LOG_ACTIVE" = 0 ] || sync 2>/dev/null || true
    [ "$TOUCHTUNE_GUARD_CREATED" = 0 ] || rmdir /tmp/touchtune-installer.guard 2>/dev/null || true
    exit "$status"
}
trap touchtune_exit 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

bootstrap_log() { printf '%s\n' "[touchtune] $1" >&2; }

bootstrap_popup() {
    [ "$MZD_TEST_MODE" = 1 ] && return 0
    [ -x /jci/tools/jci-dialog ] || return 0
    killall -q jci-dialog 2>/dev/null || true
    /jci/tools/jci-dialog --info --title="TouchTune" --text="$1" \
        --no-cancel >/dev/null 2>&1 &
}

bootstrap_sha256() {
    local command output value
    command=/usr/bin/openssl
    [ -x "$command" ] || command=$(command -v openssl 2>/dev/null || true)
    [ -n "$command" ] && [ -x "$command" ] || return 1
    output=$("$command" dgst -sha256 "$1" 2>/dev/null) || return 1
    value=${output##* }
    [ "${#value}" -eq 64 ] || return 1
    case "$value" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf '%s\n' "$value" | tr 'A-F' 'a-f'
}

bootstrap_verify_helper() {
    local manifest="$REPO_DIR/PAYLOAD.SHA256" helper="$REPO_DIR/lib/touchtune-helpers.sh"
    local digest rel extra expected='' count=0 actual
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] || return 1
    [ -f "$helper" ] && [ ! -L "$helper" ] && [ -r "$helper" ] || return 1
    while read -r digest rel extra; do
        [ "$rel" = lib/touchtune-helpers.sh ] || continue
        [ -z "$extra" ] || return 1
        expected=$digest
        count=$((count + 1))
    done < "$manifest"
    [ "$count" -eq 1 ] || return 1
    [ "${#expected}" -eq 64 ] || return 1
    case "$expected" in *[!0-9a-fA-F]*) return 1 ;; esac
    actual=$(bootstrap_sha256 "$helper") || return 1
    [ "$actual" = "$expected" ]
}

usage() {
    echo "install-patches.sh: install or remove TouchTune"
    echo
    echo "Usage:"
    echo "  install-patches.sh                  show the on-CMU action dialog"
    echo "  install-patches.sh touch-while-driving"
    echo "  install-patches.sh --restore"
    echo "  install-patches.sh --list"
    echo "  install-patches.sh --help"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -l|--list) echo touch-while-driving; exit 0 ;;
    -r|--restore)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        MZD_MODE=uninstall
        ;;
    '') MZD_MODE=choose ;;
    touch-while-driving)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        MZD_MODE=install
        ;;
    *)
        echo "ERROR: unknown TouchTune action or patch: $1" >&2
        usage >&2
        exit 2
        ;;
esac

if [ "$MZD_TEST_MODE" != "1" ]; then
    if [ ! -d /jci ]; then
        echo "ERROR: /jci not found; this installer runs on a Mazda CMU." >&2
        exit 1
    fi
    # Open the USB log before compatibility checks. Keep diagnostics on the
    # system console when the volume cannot be remounted or opened for writing.
    mount -o rw,remount "$REPO_DIR" 2>/dev/null || true
    if : >> "$REPO_DIR/touchtune.log" 2>/dev/null; then
        exec >> "$REPO_DIR/touchtune.log" 2>&1
        TOUCHTUNE_LOG_ACTIVE=1
    else
        bootstrap_log "WARNING: USB log is not writable; continuing with console logging"
    fi
fi

bootstrap_log "=== TouchTune installer started ==="

if ! bootstrap_verify_helper; then
    bootstrap_log "ERROR: TouchTune helper validation failed before execution"
    bootstrap_popup "TouchTune USB validation failed.\n\nNothing was changed.\nKeep the USB and review touchtune.log."
    exit 1
fi

. "$REPO_DIR/lib/touchtune-helpers.sh" || {
    bootstrap_log "ERROR: verified TouchTune helper could not be loaded"
    bootstrap_popup "TouchTune could not load its verified helper.\n\nNothing was changed.\nKeep the USB and review touchtune.log."
    exit 1
}

TOUCHTUNE_HELPER_LOADED=1
TOUCHTUNE_FINALIZE_NEEDED=1

if ! mzd_verify_payload "$REPO_DIR"; then
    mzd_popup "TouchTune USB validation failed.\n\nNothing was changed.\nKeep the USB and review touchtune.log."
    exit 1
fi

TOUCHTUNE_VERSION=$(tr -d '\r\n' < "$REPO_DIR/VERSION") || exit 1
case "$TOUCHTUNE_VERSION" in ''|*[!0-9A-Za-z.-]*) mzd_log "ERROR: invalid TouchTune version"; exit 1 ;; esac
mzd_log "TouchTune $TOUCHTUNE_VERSION"

if ! mzd_require_firmware; then
    exit 1
fi

if [ "$MZD_TEST_MODE" != "1" ]; then
    if ! mkdir /tmp/touchtune-installer.guard 2>/dev/null; then
        mzd_log "another TouchTune installer is already running; exiting"
        exit 0
    fi
    TOUCHTUNE_GUARD_CREATED=1
fi

if [ "$MZD_MODE" = choose ]; then
    installed=0
    mzd_touchtune_installed && installed=1
    if ! MZD_MODE=$(mzd_choose_action "$installed"); then
        mzd_log "ERROR: action dialog failed; nothing was changed"
        mzd_popup "TouchTune could not read your selection.\n\nNothing was changed.\nKeep the USB for touchtune.log."
        exit 1
    fi
fi

if [ "$MZD_MODE" = cancel ]; then
    mzd_log "cancelled before system changes"
    exit 0
fi

case "$MZD_MODE" in
    install) verb=Installing ;;
    uninstall) verb=Removing ;;
    *) mzd_log "ERROR: invalid action state"; exit 1 ;;
esac
mzd_popup "$verb TouchTune...\n\nDo not remove the USB or press any buttons."

patch_status=0
. "$REPO_DIR/patches/touch-while-driving.sh" || patch_status=$?

finalize_status=0
touchtune_cleanup || finalize_status=$?

if [ "$finalize_status" -ne 0 ]; then
    mzd_log "final safety checks failed; not restarting"
    mzd_popup "TouchTune could not verify the final CMU state.\n\nTouchTune will not restart the CMU.\nKeep the USB and review touchtune.log."
    exit "$finalize_status"
fi
if [ "$patch_status" -ne 0 ]; then
    mzd_log "installation transaction failed; not restarting"
    mzd_popup "TouchTune could not complete the requested change.\n\nTouchTune will not restart the CMU.\nKeep the USB and review touchtune.log."
    exit "$patch_status"
fi

if [ "$MZD_MODE" = uninstall ]; then
    mzd_log "TouchTune removal verified; requesting Mazda SafeReboot"
    mzd_popup "TouchTune was removed and verified.\n\nRemove the USB. Restarting..."
else
    mzd_log "TouchTune installation verified; requesting Mazda SafeReboot"
    mzd_popup "TouchTune was installed and verified.\n\nRemove the USB. Restarting..."
fi

if ! mzd_reboot; then
    mzd_popup "TouchTune finished, but the restart could not be requested.\n\nRestart Mazda Connect normally.\nKeep the USB for touchtune.log."
    exit 1
fi
exit 0
