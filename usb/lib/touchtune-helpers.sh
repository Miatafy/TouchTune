#!/bin/sh
# Provide safety helpers for the TouchTune installer.
#
# Support the BusyBox ash shell and commands included with the target firmware.
# Stage each boot-critical write beside its destination. Validate the candidate,
# rename it atomically, then validate the published file.

MZD_TEST_MODE="${MZD_TEST_MODE:-0}"
MZD_ROOT="${MZD_ROOT:-}"
TOUCHTUNE_DIR="${TOUCHTUNE_DIR:-$MZD_ROOT/data/touchtune}"
MZD_BACKUP_ROOT="${MZD_BACKUP_ROOT:-$TOUCHTUNE_DIR/backups}"
MZD_COMMON_BACKUP_DIR="$MZD_BACKUP_ROOT/common-js"
MZD_COMMON_BACKUP_FILE="$MZD_COMMON_BACKUP_DIR/Common.js"
MZD_COMMON_BACKUP_META="$MZD_COMMON_BACKUP_DIR/metadata"
MZD_COMMON_TARGET="${MZD_COMMON_TARGET:-$MZD_ROOT/jci/gui/common/js/Common.js}"
MZD_JCI_SCRIPTS="${MZD_JCI_SCRIPTS:-$MZD_ROOT/jci/scripts}"
MZD_NVRAM_DIR="${MZD_NVRAM_DIR:-$MZD_ROOT/sys/class/nvram/nv-config}"
MZD_VERSION_INI="${MZD_VERSION_INI:-$MZD_ROOT/jci/version.ini}"
MZD_MOUNTS_FILE="${MZD_MOUNTS_FILE:-$MZD_ROOT/proc/mounts}"
MZD_WATCHDOG_VALUE="${MZD_WATCHDOG_VALUE:-$MZD_ROOT/sys/class/gpio/Watchdog Disable/value}"
MZD_OPENSSL="${MZD_OPENSSL:-/usr/bin/openssl}"
[ -x "$MZD_OPENSSL" ] || MZD_OPENSSL=$(command -v openssl 2>/dev/null || true)
MZD_FSYNC="${MZD_FSYNC:-/bin/fsync}"
[ -x "$MZD_FSYNC" ] || MZD_FSYNC=$(command -v fsync 2>/dev/null || true)

MZD_SUPPORTED_BASE_FW="74.00.324"
MZD_SUPPORTED_FW="74.00.324A"
MZD_PROFILE_ID=""
MZD_PROFILE_STOCK_SHA256=""
MZD_PROFILE_PATCHED_SHA256=""
MZD_PROFILE_STOCK_BYTES=""
MZD_PROFILE_FILE_MODE=""
MZD_PROFILE_FILE_UID=""
MZD_PROFILE_FILE_GID=""
MZD_PROFILE_FACTORY_BUS="enable"
MZD_PROFILE_FACTORY_LVDS="enable"

MZD_ROOT_WRITABLE=0
MZD_WATCHDOG_DISABLED=0
MZD_COMMON_STAGE=
MZD_BACKUP_STAGE=
MZD_TRANSACTION_ACTIVE=0

mzd_log() { printf '%s\n' "[touchtune] $1" >&2; }

mzd_popup() {
    [ "$MZD_TEST_MODE" = "1" ] && return 0
    [ -x "$MZD_ROOT/jci/tools/jci-dialog" ] || return 0
    killall -q jci-dialog 2>/dev/null || true
    "$MZD_ROOT/jci/tools/jci-dialog" --info --title="TouchTune" --text="$1" \
        --no-cancel >/dev/null 2>&1 &
}

mzd_current_firmware() {
    [ -r "$MZD_VERSION_INI" ] || return 1
    local ver patch
    ver=$(grep '^JCI_SW_VER=' "$MZD_VERSION_INI" | cut -d'"' -f2 | tr -d '\r' | tr '[:lower:]' '[:upper:]') || return 1
    ver=${ver##*_}
    patch=$(grep '^JCI_SW_VER_PATCH=' "$MZD_VERSION_INI" | cut -d'"' -f2 | tr -d '\r' | tr '[:lower:]' '[:upper:]') || true
    if [ -n "$ver" ] && [ -n "$patch" ]; then
        case "$ver" in
            *"$patch") ;;
            *) ver="${ver}${patch}" ;;
        esac
    fi
    [ -n "$ver" ] || return 1
    printf '%s\n' "$ver"
}

# Select a content profile after validating the firmware. Tests may inject a
# fixture profile. Production accepts only the profiles listed below.
mzd_select_profile() {
    local fw="$1"
    case "$fw" in
        "$MZD_SUPPORTED_BASE_FW"|"$MZD_SUPPORTED_FW")
            MZD_PROFILE_ID="mazda-connect-74.00.324-common-v1"
            MZD_PROFILE_STOCK_SHA256="376b30a46366a543122956d7feb1b44f147425015837a4d83fedf12a67943351"
            MZD_PROFILE_PATCHED_SHA256="019eba18e8d629ddb1d55563aab138ce1eb3329fab67b71d9b4178377cf9d9ce"
            MZD_PROFILE_STOCK_BYTES="98348"
            MZD_PROFILE_FILE_MODE="775"
            MZD_PROFILE_FILE_UID="0"
            MZD_PROFILE_FILE_GID="0"
            ;;
        *) return 1 ;;
    esac

    if [ "$MZD_TEST_MODE" = "1" ] && [ -n "${TOUCHTUNE_TEST_STOCK_SHA256:-}" ]; then
        MZD_PROFILE_ID="test-common-v1"
        MZD_PROFILE_STOCK_SHA256="$TOUCHTUNE_TEST_STOCK_SHA256"
        MZD_PROFILE_PATCHED_SHA256="${TOUCHTUNE_TEST_PATCHED_SHA256:?}"
        MZD_PROFILE_STOCK_BYTES="${TOUCHTUNE_TEST_STOCK_BYTES:?}"
        MZD_PROFILE_FILE_MODE="${TOUCHTUNE_TEST_FILE_MODE:?}"
        MZD_PROFILE_FILE_UID="${TOUCHTUNE_TEST_FILE_UID:?}"
        MZD_PROFILE_FILE_GID="${TOUCHTUNE_TEST_FILE_GID:?}"
    fi
    return 0
}

mzd_require_firmware() {
    local fw
    if ! fw=$(mzd_current_firmware); then
        mzd_log "ERROR: cannot read firmware version from $MZD_VERSION_INI; refusing to run"
        mzd_popup "Could not read the firmware version.\n\nTouchTune supports $MZD_SUPPORTED_FW only.\nNothing was changed.\n\nKeep the USB for touchtune.log."
        return 1
    fi
    if ! mzd_select_profile "$fw"; then
        mzd_log "ERROR: firmware $fw is unsupported; TouchTune targets $MZD_SUPPORTED_FW only"
        mzd_popup "Unsupported firmware: $fw.\n\nTouchTune supports $MZD_SUPPORTED_FW only.\nNothing was changed.\n\nKeep the USB for touchtune.log."
        return 1
    fi
    mzd_log "firmware $fw; selected profile $MZD_PROFILE_ID"
}

mzd_sha256() {
    [ -n "$MZD_OPENSSL" ] && [ -x "$MZD_OPENSSL" ] || return 1
    local output digest length
    output=$("$MZD_OPENSSL" dgst -sha256 "$1" 2>/dev/null) || return 1
    digest=${output##* }
    length=${#digest}
    [ "$length" -eq 64 ] || return 1
    case "$digest" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf '%s\n' "$digest" | tr 'A-F' 'a-f'
}

mzd_bytes() {
    local raw count
    raw=$(wc -c < "$1") || return 1
    count=$(printf '%s' "$raw" | tr -d '[:space:]') || return 1
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$count"
}

mzd_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
mzd_uid() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null; }
mzd_gid() { stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1" 2>/dev/null; }

mzd_fsync_file() {
    if [ -n "$MZD_FSYNC" ] && [ -x "$MZD_FSYNC" ]; then
        "$MZD_FSYNC" "$1"
    elif [ "$MZD_TEST_MODE" = "1" ]; then
        return 0
    else
        mzd_log "ERROR: fsync is unavailable"
        return 1
    fi
}

mzd_fsync_dir() { mzd_fsync_file "$1"; }

mzd_require_regular_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }
mzd_require_real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }

mzd_make_real_dir() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        mzd_require_real_dir "$1" || {
            mzd_log "ERROR: managed path is not a real directory: $1"
            return 1
        }
        return 0
    fi
    mkdir "$1" || return 1
    mzd_fsync_dir "$(dirname "$1")"
}

mzd_ensure_data_dir() {
    [ "$MZD_TEST_MODE" = "1" ] && return 0
    mkdir -p /tmp/mnt/data || return 1
    if [ ! -e /data ] && [ ! -L /data ]; then
        ln -s /tmp/mnt/data /data || return 1
    fi
}

mzd_init_state() {
    mzd_ensure_data_dir || return 1
    local data_root
    data_root=$(dirname "$TOUCHTUNE_DIR")
    [ -d "$data_root" ] || { mzd_log "ERROR: data root is unavailable: $data_root"; return 1; }
    mzd_make_real_dir "$TOUCHTUNE_DIR" || return 1
    mzd_make_real_dir "$MZD_BACKUP_ROOT" || return 1
}

mzd_common_state() {
    local path="$1" digest
    mzd_require_regular_file "$path" || return 1
    digest=$(mzd_sha256 "$path") || return 1
    case "$digest" in
        "$MZD_PROFILE_STOCK_SHA256") printf '%s\n' stock ;;
        "$MZD_PROFILE_PATCHED_SHA256") printf '%s\n' patched ;;
        *) mzd_log "ERROR: unrecognized Common.js (sha256=$digest); refusing to modify it"; return 1 ;;
    esac
}

mzd_validate_common() { [ "$(mzd_common_state "$1")" = "$2" ]; }

mzd_validate_target_common() {
    local path="$1" wanted="$2"
    mzd_validate_common "$path" "$wanted" || return 1
    [ "$(mzd_mode "$path")" = "$MZD_PROFILE_FILE_MODE" ] || return 1
    [ "$(mzd_uid "$path")" = "$MZD_PROFILE_FILE_UID" ] || return 1
    [ "$(mzd_gid "$path")" = "$MZD_PROFILE_FILE_GID" ] || return 1
}

mzd_transform_common() {
    local source="$1" destination="$2" direction="$3"
    case "$direction" in
        install)
            awk '
                $0 == "        \"Global.AtSpeed\" : this._AtSpeedMsgHandler.bind(this)," {
                    print "        // MZD_TOUCH_WHILE_DRIVING \"Global.AtSpeed\" : this._AtSpeedMsgHandler.bind(this),"
                    next
                }
                { print }
            ' "$source" > "$destination"
            ;;
        uninstall)
            awk '
                $0 == "        // MZD_TOUCH_WHILE_DRIVING \"Global.AtSpeed\" : this._AtSpeedMsgHandler.bind(this)," {
                    print "        \"Global.AtSpeed\" : this._AtSpeedMsgHandler.bind(this),"
                    next
                }
                { print }
            ' "$source" > "$destination"
            ;;
        *) return 1 ;;
    esac
}

mzd_meta_value() {
    local key="$1" file="$2" count value
    count=$(grep -c "^${key}=" "$file" 2>/dev/null || true)
    [ "$count" = 1 ] || return 1
    value=$(grep "^${key}=" "$file") || return 1
    printf '%s\n' "${value#*=}"
}

# Accept the same complete backup-v3 bundle in staging and after publication.
# Keep this schema readable by earlier 1.2 builds; the digest identifies content.
mzd_validate_backup() {
    local dir="${1:-$MZD_COMMON_BACKUP_DIR}" meta format profile path digest bytes baseline bus lvds meta_digest meta_name meta_extra
    meta="$dir/metadata"
    mzd_require_real_dir "$dir" || return 1
    mzd_require_regular_file "$dir/Common.js" || return 1
    mzd_require_regular_file "$meta" || return 1
    mzd_require_regular_file "$dir/metadata.sha256" || return 1
    read -r meta_digest meta_name meta_extra < "$dir/metadata.sha256" || return 1
    [ "$meta_name" = metadata ] && [ -z "$meta_extra" ] || return 1
    [ "$(mzd_sha256 "$meta")" = "$meta_digest" ] || return 1
    format=$(mzd_meta_value format "$meta") || return 1
    profile=$(mzd_meta_value profile "$meta") || return 1
    path=$(mzd_meta_value path "$meta") || return 1
    digest=$(mzd_meta_value sha256 "$meta") || return 1
    bytes=$(mzd_meta_value bytes "$meta") || return 1
    baseline=$(mzd_meta_value nvram_baseline "$meta") || return 1
    bus=$(mzd_meta_value nvram_bus_bcm_speed_restriction "$meta") || return 1
    lvds=$(mzd_meta_value nvram_lvds_speed_restriction "$meta") || return 1
    [ "$format" = touchtune-backup-v3 ] && [ "$profile" = "$MZD_PROFILE_ID" ] || return 1
    [ "$path" = /jci/gui/common/js/Common.js ] || return 1
    [ "$digest" = "$MZD_PROFILE_STOCK_SHA256" ] && [ "$bytes" = "$MZD_PROFILE_STOCK_BYTES" ] || return 1
    case "$bus:$lvds" in enable:enable|enable:disable|disable:enable|disable:disable) ;; *) return 1 ;; esac
    case "$baseline" in
        entry) ;;
        factory-fallback)
            [ "$bus" = "$MZD_PROFILE_FACTORY_BUS" ] && [ "$lvds" = "$MZD_PROFILE_FACTORY_LVDS" ] || return 1
            ;;
        *) return 1 ;;
    esac
    [ "$(mzd_mode "$dir")" = 755 ] || return 1
    [ "$(mzd_mode "$dir/Common.js")" = 444 ] || return 1
    [ "$(mzd_mode "$meta")" = 444 ] || return 1
    [ "$(mzd_mode "$dir/metadata.sha256")" = 444 ] || return 1
    mzd_validate_common "$dir/Common.js" stock
}

mzd_fault() {
    [ "$MZD_TEST_MODE" = "1" ] || return 0
    [ "${TOUCHTUNE_FAULT:-}" = "$1" ] || return 0
    case "$1" in
        truncate-common-candidate) printf '%s\n' 'truncated candidate' > "$2" ;;
        corrupt-common-after-rename)
            printf '%s\n' 'corrupt readback' > "$2"
            TOUCHTUNE_FAULT=
            ;;
        interrupt-before-backup-rename|interrupt-before-common-rename|interrupt-after-common-rename)
            mzd_log "TEST: simulated interruption at $1"
            TOUCHTUNE_FAULT=
            exit 97
            ;;
        backup-write-failure|common-write-failure|common-fsync-failure) return 1 ;;
    esac
}

mzd_remove_stage_file() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    [ -f "$path" ] && [ ! -L "$path" ] || {
        mzd_log "ERROR: staging path is not a regular file: $path"
        return 1
    }
    chmod u+w "$path" 2>/dev/null || true
    rm -f "$path" || return 1
    [ ! -e "$path" ] && [ ! -L "$path" ]
}

mzd_discard_backup_stage() {
    local pending="$1"
    [ -e "$pending" ] || [ -L "$pending" ] || return 0
    mzd_require_real_dir "$pending" || {
        mzd_log "ERROR: backup staging path is not a real directory: $pending"
        return 1
    }
    chmod 0755 "$pending" 2>/dev/null || return 1
    mzd_remove_stage_file "$pending/Common.js" || return 1
    mzd_remove_stage_file "$pending/metadata" || return 1
    mzd_remove_stage_file "$pending/metadata.sha256" || return 1
    rmdir "$pending" || {
        mzd_log "ERROR: backup staging directory contains unexpected files: $pending"
        return 1
    }
}

mzd_populate_backup_stage() {
    local live_state="$1" bus="$2" lvds="$3" pending="$4" raw baseline meta_digest
    raw="$pending/Common.js"
    mzd_fault backup-write-failure "$pending" || return 1
    case "$live_state" in
        stock)
            baseline=entry
            cp -p "$MZD_COMMON_TARGET" "$raw" || return 1
            ;;
        patched)
            baseline=factory-fallback
            bus="$MZD_PROFILE_FACTORY_BUS"
            lvds="$MZD_PROFILE_FACTORY_LVDS"
            mzd_transform_common "$MZD_COMMON_TARGET" "$raw" uninstall || return 1
            ;;
        *) return 1 ;;
    esac
    mzd_validate_common "$raw" stock || {
        mzd_log "ERROR: reconstructed factory Common.js did not match the selected profile"
        return 1
    }
    cat > "$pending/metadata" <<EOF || return 1
format=touchtune-backup-v3
profile=$MZD_PROFILE_ID
path=/jci/gui/common/js/Common.js
sha256=$MZD_PROFILE_STOCK_SHA256
bytes=$MZD_PROFILE_STOCK_BYTES
nvram_baseline=$baseline
nvram_bus_bcm_speed_restriction=$bus
nvram_lvds_speed_restriction=$lvds
EOF
    meta_digest=$(mzd_sha256 "$pending/metadata") || return 1
    printf '%s  metadata\n' "$meta_digest" > "$pending/metadata.sha256" || return 1
    chmod 0444 "$raw" "$pending/metadata" "$pending/metadata.sha256" || return 1
    mzd_fsync_file "$raw" || return 1
    mzd_fsync_file "$pending/metadata" || return 1
    mzd_fsync_file "$pending/metadata.sha256" || return 1
    chmod 0755 "$pending" || return 1
    mzd_fsync_dir "$pending"
}

mzd_create_backup() {
    local live_state="$1" bus="$2" lvds="$3" parent pending
    parent="$MZD_BACKUP_ROOT"
    pending="$parent/.common-js.pending"
    mzd_discard_backup_stage "$pending" || return 1
    MZD_BACKUP_STAGE="$pending"
    mkdir "$pending" || return 1
    if ! mzd_populate_backup_stage "$live_state" "$bus" "$lvds" "$pending" || \
        ! mzd_validate_backup "$pending"; then
        mzd_log "ERROR: could not build the private backup"
        mzd_discard_backup_stage "$pending" || true
        return 1
    fi
    mzd_fault interrupt-before-backup-rename "$pending"
    [ ! -e "$MZD_COMMON_BACKUP_DIR" ] && [ ! -L "$MZD_COMMON_BACKUP_DIR" ] || {
        mzd_log "ERROR: backup appeared while it was being created; refusing to replace it"
        mzd_discard_backup_stage "$pending" || true
        return 1
    }
    if ! mv "$pending" "$MZD_COMMON_BACKUP_DIR"; then
        mzd_discard_backup_stage "$pending" || true
        return 1
    fi
    MZD_BACKUP_STAGE=
    mzd_fsync_dir "$MZD_COMMON_BACKUP_DIR" || return 1
    mzd_fsync_dir "$parent" || return 1
    mzd_validate_backup || {
        mzd_log "ERROR: published backup failed readback validation"
        return 1
    }
    mzd_log "created write-once TouchTune backup for profile $MZD_PROFILE_ID"
}

mzd_ensure_backup() {
    local live_state="$1" bus="$2" lvds="$3"
    if [ -e "$MZD_COMMON_BACKUP_DIR" ] || [ -L "$MZD_COMMON_BACKUP_DIR" ]; then
        if ! mzd_validate_backup; then
            mzd_log "ERROR: TouchTune backup is incomplete, corrupt, or belongs to another profile; refusing to continue"
            return 1
        fi
        mzd_log "validated existing write-once TouchTune backup"
        return 0
    fi
    mzd_create_backup "$live_state" "$bus" "$lvds"
}

mzd_backup_attr() { mzd_meta_value "$1" "$MZD_COMMON_BACKUP_META"; }

# Build the complete replacement from the verified factory backup. Stage it in
# the target directory so the final rename stays on the same filesystem.
mzd_stage_common() {
    local wanted="$1" parent candidate
    mzd_validate_backup || { mzd_log "ERROR: refusing replacement without a valid backup"; return 1; }
    parent=$(dirname "$MZD_COMMON_TARGET")
    candidate="$parent/.Common.js.touchtune.new"
    mzd_remove_stage_file "$candidate" || return 1
    # Discard the second temporary file used by earlier 1.2 installers.
    mzd_remove_stage_file "$parent/.Common.js.touchtune.work" || return 1
    MZD_COMMON_STAGE="$candidate"
    mzd_fault common-write-failure "$candidate" || return 1
    case "$wanted" in
        stock) cp "$MZD_COMMON_BACKUP_FILE" "$candidate" || return 1 ;;
        patched) mzd_transform_common "$MZD_COMMON_BACKUP_FILE" "$candidate" install || return 1 ;;
        *) return 1 ;;
    esac
    chmod "$MZD_PROFILE_FILE_MODE" "$candidate" || return 1
    chown "$MZD_PROFILE_FILE_UID:$MZD_PROFILE_FILE_GID" "$candidate" || return 1
    mzd_fault truncate-common-candidate "$candidate"
    if ! mzd_validate_target_common "$candidate" "$wanted"; then
        mzd_log "ERROR: staged Common.js failed exact content or permissions validation"
        return 1
    fi
    mzd_fault common-fsync-failure "$candidate" || return 1
    mzd_fsync_file "$candidate" || return 1
    sync
}

mzd_publish_common() {
    local wanted="$1" parent
    [ -n "$MZD_COMMON_STAGE" ] || return 1
    parent=$(dirname "$MZD_COMMON_TARGET")
    mzd_fault interrupt-before-common-rename "$MZD_COMMON_STAGE"
    mv -f "$MZD_COMMON_STAGE" "$MZD_COMMON_TARGET" || return 1
    MZD_COMMON_STAGE=
    mzd_fsync_dir "$parent" || return 1
    mzd_fault interrupt-after-common-rename "$MZD_COMMON_TARGET"
    mzd_fault corrupt-common-after-rename "$MZD_COMMON_TARGET"
    if ! mzd_validate_target_common "$MZD_COMMON_TARGET" "$wanted"; then
        mzd_log "ERROR: published Common.js failed readback validation"
        return 1
    fi
    mzd_log "published and read back exact $wanted Common.js"
}

mzd_read_nvram() {
    local key="$1" value
    [ -f "$MZD_NVRAM_DIR/keys/$key" ] && [ ! -L "$MZD_NVRAM_DIR/keys/$key" ] && \
        [ -r "$MZD_NVRAM_DIR/keys/$key" ] || return 1
    value=$(tr -d '\r\n' < "$MZD_NVRAM_DIR/keys/$key") || return 1
    case "$value" in enable|disable) printf '%s\n' "$value" ;; *) return 1 ;; esac
}

mzd_nvram_setter() {
    case "$1" in
        bus_bcm_speed_restriction) printf '%s\n' "$MZD_JCI_SCRIPTS/set_speed_restriction_config.sh" ;;
        lvds_speed_restriction) printf '%s\n' "$MZD_JCI_SCRIPTS/set_lvds_speed_restriction_config.sh" ;;
        *) return 1 ;;
    esac
}

mzd_require_nvram_setters() {
    local setter
    for setter in \
        "$MZD_JCI_SCRIPTS/set_speed_restriction_config.sh" \
        "$MZD_JCI_SCRIPTS/set_lvds_speed_restriction_config.sh"
    do
        [ -f "$setter" ] && [ ! -L "$setter" ] && [ -x "$setter" ] || {
            mzd_log "ERROR: required NVRAM setter is unavailable: $setter"
            return 1
        }
    done
}

mzd_set_nvram() {
    local key="$1" wanted="$2" setter actual
    case "$wanted" in enable|disable) ;; *) return 1 ;; esac
    actual=$(mzd_read_nvram "$key") || actual=
    [ "$actual" != "$wanted" ] || return 0
    setter=$(mzd_nvram_setter "$key") || return 1
    [ -x "$setter" ] || { mzd_log "ERROR: required NVRAM setter is missing: $setter"; return 1; }
    if ! "$setter" "$wanted"; then
        mzd_log "ERROR: NVRAM setter failed for $key=$wanted"
        return 1
    fi
    actual=$(mzd_read_nvram "$key") || {
        mzd_log "ERROR: could not read back NVRAM key $key"
        return 1
    }
    if [ "$actual" != "$wanted" ]; then
        mzd_log "ERROR: NVRAM readback mismatch for $key (wanted $wanted, got $actual)"
        return 1
    fi
    mzd_log "verified NVRAM $key=$wanted"
}

mzd_set_touch_nvram() {
    local bus="$1" lvds="$2"
    mzd_set_nvram bus_bcm_speed_restriction "$bus" || return 1
    mzd_set_nvram lvds_speed_restriction "$lvds" || return 1
}


mzd_touchtune_installed() {
    [ -n "$MZD_PROFILE_PATCHED_SHA256" ] || return 1
    mzd_validate_target_common "$MZD_COMMON_TARGET" patched
}

mzd_choose_action() {
    local installed="${1:-0}" code
    if [ "$MZD_TEST_MODE" = "1" ]; then
        case "${TOUCHTUNE_TEST_ACTION:-install}" in
            install|uninstall|cancel) printf '%s\n' "${TOUCHTUNE_TEST_ACTION:-install}" ;;
            *) return 1 ;;
        esac
        return 0
    fi
    [ -x "$MZD_ROOT/jci/tools/jci-dialog" ] || return 1
    killall -q jci-dialog 2>/dev/null || true
    if [ "$installed" = "1" ]; then
        "$MZD_ROOT/jci/tools/jci-dialog" --3-button-dialog --title="TOUCHTUNE" \
            --text="TouchTune is installed.\nChoose an action." --ok-label="REPAIR" \
            --cancel-label="REMOVE" --button3-label="CANCEL" >/dev/null 2>&1
        code=$?
        case "$code" in 0) echo install ;; 1) echo uninstall ;; 2) echo cancel ;; *) return 1 ;; esac
    else
        "$MZD_ROOT/jci/tools/jci-dialog" --confirm --title="TOUCHTUNE" \
            --text="Install TouchTune?" --ok-label="INSTALL" --cancel-label="CANCEL" \
            >/dev/null 2>&1
        code=$?
        case "$code" in 0) echo install ;; 1) echo cancel ;; *) return 1 ;; esac
    fi
}

mzd_read_launcher_name() {
    local file="$1/LAUNCHER.NAME" name lines raw_lines bytes
    mzd_require_regular_file "$file" || return 1
    name=$(tr -d '\r\n' < "$file") || return 1
    raw_lines=$(wc -l < "$file") || return 1
    lines=$(printf '%s' "$raw_lines" | tr -d '[:space:]') || return 1
    bytes=$(mzd_bytes "$file") || return 1
    [ "$lines" = 1 ] && [ "$bytes" -le 256 ] || return 1
    case "$name" in ''|*/*) return 1 ;; esac
    case "$name" in '$('*').up') ;; *) return 1 ;; esac
    printf '%s\n' "$name"
}

mzd_verify_payload() {
    local root="$1" manifest="$1/PAYLOAD.SHA256" line_count=0 digest rel extra actual actual_path patch_count launcher_count launcher_name seen=' '
    mzd_require_regular_file "$manifest" || { mzd_log "ERROR: PAYLOAD.SHA256 is missing"; return 1; }
    mzd_require_real_dir "$root/lib" && mzd_require_real_dir "$root/patches" || return 1
    launcher_name=$(mzd_read_launcher_name "$root") || { mzd_log "ERROR: LAUNCHER.NAME is invalid"; return 1; }
    while read -r digest rel extra; do
        [ -n "$digest" ] || continue
        [ -z "$extra" ] || { mzd_log "ERROR: malformed payload manifest"; return 1; }
        case "$rel" in
            TOUCHTUNE.ID|VERSION|LAUNCHER.NAME|install-patches.sh|jci-autoupdate|lib/touchtune-helpers.sh|patches/touch-while-driving.sh)
                actual_path="$root/$rel"
                ;;
            @launcher)
                actual_path="$root/$launcher_name"
                ;;
            *) mzd_log "ERROR: unexpected manifest entry: $rel"; return 1 ;;
        esac
        case "$seen" in
            *" $rel "*) mzd_log "ERROR: duplicate manifest entry: $rel"; return 1 ;;
        esac
        seen="$seen$rel "
        mzd_require_regular_file "$actual_path" || { mzd_log "ERROR: payload file missing: $rel"; return 1; }
        actual=$(mzd_sha256 "$actual_path") || { mzd_log "ERROR: cannot hash payload file: $rel"; return 1; }
        [ "$actual" = "$digest" ] || { mzd_log "ERROR: payload digest mismatch: $rel"; return 1; }
        line_count=$((line_count + 1))
    done < "$manifest"
    [ "$line_count" -eq 8 ] || { mzd_log "ERROR: payload manifest must contain exactly eight entries"; return 1; }
    patch_count=0
    for rel in "$root"/patches/*.sh; do
        [ -f "$rel" ] || continue
        patch_count=$((patch_count + 1))
        [ "${rel##*/}" = "touch-while-driving.sh" ] || {
            mzd_log "ERROR: unmanifested patch present: ${rel##*/}"
            return 1
        }
    done
    [ "$patch_count" -eq 1 ] || { mzd_log "ERROR: expected exactly one TouchTune patch"; return 1; }
    launcher_count=0
    for rel in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        case "$rel" in *.[uU][pP]) ;; *) continue ;; esac
        [ -e "$rel" ] || [ -L "$rel" ] || continue
        launcher_count=$((launcher_count + 1))
        [ "${rel##*/}" = "$launcher_name" ] || {
            mzd_log "ERROR: undeclared launcher present: ${rel##*/}"
            return 1
        }
    done
    [ "$launcher_count" -eq 1 ] || { mzd_log "ERROR: expected exactly one TouchTune launcher"; return 1; }
    [ "$(mzd_bytes "$root/jci-autoupdate")" = 0 ] || {
        mzd_log "ERROR: jci-autoupdate must be empty"
        return 1
    }
    [ "$(tr -d '\r\n' < "$root/TOUCHTUNE.ID")" = "touchtune-oss-v2" ] || {
        mzd_log "ERROR: TouchTune media identity is invalid"
        return 1
    }
    mzd_log "verified the complete TouchTune USB payload"
}

mzd_watchdog_write() { printf '%s\n' "$1" > "$MZD_WATCHDOG_VALUE"; }
mzd_watchdog_read() { tr -d '\r\n' < "$MZD_WATCHDOG_VALUE"; }

mzd_root_is_read_only() {
    [ -r "$MZD_MOUNTS_FILE" ] || return 1
    awk '
        $2 == "/" {
            found = 0
            count = split($4, option, ",")
            for (i = 1; i <= count; i++) if (option[i] == "ro") found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$MZD_MOUNTS_FILE"
}

mzd_prepare_mutation() {
    [ "$MZD_ROOT_WRITABLE" = 0 ] || return 0
    if [ "$MZD_TEST_MODE" != "1" ]; then
        mzd_log "remounting root read-write"
        MZD_ROOT_WRITABLE=1
        mount -o rw,remount / || return 1
        if [ -e "$MZD_WATCHDOG_VALUE" ]; then
            MZD_WATCHDOG_DISABLED=1
            mzd_watchdog_write 1 || return 1
            [ "$(mzd_watchdog_read)" = 1 ] || return 1
        fi
    else
        MZD_ROOT_WRITABLE=1
    fi
}

mzd_finalize() {
    local failures=0
    sync || failures=$((failures + 1))
    if [ "$MZD_ROOT_WRITABLE" = 1 ]; then
        if [ "$MZD_TEST_MODE" = "1" ]; then
            MZD_ROOT_WRITABLE=0
        else
            mzd_log "remounting root read-only"
            if mount -o ro,remount / && mzd_root_is_read_only; then
                MZD_ROOT_WRITABLE=0
            else
                mzd_log "ERROR: could not remount root read-only"
                failures=$((failures + 1))
            fi
        fi
    fi
    if [ "$MZD_WATCHDOG_DISABLED" = 1 ]; then
        mzd_log "re-enabling watchdog"
        if mzd_watchdog_write 0 && [ "$(mzd_watchdog_read)" = 0 ]; then
            MZD_WATCHDOG_DISABLED=0
        else
            mzd_log "ERROR: could not verify watchdog re-enable"
            failures=$((failures + 1))
        fi
    fi
    sync || failures=$((failures + 1))
    [ "$failures" -eq 0 ]
}

mzd_reboot() {
    [ "$MZD_TEST_MODE" = "1" ] && { mzd_log "test mode: skipping reboot"; return 0; }
    local reply status
    [ -x /usr/bin/dbus-send ] || { mzd_log "ERROR: Mazda SafeReboot client is unavailable"; return 1; }
    reply=$(/usr/bin/dbus-send --address=unix:path=/tmp/dbus_service_socket \
        --print-reply --reply-timeout=5000 --type=method_call \
        --dest=com.jci.blm.system /com/jci/blm/system \
        com.jci.blmsystem.Interface.SafeReboot 2>&1) || {
            mzd_log "ERROR: Mazda SafeReboot request failed: $reply"
            return 1
        }
    status=$(printf '%s\n' "$reply" | awk '$1 == "int32" { print $2; exit }')
    [ "$status" = 100 ] || {
        mzd_log "ERROR: Mazda SafeReboot returned ${status:-no status}; refusing a raw reboot"
        return 1
    }
    mzd_log "Mazda SafeReboot accepted"
}
