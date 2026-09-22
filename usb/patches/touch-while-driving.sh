#!/bin/sh
# Run the TouchTune transaction. install-patches.sh sources this file.

rollback_touch_transaction() {
    local rollback_failures=0
    mzd_log "rolling back to the verified entry state"
    if mzd_validate_target_common "$MZD_COMMON_TARGET" "$ENTRY_COMMON_STATE"; then
        mzd_log "Common.js already matches the entry state"
    else
        if ! mzd_stage_common "$ENTRY_COMMON_STATE" || ! mzd_publish_common "$ENTRY_COMMON_STATE"; then
            rollback_failures=$((rollback_failures + 1))
        fi
    fi
    mzd_set_nvram bus_bcm_speed_restriction "$ENTRY_BUS_STATE" || rollback_failures=$((rollback_failures + 1))
    mzd_set_nvram lvds_speed_restriction "$ENTRY_LVDS_STATE" || rollback_failures=$((rollback_failures + 1))
    mzd_validate_target_common "$MZD_COMMON_TARGET" "$ENTRY_COMMON_STATE" || rollback_failures=$((rollback_failures + 1))
    # A key that was absent at entry may still be absent if its setter failed;
    # that is the factory state and equals the recorded entry value.
    [ "$(mzd_read_nvram_or_factory bus_bcm_speed_restriction 2>/dev/null)" = "$ENTRY_BUS_STATE" ] || rollback_failures=$((rollback_failures + 1))
    [ "$(mzd_read_nvram_or_factory lvds_speed_restriction 2>/dev/null)" = "$ENTRY_LVDS_STATE" ] || rollback_failures=$((rollback_failures + 1))
    MZD_TRANSACTION_ACTIVE=0
    if [ "$rollback_failures" -eq 0 ]; then
        mzd_log "rollback verified"
        return 0
    fi
    mzd_log "ERROR: rollback could not be completely verified"
    return 1
}

# Read one speed-restriction key for the entry state. Mazda's setters create
# these keys on first use, so a key that does not exist yet is the factory value.
read_entry_nvram() {
    local key="$1" value
    if value=$(mzd_read_nvram "$key"); then
        printf '%s\n' "$value"
        return 0
    fi
    if mzd_nvram_key_absent "$key"; then
        value=$(mzd_nvram_factory_value "$key") || return 1
        mzd_log "NVRAM key $key does not exist yet; Mazda's setter creates it. Using the factory value $value as the entry state"
        printf '%s\n' "$value"
        return 0
    fi
    if [ -e "$MZD_NVRAM_DIR/keys/$key" ] || [ -L "$MZD_NVRAM_DIR/keys/$key" ]; then
        mzd_log "ERROR: NVRAM key $key exists but did not read as enable or disable (got '$(tr -d '\r\n' < "$MZD_NVRAM_DIR/keys/$key" 2>/dev/null)'); nothing was changed"
    else
        mzd_log "ERROR: NVRAM key directory $MZD_NVRAM_DIR/keys is unavailable; nothing was changed"
    fi
    return 1
}

if ! ENTRY_COMMON_STATE=$(mzd_common_state "$MZD_COMMON_TARGET"); then
    mzd_log "nothing was changed"
    return 1
fi
if ! mzd_record_common_attrs "$MZD_COMMON_TARGET"; then
    mzd_log "ERROR: could not read the mode and ownership of Common.js; nothing was changed"
    return 1
fi
mzd_log "Common.js is the exact $ENTRY_COMMON_STATE file with mode=$MZD_COMMON_MODE uid=$MZD_COMMON_UID gid=$MZD_COMMON_GID; replacements will keep these attributes"
ENTRY_BUS_STATE=$(read_entry_nvram bus_bcm_speed_restriction) || return 1
ENTRY_LVDS_STATE=$(read_entry_nvram lvds_speed_restriction) || return 1
if ! mzd_require_nvram_setters; then
    mzd_log "ERROR: required NVRAM setters are unavailable; nothing was changed"
    return 1
fi
if ! mzd_init_state; then
    mzd_log "ERROR: could not initialize TouchTune-private state"
    return 1
fi
if ! mzd_ensure_backup "$ENTRY_COMMON_STATE" "$ENTRY_BUS_STATE" "$ENTRY_LVDS_STATE"; then
    mzd_log "ERROR: a trustworthy TouchTune backup is unavailable; nothing was changed"
    return 1
fi

case "$MZD_MODE" in
    install)
        WANTED_COMMON_STATE=patched
        WANTED_BUS_STATE=disable
        WANTED_LVDS_STATE=disable
        ;;
    uninstall)
        WANTED_COMMON_STATE=stock
        WANTED_BUS_STATE=$(mzd_backup_attr nvram_bus_bcm_speed_restriction) || return 1
        WANTED_LVDS_STATE=$(mzd_backup_attr nvram_lvds_speed_restriction) || return 1
        ;;
    *) return 1 ;;
esac

if ! mzd_prepare_mutation; then
    mzd_log "ERROR: could not prepare the CMU for a verified write"
    return 1
fi
# Build and flush the complete file before touching either NVRAM setting.
if [ "$ENTRY_COMMON_STATE" != "$WANTED_COMMON_STATE" ]; then
    if ! mzd_stage_common "$WANTED_COMMON_STATE"; then
        mzd_log "ERROR: could not prepare a complete Common.js replacement; managed state was not changed"
        return 1
    fi
fi
# Revalidate the entry state immediately before the first managed write.
if ! mzd_validate_target_common "$MZD_COMMON_TARGET" "$ENTRY_COMMON_STATE" || \
    [ "$(mzd_read_nvram_or_factory bus_bcm_speed_restriction 2>/dev/null)" != "$ENTRY_BUS_STATE" ] || \
    [ "$(mzd_read_nvram_or_factory lvds_speed_restriction 2>/dev/null)" != "$ENTRY_LVDS_STATE" ]; then
    mzd_log "ERROR: Common.js or the NVRAM keys changed during preflight; refusing to continue. Common.js now: $(mzd_describe_common "$MZD_COMMON_TARGET")"
    return 1
fi

MZD_TRANSACTION_ACTIVE=1
transaction_failed=0
if ! mzd_set_touch_nvram "$WANTED_BUS_STATE" "$WANTED_LVDS_STATE"; then
    transaction_failed=1
fi
if [ "$transaction_failed" -eq 0 ] && [ "$ENTRY_COMMON_STATE" != "$WANTED_COMMON_STATE" ]; then
    mzd_publish_common "$WANTED_COMMON_STATE" || transaction_failed=1
fi
if [ "$transaction_failed" -eq 0 ]; then
    mzd_validate_target_common "$MZD_COMMON_TARGET" "$WANTED_COMMON_STATE" || transaction_failed=1
    [ "$(mzd_read_nvram bus_bcm_speed_restriction 2>/dev/null)" = "$WANTED_BUS_STATE" ] || transaction_failed=1
    [ "$(mzd_read_nvram lvds_speed_restriction 2>/dev/null)" = "$WANTED_LVDS_STATE" ] || transaction_failed=1
fi

if [ "$transaction_failed" -ne 0 ]; then
    mzd_log "ERROR: transaction verification failed"
    rollback_touch_transaction || true
    return 1
fi

MZD_TRANSACTION_ACTIVE=0
mzd_log "transaction complete: Common.js=$WANTED_COMMON_STATE, NVRAM=$WANTED_BUS_STATE/$WANTED_LVDS_STATE"
return 0
