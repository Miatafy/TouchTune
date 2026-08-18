#!/bin/sh
# TouchTune — install-patches.sh
#
# Applies every patch under patches/ to this Mazda CMU, backing up each factory file
# (and nvram value) first. With no arguments, the on-car dialog chooses install or
# uninstall. Runs automatically off the USB stick; flags are for off-target/SSH use.
# No warranty — see README and LICENSE.

REPO_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$REPO_DIR"

# Test mode (set by the Docker CMU test harness) skips the operations that can't run in
# a container: the double-execution guard, the / remount, the USB-log redirect, popups,
# and the final reboot. There is no production override — the real install never sets it.
MZD_TEST_MODE="${MZD_TEST_MODE:-0}"

. "$REPO_DIR/lib/touchtune-helpers.sh"

usage() {
    echo "install-patches.sh — apply TouchTune patches to this Mazda CMU"
    echo
    echo "With no arguments on the CMU, prompts to install, repair, or remove TouchTune."
    echo
    echo "Usage:"
    echo "  install-patches.sh                 prompt on-CMU; apply every patch off-target"
    echo "  install-patches.sh ID [ID...]      apply specific patch ids"
    echo "  install-patches.sh --restore       restore factory state (files + nvram)"
    echo "  install-patches.sh --list          list available patch ids"
    echo "  install-patches.sh --help          this help"
}

# Resolve a patch id (e.g. touch-while-driving) to its script path under patches/.
resolve_patch() {
    [ -f "patches/$1.sh" ] && { echo "patches/$1.sh"; return 0; }
    return 1
}

# Every patch id under patches/ (sorted, so a NN- prefix orders the apply, e.g.
# 01-foo, 02-bar). Patches live directly in patches/ — no subfolders. Pure glob +
# parameter expansion: no find/sed, so it runs on the CMU's busybox (1.19.2, which
# lacks `sed -E`).
list_all_patches() {
    [ -d patches ] || return 0
    for f in patches/*.sh; do
        [ -f "$f" ] || continue   # unmatched glob stays literal — skip it
        f=${f##*/}                # strip the patches/ prefix
        printf '%s\n' "${f%.sh}"  # strip the .sh suffix
    done | sort
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    -l|--list)
        list_all_patches
        exit 0
        ;;
    -r|--restore)
        if [ -d /jci ]; then
            [ "$MZD_TEST_MODE" = "1" ] || mount -o rw,remount / 2>/dev/null
        fi
        mzd_popup "Restoring factory settings...\n\nDo not remove the USB or press any buttons."
        mzd_log "restoring factory state (file + nvram backups)"
        mzd_restore_all
        mzd_restore_nvram
        mzd_finalize
        mzd_log "done — restarting to load the restored state"
        mzd_popup "Factory settings restored.\n\nRemove the USB. Restarting..."
        mzd_reboot
        exit 0
        ;;
esac

# These write to CMU system paths — refuse off-target unless explicitly dry-running.
if [ ! -d /jci ] && [ "${TOUCHTUNE_ALLOW_OFFTARGET:-0}" != "1" ]; then
    echo "ERROR: /jci not found — this runs on the Mazda CMU via the USB installer, not on your computer." >&2
    echo "To dry-run off-target (no CMU present), set TOUCHTUNE_ALLOW_OFFTARGET=1." >&2
    exit 1
fi

# Refuse any firmware but the validated one, before touching anything.
if [ -d /jci ]; then
    mzd_require_firmware || exit 1
fi

if [ -d /jci ]; then
    # The reusable USB keeps its launcher. An atomic /tmp guard stops overlapping update
    # scanner launches from opening a second dialog or rerunning the payload.
    if [ "$MZD_TEST_MODE" != "1" ] && ! mkdir /tmp/touchtune-installer.guard 2>/dev/null; then
        mzd_log "another TouchTune installer is already running; exiting"
        exit 0
    fi
    if [ "$MZD_TEST_MODE" != "1" ]; then
        trap 'rmdir /tmp/touchtune-installer.guard 2>/dev/null || true' 0
    fi
fi

MZD_MODE=""

# The USB launcher passes no arguments. On-CMU that means a state-aware action dialog;
# off-target it retains the useful dry-run behavior of applying all public patches.
if [ "$#" -eq 0 ]; then
    if [ -d /jci ] || [ "$MZD_TEST_MODE" = "1" ]; then
        installed=0
        mzd_touchtune_installed && installed=1
        if ! MZD_MODE=$(mzd_choose_action "$installed"); then
            mzd_log "action selection failed; nothing was changed"
            exit 1
        fi
        if [ "$MZD_MODE" = "cancel" ]; then
            mzd_log "cancelled before system changes"
            exit 0
        fi
        if [ "$MZD_MODE" = "install" ]; then
            set -- $(list_all_patches)
            if [ "$#" -eq 0 ]; then
                mzd_log "ERROR: no TouchTune patches found on the USB; nothing was changed"
                mzd_popup "TouchTune files are incomplete.\n\nNothing was changed."
                exit 1
            fi
        fi
    else
        set -- $(list_all_patches)
    fi
fi

# Explicit patch ids are installs. An empty off-target patch set retains the legacy
# restore-only behavior; the normal USB uninstall path is the REMOVE choice above.
if [ -z "$MZD_MODE" ]; then
    if [ "$#" -eq 0 ]; then
        MZD_MODE="uninstall"
    else
        MZD_MODE="install"
    fi
fi
if [ "$MZD_MODE" = "uninstall" ]; then
    MZD_VERB="Uninstalling"
else
    MZD_VERB="Installing"
fi

if [ -d /jci ]; then
    mzd_popup "$MZD_VERB TouchTune...\n\nDo not remove the USB or press any buttons."
    # Remount USB rw for logging. Keep the launcher and update flag so this exact stick
    # can install, repair, or remove TouchTune again on a later insertion.
    mount -o rw,remount "$REPO_DIR" 2>/dev/null || true
    [ "$MZD_TEST_MODE" = "1" ] || exec >>"$REPO_DIR/touchtune.log" 2>&1
    mzd_log "=== install-patches.sh started ==="
    mzd_log "remounting / read-write"
    [ "$MZD_TEST_MODE" = "1" ] || mount -o rw,remount /
    # Disable the watchdog so a long apply can't trip a reboot.
    [ -e "/sys/class/gpio/Watchdog Disable/value" ] && \
        echo 1 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null || true
fi

# /data is a runtime symlink; make its target real before backing anything up.
mzd_ensure_data_dir
mzd_init

# Restore to factory first so each run starts clean and dropped patches revert.
if [ -d "$MZD_BACKUP_DIR" ]; then
    mzd_log "restoring factory state"
    mzd_restore_all
fi
mzd_restore_nvram

failures=0
applied=0
total=$#
for id in "$@"; do
    if ! script=$(resolve_patch "$id"); then
        mzd_log "SKIP: unknown patch '$id'"
        failures=$((failures + 1))
        continue
    fi
    applied=$((applied + 1))
    mzd_log "applying ($applied/$total): $id"
    # Run each patch in a subshell so one can't leak vars into (or abort) the next.
    if ( . "$script" ); then
        mzd_log "ok: $id"
    else
        mzd_log "FAILED: $id (exit $?)"
        failures=$((failures + 1))
    fi
done

if [ "$MZD_MODE" = "uninstall" ]; then
    mzd_log "finished: uninstall — factory state restored"
else
    mzd_log "finished: $applied applied, $failures failure(s)"
fi
# Return to a safe state: flush, re-enable watchdog, remount / read-only.
mzd_finalize
if [ "$failures" -eq 0 ]; then
    if [ "$MZD_MODE" = "uninstall" ]; then
        mzd_log "restarting to load factory state"
        mzd_popup "TouchTune uninstalled.\n\nRemove the USB."
    else
        mzd_log "restarting to load the changes"
        mzd_popup "TouchTune installed.\n\nRemove the USB."
    fi
    mzd_reboot
else
    # Stay in the safe state but don't reboot, so the error/log stays visible.
    mzd_log "finished with errors — not restarting; see touchtune.log on the USB"
    mzd_popup "TouchTune finished with $failures error(s).\n\nSee touchtune.log on the USB."
fi
[ "$failures" -eq 0 ]
