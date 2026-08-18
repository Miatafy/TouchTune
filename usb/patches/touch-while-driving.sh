#!/bin/sh
# Enable touchscreen while driving by blocking the GUI AtSpeed restriction event

TARGET="/jci/gui/common/js/Common.js"
mzd_backup "$TARGET"

ANCHOR='        "Global.AtSpeed" : this._AtSpeedMsgHandler.bind(this),'
if [ ! -r "$TARGET" ]; then
    mzd_log "ERROR: $TARGET is not readable; refusing to patch"
    return 1
fi
ANCHOR_COUNT=$(grep -F -c "$ANCHOR" "$TARGET" 2>/dev/null)
if [ "$ANCHOR_COUNT" != "1" ]; then
    mzd_log "ERROR: expected one unmodified Global.AtSpeed handler; refusing to patch"
    return 1
fi

sed -i 's/        "Global.AtSpeed" : this\._AtSpeedMsgHandler\.bind(this),/        \/\/ MZD_TOUCH_WHILE_DRIVING "Global.AtSpeed" : this._AtSpeedMsgHandler.bind(this),/' "$TARGET"
if ! grep -q 'MZD_TOUCH_WHILE_DRIVING' "$TARGET"; then
    mzd_log "ERROR: touch marker missing after edit"
    return 1
fi

# The speed-restriction flags live in nvram. Record their factory value (enable =
# lockout on) so the restore re-enables them; pass the known value so an already-
# modified unit still reverts to true factory.
mzd_backup_nvram bus_bcm_speed_restriction enable
mzd_backup_nvram lvds_speed_restriction enable

if [ -x "$MZD_JCI_SCRIPTS/set_speed_restriction_config.sh" ]; then
    "$MZD_JCI_SCRIPTS/set_speed_restriction_config.sh" disable || \
        mzd_log "WARN: set_speed_restriction_config.sh disable failed (exit $?)"
fi
if [ -x "$MZD_JCI_SCRIPTS/set_lvds_speed_restriction_config.sh" ]; then
    "$MZD_JCI_SCRIPTS/set_lvds_speed_restriction_config.sh" disable || \
        mzd_log "WARN: set_lvds_speed_restriction_config.sh disable failed (exit $?)"
fi
