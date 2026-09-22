#!/bin/sh
set -eu

REPO_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/touchtune-tests.XXXXXX")
cleanup() {
    chmod -R u+w "$TEST_TMP" 2>/dev/null || true
    rm -rf "$TEST_TMP"
}
trap cleanup 0
TEST_COUNT=0

"$REPO_DIR/tools/payload-manifest.sh" --check
python3 "$REPO_DIR/tools/release.py" check

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    echo "ok $TEST_COUNT - $1"
}

sha256_file() {
    local output
    output=$(openssl dgst -sha256 "$1") || return 1
    printf '%s\n' "${output##* }"
}

bytes_file() { wc -c < "$1" | tr -d ' '; }
mode_file() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
uid_file() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
gid_file() { stat -c '%g' "$1" 2>/dev/null || stat -f '%g' "$1"; }

assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (wanted '$2', got '$1')"
}

assert_attrs() {
    local path="$1" label="$2"
    assert_eq "$(mode_file "$path")" "$FIXTURE_FILE_MODE" "$label mode"
    assert_eq "$(uid_file "$path")" "$FIXTURE_FILE_UID" "$label uid"
    assert_eq "$(gid_file "$path")" "$FIXTURE_FILE_GID" "$label gid"
}

assert_file_state() {
    local wanted="$1" path="$2" actual
    actual=$(sha256_file "$path")
    case "$wanted" in
        stock) assert_eq "$actual" "$FIXTURE_STOCK_SHA" "$path stock digest" ;;
        patched) assert_eq "$actual" "$FIXTURE_PATCHED_SHA" "$path patched digest" ;;
        *) fail "unknown assertion state: $wanted" ;;
    esac
}

make_fixture() {
    FIXTURE_NAME="$1"
    FIXTURE_DIR="$TEST_TMP/$FIXTURE_NAME"
    FIXTURE_ROOT="$FIXTURE_DIR/root"
    FIXTURE_USB="$FIXTURE_DIR/usb"
    FIXTURE_LOG="$FIXTURE_DIR/run.log"
    mkdir -p "$FIXTURE_ROOT/jci/gui/common/js" "$FIXTURE_ROOT/jci/scripts" \
        "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys" "$FIXTURE_ROOT/data" "$FIXTURE_USB"
    cp -R "$REPO_DIR/usb/." "$FIXTURE_USB/"
    cat > "$FIXTURE_ROOT/jci/version.ini" <<'EOF'
JCI_SW_VER="MAZ_CMU-140_74.00.324"
JCI_SW_VER_PATCH="A"
EOF
    cat > "$FIXTURE_ROOT/jci/gui/common/js/Common.js" <<'EOF'
(function () {
    var messageHandlers = {
        "Global.AtSpeed" : this._AtSpeedMsgHandler.bind(this),
        "Global.Other" : this._OtherMsgHandler.bind(this)
    };
}());
framework.registerCommonLoaded(["common/controls/StatusBar"]);
EOF
    chmod 0755 "$FIXTURE_ROOT/jci/gui/common/js/Common.js"
    printf '%s\n' enable > "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction"
    printf '%s\n' enable > "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
    cat > "$FIXTURE_ROOT/jci/scripts/set_speed_restriction_config.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "bus=$1" >> "$MZD_ROOT/setter-attempts"
if [ -f "$MZD_ROOT/test/fail-bus-$1" ]; then exit 47; fi
if [ -f "$MZD_ROOT/test/lie-bus-$1" ]; then exit 0; fi
printf '%s\n' "bus=$1" >> "$MZD_ROOT/nvram-writes"
printf '%s\n' "$1" > "$MZD_NVRAM_DIR/keys/bus_bcm_speed_restriction"
if [ -f "$MZD_ROOT/test/signal" ]; then
    read -r signal < "$MZD_ROOT/test/signal"
    rm "$MZD_ROOT/test/signal"
    kill -s "$signal" "$PPID"
fi
EOF
    cat > "$FIXTURE_ROOT/jci/scripts/set_lvds_speed_restriction_config.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "lvds=$1" >> "$MZD_ROOT/setter-attempts"
if [ -f "$MZD_ROOT/test/fail-lvds-$1" ]; then exit 47; fi
if [ -f "$MZD_ROOT/test/lie-lvds-$1" ]; then exit 0; fi
printf '%s\n' "lvds=$1" >> "$MZD_ROOT/nvram-writes"
printf '%s\n' "$1" > "$MZD_NVRAM_DIR/keys/lvds_speed_restriction"
EOF
    chmod 0755 "$FIXTURE_ROOT/jci/scripts/"*.sh
    FIXTURE_COMMON="$FIXTURE_ROOT/jci/gui/common/js/Common.js"
    FIXTURE_STOCK_SHA=$(sha256_file "$FIXTURE_COMMON")
    FIXTURE_STOCK_BYTES=$(bytes_file "$FIXTURE_COMMON")
    FIXTURE_FILE_MODE=$(mode_file "$FIXTURE_COMMON")
    FIXTURE_FILE_UID=$(uid_file "$FIXTURE_COMMON")
    FIXTURE_FILE_GID=$(gid_file "$FIXTURE_COMMON")
    awk '
        $0 == "        \"Global.AtSpeed\" : this._AtSpeedMsgHandler.bind(this)," {
            print "        // MZD_TOUCH_WHILE_DRIVING \"Global.AtSpeed\" : this._AtSpeedMsgHandler.bind(this),"
            next
        }
        { print }
    ' "$FIXTURE_COMMON" > "$FIXTURE_DIR/patched.js"
    FIXTURE_PATCHED_SHA=$(sha256_file "$FIXTURE_DIR/patched.js")
}

run_installer() {
    local action="$1" fault="${2:-}" status=0
    : > "$FIXTURE_LOG"
    PATH="$FIXTURE_DIR/bin:$PATH" \
    MZD_TEST_MODE=1 \
    MZD_ROOT="$FIXTURE_ROOT" \
    MZD_NVRAM_DIR="$FIXTURE_ROOT/sys/class/nvram/nv-config" \
    TOUCHTUNE_TEST_ACTION="$action" \
    TOUCHTUNE_TEST_STOCK_SHA256="$FIXTURE_STOCK_SHA" \
    TOUCHTUNE_TEST_PATCHED_SHA256="$FIXTURE_PATCHED_SHA" \
    TOUCHTUNE_TEST_STOCK_BYTES="$FIXTURE_STOCK_BYTES" \
    TOUCHTUNE_FAULT="$fault" \
        sh "$FIXTURE_USB/install-patches.sh" > "$FIXTURE_LOG" 2>&1 || status=$?
    return "$status"
}

nvram_value() { tr -d '\r\n' < "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/$1"; }

make_fixture lifecycle
run_installer install || fail "first install failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
assert_attrs "$FIXTURE_COMMON" "installed Common.js"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" disable "bus NVRAM after install"
assert_eq "$(nvram_value lvds_speed_restriction)" disable "LVDS NVRAM after install"
[ ! -e "$FIXTURE_ROOT/data/touchtune/state" ] || fail "install created diagnostic state"
BACKUP_SHA=$(sha256_file "$FIXTURE_ROOT/data/touchtune/backups/common-js/Common.js")
BACKUP_META_SHA=$(sha256_file "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata")
BACKUP_META_DIGEST_SHA=$(sha256_file "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata.sha256")
run_installer install || fail "repeat install failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
assert_eq "$(sha256_file "$FIXTURE_ROOT/data/touchtune/backups/common-js/Common.js")" "$BACKUP_SHA" "backup changed on repair"
assert_eq "$(sha256_file "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata")" "$BACKUP_META_SHA" "backup metadata changed on repair"
assert_eq "$(sha256_file "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata.sha256")" "$BACKUP_META_DIGEST_SHA" "backup metadata digest changed on repair"
run_installer uninstall || fail "uninstall failed: $(cat "$FIXTURE_LOG")"
assert_file_state stock "$FIXTURE_COMMON"
assert_attrs "$FIXTURE_COMMON" "restored Common.js"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "bus NVRAM after uninstall"
assert_eq "$(nvram_value lvds_speed_restriction)" enable "LVDS NVRAM after uninstall"
[ ! -e "$FIXTURE_ROOT/data/touchtune/state" ] || fail "uninstall created diagnostic state"
run_installer uninstall || fail "repeat uninstall failed: $(cat "$FIXTURE_LOG")"
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(wc -l < "$FIXTURE_ROOT/nvram-writes" | tr -d '[:space:]')" 8 "repeat actions skipped NVRAM setters"
pass "repeat actions preserve the backup and require successful NVRAM setters"

make_fixture existing_nvram
printf '%s\n' disable > "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction"
printf '%s\n' disable > "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
run_installer install || fail "install over an existing NVRAM configuration failed: $(cat "$FIXTURE_LOG")"
grep -q '^nvram_baseline=entry$' "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata" || fail "entry baseline was not recorded"
run_installer uninstall || fail "uninstall over an existing NVRAM configuration failed: $(cat "$FIXTURE_LOG")"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" disable "bus entry baseline after uninstall"
assert_eq "$(nvram_value lvds_speed_restriction)" disable "LVDS entry baseline after uninstall"
pass "removal restores the NVRAM values present before a stock first install"

# Mazda ships the GUI tree with a different owner and mode than the bench had.
# Whatever the live file has must survive install and removal unchanged.
make_fixture inherited_attrs
chmod 0664 "$FIXTURE_COMMON"
FIXTURE_FILE_MODE=$(mode_file "$FIXTURE_COMMON")
run_installer install || fail "install with an unusual file mode failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
assert_attrs "$FIXTURE_COMMON" "installed Common.js with inherited mode"
grep -q "mode=664 uid=$FIXTURE_FILE_UID gid=$FIXTURE_FILE_GID; replacements will keep" "$FIXTURE_LOG" || fail "recorded attributes were not logged"
if grep -q 'permissions do not match' "$FIXTURE_LOG"; then fail "profile permission check still exists"; fi
run_installer uninstall || fail "removal with an unusual file mode failed: $(cat "$FIXTURE_LOG")"
assert_file_state stock "$FIXTURE_COMMON"
assert_attrs "$FIXTURE_COMMON" "restored Common.js with inherited mode"
pass "Common.js mode and ownership are inherited from the live file, never asserted"

# Some 74.00.324A units have never run the speed-restriction setters, so the
# NVRAM keys do not exist until Mazda's own scripts create them.
make_fixture nvram_keys_absent
rm "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction" \
    "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
run_installer install || fail "install with absent NVRAM keys failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" disable "bus key created and set on install"
assert_eq "$(nvram_value lvds_speed_restriction)" disable "LVDS key created and set on install"
grep -q 'bus_bcm_speed_restriction does not exist yet' "$FIXTURE_LOG" || fail "absent bus key was not explained"
grep -q 'lvds_speed_restriction does not exist yet' "$FIXTURE_LOG" || fail "absent LVDS key was not explained"
grep -q '^nvram_bus_bcm_speed_restriction=enable$' "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata" || fail "factory entry value was not recorded"
run_installer uninstall || fail "removal after absent-key install failed: $(cat "$FIXTURE_LOG")"
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "bus factory value after removal"
assert_eq "$(nvram_value lvds_speed_restriction)" enable "LVDS factory value after removal"
pass "absent NVRAM keys are treated as factory values and created by the stock setters"

make_fixture nvram_keys_absent_setter_failure
rm "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction" \
    "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
mkdir "$FIXTURE_ROOT/test"
: > "$FIXTURE_ROOT/test/fail-lvds-disable"
if run_installer install; then fail "setter failure with absent keys returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "bus rolled back to factory"
assert_eq "$(nvram_value lvds_speed_restriction)" enable "LVDS set to factory by rollback"
grep -q 'rollback verified' "$FIXTURE_LOG" || fail "rollback from absent keys was not verified"
pass "rollback after a setter failure leaves absent keys at their factory value"

make_fixture nvram_key_garbage
printf '%s\n' maybe > "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
if run_installer install; then fail "unreadable NVRAM key was accepted"; fi
assert_file_state stock "$FIXTURE_COMMON"
[ ! -e "$FIXTURE_ROOT/nvram-writes" ] || fail "unreadable key led to NVRAM writes"
grep -q "lvds_speed_restriction exists but did not read as enable or disable (got 'maybe')" "$FIXTURE_LOG" || fail "unreadable key was not diagnosed"
pass "an existing NVRAM key with an unexpected value is still refused"

make_fixture nvram_dir_missing
rm -r "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys"
if run_installer install; then fail "missing NVRAM key directory was accepted"; fi
assert_file_state stock "$FIXTURE_COMMON"
grep -q 'NVRAM key directory .* is unavailable' "$FIXTURE_LOG" || fail "missing key directory was not diagnosed"
pass "a missing NVRAM key directory is refused rather than assumed factory"

make_fixture legacy_upgrade
cp "$FIXTURE_DIR/patched.js" "$FIXTURE_COMMON"
chmod 0755 "$FIXTURE_COMMON"
printf '%s\n' disable > "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/bus_bcm_speed_restriction"
printf '%s\n' disable > "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/lvds_speed_restriction"
mkdir -p "$FIXTURE_ROOT/data/foreign-tool/shared-backups"
printf '%s\n' 'untrusted shared backup' > "$FIXTURE_ROOT/data/foreign-tool/shared-backups/Common.js"
run_installer install || fail "upgrade from exact legacy patch failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
assert_eq "$(sha256_file "$FIXTURE_ROOT/data/touchtune/backups/common-js/Common.js")" "$FIXTURE_STOCK_SHA" "reconstructed private factory backup"
assert_eq "$(cat "$FIXTURE_ROOT/data/foreign-tool/shared-backups/Common.js")" "untrusted shared backup" "shared backup was touched"
grep -q '^nvram_baseline=factory-fallback$' "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata" || fail "legacy fallback policy was not recorded"
run_installer uninstall || fail "uninstall after legacy migration failed: $(cat "$FIXTURE_LOG")"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "legacy bus factory fallback"
assert_eq "$(nvram_value lvds_speed_restriction)" enable "legacy LVDS factory fallback"
pass "legacy migration records its factory fallback and ignores shared backup residue"

make_fixture truncated_candidate
if run_installer install truncate-common-candidate; then fail "truncated candidate was accepted"; fi
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "bus rollback after short write"
assert_eq "$(nvram_value lvds_speed_restriction)" enable "LVDS rollback after short write"
grep -q 'staged Common.js failed' "$FIXTURE_LOG" || fail "truncated candidate refusal was not diagnosed"
pass "truncated candidate cannot replace Common.js"

make_fixture common_write_failure
if run_installer install common-write-failure; then fail "Common.js write failure returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
[ ! -e "$FIXTURE_ROOT/jci/gui/common/js/.Common.js.touchtune.new" ] || fail "failed candidate was not removed"
[ ! -e "$FIXTURE_ROOT/jci/gui/common/js/.Common.js.touchtune.work" ] || fail "failed work file was not removed"
[ ! -e "$FIXTURE_ROOT/nvram-writes" ] || fail "candidate failure wrote NVRAM"
pass "Common.js write failure removes staging without NVRAM writes"

make_fixture common_fsync_failure
if run_installer install common-fsync-failure; then fail "Common.js fsync failure returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
[ ! -e "$FIXTURE_ROOT/jci/gui/common/js/.Common.js.touchtune.new" ] || fail "unflushed candidate was not removed"
[ ! -e "$FIXTURE_ROOT/jci/gui/common/js/.Common.js.touchtune.work" ] || fail "fsync failure left a work file"
[ ! -e "$FIXTURE_ROOT/nvram-writes" ] || fail "candidate fsync failure wrote NVRAM"
pass "Common.js fsync failure removes staging without NVRAM writes"

make_fixture backup_write_failure
if run_installer install backup-write-failure; then fail "backup write failure returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
[ ! -e "$FIXTURE_ROOT/data/touchtune/backups/.common-js.pending" ] || fail "failed backup stage was not removed"
pass "backup write failure removes its private staging directory"

make_fixture corrupt_source
printf '%s\n' '// latent corruption' >> "$FIXTURE_COMMON"
if run_installer install; then fail "corrupt source was accepted"; fi
[ ! -e "$FIXTURE_ROOT/data/touchtune/backups/common-js" ] || fail "corrupt source became a backup"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "NVRAM changed for corrupt source"
grep -q 'neither the stock nor the TouchTune file' "$FIXTURE_LOG" || fail "corrupt source refusal was not diagnosed"
grep -q 'sha256=' "$FIXTURE_LOG" || fail "corrupt source digest was not logged"
pass "unknown or corrupt Common.js baseline is refused before mutation"

make_fixture unsupported_firmware
cat > "$FIXTURE_ROOT/jci/version.ini" <<'EOF'
JCI_SW_VER="MAZ_CMU-140_74.00.331"
EOF
if run_installer install; then fail "unsupported firmware was accepted"; fi
assert_file_state stock "$FIXTURE_COMMON"
[ ! -e "$FIXTURE_ROOT/data/touchtune" ] || fail "state created before firmware refusal"
grep -q 'firmware 74.00.331 is unsupported' "$FIXTURE_LOG" || fail "firmware refusal was not diagnosed"
pass "unsupported firmware is refused before state or system mutation"

make_fixture corrupt_backup
run_installer install || fail "setup install for corrupt backup failed"
chmod 0644 "$FIXTURE_ROOT/data/touchtune/backups/common-js/Common.js"
printf '%s\n' corrupt > "$FIXTURE_ROOT/data/touchtune/backups/common-js/Common.js"
if run_installer install; then fail "corrupt backup was accepted"; fi
assert_file_state patched "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" disable "NVRAM changed after corrupt-backup refusal"
grep -q 'backup is incomplete, corrupt' "$FIXTURE_LOG" || fail "corrupt backup refusal was not diagnosed"
pass "corrupt write-once backup is never inherited or restored"

make_fixture corrupt_backup_metadata
run_installer install || fail "setup install for corrupt metadata failed"
chmod 0644 "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata"
printf '\n' >> "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata"
chmod 0444 "$FIXTURE_ROOT/data/touchtune/backups/common-js/metadata"
if run_installer install; then fail "corrupt backup metadata was accepted"; fi
assert_file_state patched "$FIXTURE_COMMON"
grep -q 'backup is incomplete, corrupt' "$FIXTURE_LOG" || fail "metadata corruption was not diagnosed"
pass "backup metadata must match its recorded digest"

make_fixture backup_interruption
if run_installer install interrupt-before-backup-rename; then fail "backup interruption returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
[ ! -e "$FIXTURE_ROOT/data/touchtune/backups/common-js" ] || fail "partial backup was published"
run_installer install || fail "retry after backup interruption failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
pass "interrupted backup publication exposes no partial final backup and retry succeeds"

make_fixture publish_before
if run_installer install interrupt-before-common-rename; then fail "pre-rename interruption returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
run_installer install || fail "retry after pre-rename interruption failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
pass "interruption before atomic rename leaves the original and can be retried"

make_fixture publish_after
if run_installer install interrupt-after-common-rename; then fail "post-rename interruption returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "post-rename exit rollback"
run_installer install || fail "retry after post-rename interruption failed: $(cat "$FIXTURE_LOG")"
assert_file_state patched "$FIXTURE_COMMON"
pass "catchable exit after atomic rename rolls back and permits retry"

make_fixture publish_readback
if run_installer install corrupt-common-after-rename; then fail "corrupt post-publication readback returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "bus NVRAM was not rolled back after readback failure"
grep -q 'published Common.js failed readback validation' "$FIXTURE_LOG" || fail "post-publication readback failure was not diagnosed"
pass "post-publication readback failure is fatal and rolls back"

make_fixture nvram_failure
mkdir "$FIXTURE_ROOT/test"
: > "$FIXTURE_ROOT/test/fail-lvds-disable"
if run_installer install; then fail "NVRAM setter failure returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "bus NVRAM was not rolled back"
assert_eq "$(nvram_value lvds_speed_restriction)" enable "LVDS NVRAM changed after setter failure"
grep -q 'NVRAM setter failed' "$FIXTURE_LOG" || fail "setter failure was not diagnosed"
pass "NVRAM setter failure is fatal and verified rollback restores entry state"

make_fixture rollback_failure
mkdir "$FIXTURE_ROOT/test"
: > "$FIXTURE_ROOT/test/fail-bus-enable"
if run_installer install corrupt-common-after-rename; then fail "incomplete rollback returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
grep -q '^bus=enable$' "$FIXTURE_ROOT/setter-attempts" || fail "bus restore was not attempted"
grep -q '^lvds=enable$' "$FIXTURE_ROOT/setter-attempts" || fail "LVDS restore was skipped after bus failure"
assert_eq "$(nvram_value lvds_speed_restriction)" enable "LVDS restore after bus rollback failure"
grep -q 'rollback could not be completely verified' "$FIXTURE_LOG" || fail "incomplete rollback was not reported"
if grep -q 'skipping reboot' "$FIXTURE_LOG"; then fail "incomplete rollback requested reboot"; fi
pass "rollback attempts both NVRAM restores and reports an incomplete recovery"

for signal in HUP INT TERM; do
    make_fixture "signal_$signal"
    mkdir "$FIXTURE_ROOT/test"
    printf '%s\n' "$signal" > "$FIXTURE_ROOT/test/signal"
    status=0
    run_installer install || status=$?
    case "$signal" in HUP) wanted_status=129 ;; INT) wanted_status=130 ;; TERM) wanted_status=143 ;; esac
    assert_eq "$status" "$wanted_status" "$signal exit status"
    assert_file_state stock "$FIXTURE_COMMON"
    assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "$signal bus rollback"
    assert_eq "$(nvram_value lvds_speed_restriction)" enable "$signal LVDS rollback"
    [ ! -e "$FIXTURE_ROOT/jci/gui/common/js/.Common.js.touchtune.new" ] || fail "$signal left a candidate"
    grep -q 'rollback verified' "$FIXTURE_LOG" || fail "$signal did not verify rollback"
    if grep -q 'skipping reboot' "$FIXTURE_LOG"; then fail "$signal requested reboot"; fi
done
pass "HUP, INT, and TERM roll back an active transaction and remove the staged file"

make_fixture nvram_readback
mkdir "$FIXTURE_ROOT/test"
: > "$FIXTURE_ROOT/test/lie-lvds-disable"
if run_installer install; then fail "NVRAM readback mismatch returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" enable "bus NVRAM was not rolled back after readback mismatch"
grep -q 'NVRAM readback mismatch' "$FIXTURE_LOG" || fail "readback mismatch was not diagnosed"
pass "successful setter exit is insufficient without matching NVRAM readback"

# Mazda's setters update live keys before committing the entire NVRAM block.
# Failed commits can leave readable values that do not match persistent storage.
make_fixture nvram_commit_retry
run_installer install || fail "setup install for commit failure failed"
mkdir "$FIXTURE_ROOT/persistent"
cp "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/"* "$FIXTURE_ROOT/persistent/"
cat > "$FIXTURE_ROOT/jci/scripts/set_speed_restriction_config.sh" <<'EOF'
#!/bin/sh
case "${0##*/}" in
    set_speed_restriction_config.sh) key=bus_bcm_speed_restriction ;;
    set_lvds_speed_restriction_config.sh) key=lvds_speed_restriction ;;
esac
printf '%s\n' "$1" > "$MZD_NVRAM_DIR/keys/$key"
count=0
[ ! -f "$MZD_ROOT/commit-count" ] || read -r count < "$MZD_ROOT/commit-count"
count=$((count + 1))
printf '%s\n' "$count" > "$MZD_ROOT/commit-count"
# Let removal's first commit succeed, then fail its second commit and rollback.
[ "$count" -eq 1 ] || [ -f "$MZD_ROOT/allow-commits" ] || exit 47
cp "$MZD_NVRAM_DIR/keys/"* "$MZD_ROOT/persistent/"
EOF
cp "$FIXTURE_ROOT/jci/scripts/set_speed_restriction_config.sh" \
    "$FIXTURE_ROOT/jci/scripts/set_lvds_speed_restriction_config.sh"
if run_installer uninstall; then fail "failed commits were accepted on removal"; fi
assert_file_state patched "$FIXTURE_COMMON"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" disable "live bus after incomplete rollback"
assert_eq "$(nvram_value lvds_speed_restriction)" disable "live LVDS after incomplete rollback"
assert_eq "$(cat "$FIXTURE_ROOT/persistent/bus_bcm_speed_restriction")" enable "persisted bus after incomplete rollback"
grep -q 'rollback could not be completely verified' "$FIXTURE_LOG" || fail "failed rollback commits were not reported"

if run_installer install; then fail "repair accepted matching live values while commits failed"; fi
grep -q 'NVRAM setter failed' "$FIXTURE_LOG" || fail "repair did not attempt a commit"
if grep -q 'skipping reboot' "$FIXTURE_LOG"; then fail "failed repair requested reboot"; fi
: > "$FIXTURE_ROOT/allow-commits"
run_installer install || fail "repair did not recover when commits became available"
assert_file_state patched "$FIXTURE_COMMON"
assert_eq "$(cat "$FIXTURE_ROOT/persistent/bus_bcm_speed_restriction")" disable "repaired persisted bus"
assert_eq "$(cat "$FIXTURE_ROOT/persistent/lvds_speed_restriction")" disable "repaired persisted LVDS"
# Simulate boot reloading the committed block into the live keys.
cp "$FIXTURE_ROOT/persistent/"* "$FIXTURE_ROOT/sys/class/nvram/nv-config/keys/"
assert_eq "$(nvram_value bus_bcm_speed_restriction)" disable "repaired bus after simulated boot"
assert_eq "$(nvram_value lvds_speed_restriction)" disable "repaired LVDS after simulated boot"
pass "repair requires successful commits after incomplete rollback and survives simulated boot"

make_fixture old_receipt
mkdir -p "$FIXTURE_ROOT/data/touchtune/state"
printf '%s\n' obsolete > "$FIXTURE_ROOT/data/touchtune/state/receipt"
chmod 0444 "$FIXTURE_ROOT/data/touchtune/state/receipt"
chmod 0555 "$FIXTURE_ROOT/data/touchtune/state"
run_installer install || fail "old receipt prevented installation"
assert_file_state patched "$FIXTURE_COMMON"
assert_eq "$(cat "$FIXTURE_ROOT/data/touchtune/state/receipt")" obsolete "old receipt was rewritten"
pass "old diagnostic receipts are ignored and never rewritten"

# Simulate a real metadata writer that emits partial output, then either fails
# or falsely succeeds. Neither result may publish an unusable final backup.
for writer_status in 47 0; do
    make_fixture "metadata_partial_$writer_status"
    mkdir "$FIXTURE_DIR/bin"
    cat > "$FIXTURE_DIR/bin/cat" <<'EOF'
#!/bin/sh
if [ "$#" -eq 0 ] && [ ! -e "$MZD_ROOT/metadata-fault-used" ]; then
    /bin/cat > "$MZD_ROOT/metadata-input"
    case "$(head -n 1 "$MZD_ROOT/metadata-input")" in
        format=touchtune-backup-v3)
            : > "$MZD_ROOT/metadata-fault-used"
            head -n 1 "$MZD_ROOT/metadata-input"
            exit "$TOUCHTUNE_WRITER_STATUS"
            ;;
    esac
    /bin/cat "$MZD_ROOT/metadata-input"
else
    /bin/cat "$@"
fi
EOF
    chmod 0755 "$FIXTURE_DIR/bin/cat"
    export TOUCHTUNE_WRITER_STATUS="$writer_status"
    if run_installer install; then fail "partial metadata writer status $writer_status was accepted"; fi
    [ ! -e "$FIXTURE_ROOT/data/touchtune/backups/common-js" ] || fail "partial metadata was published"
    [ ! -e "$FIXTURE_ROOT/data/touchtune/backups/.common-js.pending" ] || fail "partial metadata stage remained"
    [ ! -e "$FIXTURE_ROOT/nvram-writes" ] || fail "partial metadata changed NVRAM"
    run_installer install || fail "retry after partial metadata failed: $(cat "$FIXTURE_LOG")"
    assert_file_state patched "$FIXTURE_COMMON"
done
unset TOUCHTUNE_WRITER_STATUS
pass "partial metadata writes cannot publish a backup or block a normal retry"

make_fixture corrupt_helper
printf '%s\n' ': > "$MZD_ROOT/helper-executed"' >> "$FIXTURE_USB/lib/touchtune-helpers.sh"
if run_installer install; then fail "corrupt helper returned success"; fi
[ ! -e "$FIXTURE_ROOT/helper-executed" ] || fail "corrupt helper executed before verification"
assert_file_state stock "$FIXTURE_COMMON"
grep -q 'helper validation failed before execution' "$FIXTURE_LOG" || fail "early helper refusal was not diagnosed"
pass "helper code is verified before it is sourced"

make_fixture corrupt_payload
printf '%s\n' '# damaged in transit' >> "$FIXTURE_USB/patches/touch-while-driving.sh"
if run_installer install; then fail "corrupt payload returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
[ ! -e "$FIXTURE_ROOT/data/touchtune" ] || fail "state created before corrupt payload refusal"
grep -q 'payload digest mismatch' "$FIXTURE_LOG" || fail "payload mismatch was not diagnosed"
pass "payload digest mismatch is refused before CMU mutation"

make_fixture missing_trigger_payload
mv "$FIXTURE_USB/jci-autoupdate" "$FIXTURE_DIR/jci-autoupdate.saved"
if run_installer install; then fail "payload without jci-autoupdate returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
grep -q 'payload file missing: jci-autoupdate' "$FIXTURE_LOG" || fail "missing trigger was not diagnosed"
pass "installer payload verification requires jci-autoupdate"

make_fixture wrong_launcher_payload
declared_launcher=$(tr -d '\r\n' < "$FIXTURE_USB/LAUNCHER.NAME")
mv "$FIXTURE_USB/$declared_launcher" "$FIXTURE_USB/residual-old-launcher.up"
if run_installer install; then fail "payload with the wrong launcher returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
grep -q 'payload file missing: @launcher' "$FIXTURE_LOG" || fail "wrong launcher was not diagnosed"
pass "installer payload verification requires the declared launcher"

for extra in leftover.up LEFTOVER.UP ._leftover.up; do
    make_fixture "runtime_launcher_$extra"
    printf '%s\n' stale > "$FIXTURE_USB/$extra"
    if run_installer install; then fail "conflicting runtime launcher was accepted: $extra"; fi
    assert_file_state stock "$FIXTURE_COMMON"
    [ ! -e "$FIXTURE_ROOT/data/touchtune" ] || fail "launcher conflict created installer state"
done
pass "runtime checks refuse visible, hidden, and uppercase conflicting launchers"

make_fixture residual_patch
printf '%s\n' '#!/bin/sh' 'exit 0' > "$FIXTURE_USB/patches/zz-residual.sh"
if run_installer install; then fail "residual patch returned success"; fi
assert_file_state stock "$FIXTURE_COMMON"
grep -q 'unmanifested patch present' "$FIXTURE_LOG" || fail "residual patch was not diagnosed"
pass "unmanifested residual patches are never executed"

launcher_count=0
for launcher in "$REPO_DIR"/usb/*.up; do
    [ -f "$launcher" ] || continue
    launcher_count=$((launcher_count + 1))
    launcher_name=${launcher##*/}
done
assert_eq "$launcher_count" 1 "launcher count"
case "$launcher_name" in
    *'N=0;'*'M=$P${S}TOUCHTUNE.ID;[ -f $M ]&&set -- $(cksum $M)&&[ $1 = 745427070 ]&&[ $2 = 17 ]'*'[ $N = 1 ]&&[ -f $I ]&&sh $I).up') ;;
    *) fail "launcher does not require one exact TouchTune identity" ;;
esac
case "$launcher_name" in *'grep -x'*) fail "launcher requires unsupported BusyBox grep -x" ;; esac
marker_result=$(cksum "$REPO_DIR/usb/TOUCHTUNE.ID")
marker_crc=${marker_result%% *}
marker_result=${marker_result#* }
marker_bytes=${marker_result%% *}
assert_eq "$marker_crc" 745427070 "launcher marker checksum"
assert_eq "$marker_bytes" 17 "launcher marker size"
launcher_command=${launcher_name#'$('}
launcher_command=${launcher_command%').up'}
sh -n -c "$launcher_command" || fail "launcher command is not valid POSIX shell"
assert_eq "$(tr -d '\r\n' < "$REPO_DIR/usb/LAUNCHER.NAME")" "$launcher_name" "declared launcher name"
pass "launcher source and media declaration require the exact TouchTune identity"

LAUNCH_ROOT="$TEST_TMP/launcher-selection"
mkdir -p "$LAUNCH_ROOT/tmp/mnt/sda1" "$LAUNCH_ROOT/tmp/mnt/sdb1"
cat > "$LAUNCH_ROOT/tmp/mnt/sda1/install-patches.sh" <<'EOF'
#!/bin/sh
printf '%s\n' ran > "$TOUCHTUNE_LAUNCH_EVIDENCE"
EOF
cp "$LAUNCH_ROOT/tmp/mnt/sda1/install-patches.sh" "$LAUNCH_ROOT/tmp/mnt/sdb1/install-patches.sh"
printf '%s\n' foreign > "$LAUNCH_ROOT/tmp/mnt/sda1/TOUCHTUNE.ID"
TOUCHTUNE_LAUNCH_EVIDENCE="$LAUNCH_ROOT/foreign-ran" TT_ROOT="$LAUNCH_ROOT" HOME=/root sh -c "$launcher_command" || true
[ ! -e "$LAUNCH_ROOT/foreign-ran" ] || fail "foreign marker launched an installer"
printf '%s\n' touchtune-oss-v2 > "$LAUNCH_ROOT/tmp/mnt/sda1/TOUCHTUNE.ID"
TOUCHTUNE_LAUNCH_EVIDENCE="$LAUNCH_ROOT/exact-ran" TT_ROOT="$LAUNCH_ROOT" HOME=/root sh -c "$launcher_command"
[ -f "$LAUNCH_ROOT/exact-ran" ] || fail "exact marker did not launch the installer"
printf '%s\n' touchtune-oss-v2 > "$LAUNCH_ROOT/tmp/mnt/sdb1/TOUCHTUNE.ID"
TOUCHTUNE_LAUNCH_EVIDENCE="$LAUNCH_ROOT/ambiguous-ran" TT_ROOT="$LAUNCH_ROOT" HOME=/root sh -c "$launcher_command" || true
[ ! -e "$LAUNCH_ROOT/ambiguous-ran" ] || fail "ambiguous TouchTune volumes launched an installer"
pass "launcher executes one exact TouchTune volume and refuses foreign or ambiguous media"

PACKAGE_ONE="$TEST_TMP/touchtune-one.zip"
PACKAGE_TWO="$TEST_TMP/touchtune-two.zip"
python3 "$REPO_DIR/tools/release.py" package "$PACKAGE_ONE" >/dev/null
python3 "$REPO_DIR/tools/release.py" package "$PACKAGE_TWO" >/dev/null
cmp -s "$PACKAGE_ONE" "$PACKAGE_TWO" || fail "release archives are not reproducible"
MEDIA_DIR="$TEST_TMP/release-media"
mkdir "$MEDIA_DIR"
unzip -qq "$PACKAGE_ONE" -d "$MEDIA_DIR"
cmp -s "$REPO_DIR/macos-usb-eject.sh" "$MEDIA_DIR/macos-usb-eject.sh" || fail "release helper differs from its source"
"$MEDIA_DIR/macos-usb-eject.sh" --verify-only "$MEDIA_DIR" >/dev/null || fail "release media did not verify"
pass "release package is reproducible and verifies as a complete USB root"

MISSING_TRIGGER="$TEST_TMP/missing-trigger"
mkdir "$MISSING_TRIGGER"
unzip -qq "$PACKAGE_ONE" -d "$MISSING_TRIGGER"
mv "$MISSING_TRIGGER/jci-autoupdate" "$TEST_TMP/jci-autoupdate.saved"
if "$REPO_DIR/macos-usb-eject.sh" --verify-only "$MISSING_TRIGGER" >/dev/null 2>&1; then
    fail "media without jci-autoupdate was accepted"
fi
WRONG_LAUNCHER="$TEST_TMP/wrong-launcher"
mkdir "$WRONG_LAUNCHER"
unzip -qq "$PACKAGE_ONE" -d "$WRONG_LAUNCHER"
declared_launcher=$(tr -d '\r\n' < "$WRONG_LAUNCHER/LAUNCHER.NAME")
mv "$WRONG_LAUNCHER/$declared_launcher" "$WRONG_LAUNCHER/residual-old-launcher.up"
if "$REPO_DIR/macos-usb-eject.sh" --verify-only "$WRONG_LAUNCHER" >/dev/null 2>&1; then
    fail "media with the wrong launcher was accepted"
fi
pass "media verification refuses a missing trigger and wrong launcher"

mkdir -p "$MEDIA_DIR/System Volume Information" "$MEDIA_DIR/holiday-photos"
printf '%s\n' personal > "$MEDIA_DIR/notes.txt"
printf '%s\n' '#!/bin/sh' > "$MEDIA_DIR/lib/unrelated.sh"
"$REPO_DIR/macos-usb-eject.sh" --verify-only "$MEDIA_DIR" >/dev/null || fail "unrelated USB contents were rejected"
pass "media verification accepts unrelated directories, files, and the macOS helper"

for extra in old-launcher.up OLD-LAUNCHER.UP ._old-launcher.up patches/leftover.sh; do
    printf '%s\n' stale > "$MEDIA_DIR/$extra"
    if "$REPO_DIR/macos-usb-eject.sh" --verify-only "$MEDIA_DIR" >/dev/null 2>&1; then
        fail "conflicting executable was accepted: $extra"
    fi
    rm "$MEDIA_DIR/$extra"
done
cp "$MEDIA_DIR/patches/touch-while-driving.sh" "$TEST_TMP/patch.saved"
printf '%s\n' corruption >> "$MEDIA_DIR/patches/touch-while-driving.sh"
if "$REPO_DIR/macos-usb-eject.sh" --verify-only "$MEDIA_DIR" >/dev/null 2>&1; then
    fail "damaged runtime file was accepted"
fi
cp "$TEST_TMP/patch.saved" "$MEDIA_DIR/patches/touch-while-driving.sh"
pass "media verification rejects conflicting launchers, residual patches, and corrupt runtime files"

make_fixture runtime_without_notices
rm "$FIXTURE_USB/LICENSE" "$FIXTURE_USB/NOTICE" "$FIXTURE_USB/SOURCE.txt"
run_installer install || fail "missing release documents prevented runtime installation"
"$REPO_DIR/macos-usb-eject.sh" --verify-only "$FIXTURE_USB" >/dev/null || fail "media verifier required release documents"
assert_file_state patched "$FIXTURE_COMMON"
pass "release documents are packaging requirements and cannot block runtime installation"

FINALIZE_ROOT="$TEST_TMP/finalize"
mkdir -p "$FINALIZE_ROOT/proc" "$FINALIZE_ROOT/sys/class/gpio/Watchdog Disable"
printf '%s\n' 0 > "$FINALIZE_ROOT/sys/class/gpio/Watchdog Disable/value"
printf '%s\n' 'rootfs / ext4 rw,relatime 0 0' > "$FINALIZE_ROOT/proc/mounts"
if ! (
    MZD_TEST_MODE=0
    MZD_ROOT="$FINALIZE_ROOT"
    MZD_MOUNTS_FILE="$FINALIZE_ROOT/proc/mounts"
    MZD_WATCHDOG_VALUE="$FINALIZE_ROOT/sys/class/gpio/Watchdog Disable/value"
    . "$REPO_DIR/usb/lib/touchtune-helpers.sh"
    mount() {
        case "$*" in
            *ro,remount*) printf '%s\n' 'rootfs / ext4 ro,relatime 0 0' > "$MZD_MOUNTS_FILE" ;;
            *) printf '%s\n' 'rootfs / ext4 rw,relatime 0 0' > "$MZD_MOUNTS_FILE" ;;
        esac
    }
    mzd_watchdog_read() {
        if [ ! -e "$FINALIZE_ROOT/read-failed" ]; then
            : > "$FINALIZE_ROOT/read-failed"
            return 1
        fi
        tr -d '\r\n' < "$MZD_WATCHDOG_VALUE"
    }
    if mzd_prepare_mutation; then exit 1; fi
    [ "$MZD_WATCHDOG_DISABLED" = 1 ] || exit 1
    mzd_finalize || exit 1
    [ "$(tr -d '\r\n' < "$MZD_WATCHDOG_VALUE")" = 0 ] || exit 1
    [ "$MZD_WATCHDOG_DISABLED" = 0 ] || exit 1
    [ "$MZD_ROOT_WRITABLE" = 0 ] || exit 1
); then
    fail "watchdog readback failure was not finalized"
fi
pass "failed watchdog readback still triggers verified watchdog and mount cleanup"

printf '%s\n' 'rootfs / ext4 rw,relatime 0 0' > "$FINALIZE_ROOT/proc/mounts"
if (
    MZD_TEST_MODE=0
    MZD_ROOT="$FINALIZE_ROOT"
    MZD_MOUNTS_FILE="$FINALIZE_ROOT/proc/mounts"
    MZD_WATCHDOG_VALUE="$FINALIZE_ROOT/missing-watchdog"
    . "$REPO_DIR/usb/lib/touchtune-helpers.sh"
    mount() { return 0; }
    MZD_ROOT_WRITABLE=1
    mzd_finalize
); then
    fail "false-success read-only remount was accepted"
fi
pass "finalization requires readback of the root read-only mount state"

# Exercise the actual entrypoint's cleanup/traps with production-mode helpers
# and a fake mount command. No real system paths are written by this harness.
awk '
    /^TOUCHTUNE_LOG_ACTIVE=0/ { copying = 1 }
    /^bootstrap_log\(\)/ { exit }
    copying { print }
' "$REPO_DIR/usb/install-patches.sh" > "$TEST_TMP/entrypoint-cleanup.sh"
cat > "$TEST_TMP/cleanup-harness.sh" <<'EOF'
#!/bin/sh
. "$TOUCHTUNE_TEST_CLEANUP"
MZD_TEST_MODE=0
MZD_ROOT="$TOUCHTUNE_TEST_ROOT"
. "$TOUCHTUNE_TEST_HELPER"
TOUCHTUNE_HELPER_LOADED=1
TOUCHTUNE_FINALIZE_NEEDED=1
sync() { return 0; }
mount() {
    printf '%s\n' "$*" >> "$MZD_ROOT/mount-events"
    case "$*" in
        *ro,remount*)
            if [ -e "$MZD_COMMON_TARGET.new" ]; then
                printf '%s\n' 'candidate still present at remount' >> "$MZD_ROOT/cleanup-errors"
                return 1
            fi
            [ "$TOUCHTUNE_TEST_FAILURE" != mount ] || return 1
            printf '%s\n' 'rootfs / rootfs rw 0 0' '/dev/root / ext4 ro,relatime 0 0' > "$MZD_MOUNTS_FILE"
            ;;
        *) printf '%s\n' '/dev/root / ext4 rw,relatime 0 0' > "$MZD_MOUNTS_FILE" ;;
    esac
}
mzd_watchdog_write() {
    if [ "$1" = 0 ]; then
        mzd_root_is_read_only || printf '%s\n' 'watchdog enabled before read-only mount' >> "$MZD_ROOT/cleanup-errors"
        [ "$TOUCHTUNE_TEST_FAILURE" != watchdog ] || return 1
    fi
    printf '%s\n' "$1" > "$MZD_WATCHDOG_VALUE"
}
mzd_prepare_mutation || exit 1
MZD_COMMON_STAGE="$MZD_COMMON_TARGET.new"
printf '%s\n' staged > "$MZD_COMMON_STAGE"
case "$TOUCHTUNE_TEST_END" in
    HUP|INT|TERM) kill -s "$TOUCHTUNE_TEST_END" "$$" ;;
    normal)
        touchtune_cleanup || exit 1
        touchtune_cleanup || exit 1
        : > "$MZD_ROOT/reboot-allowed"
        ;;
    exit) exit 47 ;;
esac
EOF
for end in HUP INT TERM normal exit; do
    make_fixture "cleanup_$end"
    mkdir -p "$FIXTURE_ROOT/proc" "$FIXTURE_ROOT/sys/class/gpio/Watchdog Disable"
    printf '%s\n' 0 > "$FIXTURE_ROOT/sys/class/gpio/Watchdog Disable/value"
    status=0
    TOUCHTUNE_TEST_CLEANUP="$TEST_TMP/entrypoint-cleanup.sh" \
    TOUCHTUNE_TEST_HELPER="$REPO_DIR/usb/lib/touchtune-helpers.sh" \
    TOUCHTUNE_TEST_ROOT="$FIXTURE_ROOT" TOUCHTUNE_TEST_END="$end" TOUCHTUNE_TEST_FAILURE= \
        sh "$TEST_TMP/cleanup-harness.sh" > "$FIXTURE_LOG" 2>&1 || status=$?
    case "$end" in HUP) wanted_status=129 ;; INT) wanted_status=130 ;; TERM) wanted_status=143 ;; normal) wanted_status=0 ;; exit) wanted_status=47 ;; esac
    assert_eq "$status" "$wanted_status" "$end cleanup exit status"
    assert_eq "$(cat "$FIXTURE_ROOT/sys/class/gpio/Watchdog Disable/value")" 0 "$end watchdog cleanup"
    grep -q '^/dev/root / ext4 ro,' "$FIXTURE_ROOT/proc/mounts" || fail "$end root stayed writable"
    [ ! -e "$FIXTURE_ROOT/cleanup-errors" ] || fail "$end cleanup order was unsafe"
    [ ! -e "$FIXTURE_COMMON.new" ] || fail "$end left staging file"
    assert_eq "$(grep -c ro,remount "$FIXTURE_ROOT/mount-events")" 1 "$end cleanup was not idempotent"
done
pass "normal exit and catchable signals clean staging, restore root/watchdog, and preserve status"

for failure in mount watchdog; do
    make_fixture "cleanup_failure_$failure"
    mkdir -p "$FIXTURE_ROOT/proc" "$FIXTURE_ROOT/sys/class/gpio/Watchdog Disable"
    printf '%s\n' 0 > "$FIXTURE_ROOT/sys/class/gpio/Watchdog Disable/value"
    if TOUCHTUNE_TEST_CLEANUP="$TEST_TMP/entrypoint-cleanup.sh" \
        TOUCHTUNE_TEST_HELPER="$REPO_DIR/usb/lib/touchtune-helpers.sh" \
        TOUCHTUNE_TEST_ROOT="$FIXTURE_ROOT" TOUCHTUNE_TEST_END=normal TOUCHTUNE_TEST_FAILURE="$failure" \
        sh "$TEST_TMP/cleanup-harness.sh" > "$FIXTURE_LOG" 2>&1; then
        fail "$failure cleanup failure returned success"
    fi
    [ ! -e "$FIXTURE_ROOT/reboot-allowed" ] || fail "$failure cleanup failure allowed reboot"
done
pass "failed root or watchdog cleanup prevents successful completion"

printf '%s\n' 'rootfs / rootfs ro 0 0' '/dev/root / ext4 rw,relatime 0 0' > "$FINALIZE_ROOT/proc/mounts"
if (
    MZD_TEST_MODE=0
    MZD_ROOT="$FINALIZE_ROOT"
    MZD_MOUNTS_FILE="$FINALIZE_ROOT/proc/mounts"
    . "$REPO_DIR/usb/lib/touchtune-helpers.sh"
    mzd_root_is_read_only
); then
    fail "an earlier read-only mount hid the effective writable root"
fi
pass "root readback evaluates the effective final mount entry"

echo "1..$TEST_COUNT"
