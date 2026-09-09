# TouchTune developer notes

TouchTune owns one file, `Common.js`, and two NVRAM keys,
`bus_bcm_speed_restriction` and `lvds_speed_restriction`. Keep installation and
removal limited to those changes.

## Recognizing the file

Firmware must be `74.00.324` or `74.00.324A`. The production profile in
`usb/lib/touchtune-helpers.sh` recognizes these complete file contents:

| State | Bytes, for reference | SHA-256 |
| --- | ---: | --- |
| Stock | 98,348 | `376b30a46366a543122956d7feb1b44f147425015837a4d83fedf12a67943351` |
| TouchTune | 98,375 | `019eba18e8d629ddb1d55563aab138ce1eb3329fab67b71d9b4178377cf9d9ce` |

The full digest verifies the content, including its final registration and the
one changed line. Runtime anchor-count and tail checks are unnecessary once
that digest matches. File mode and ownership are checked separately.

## Installation and rollback

1. Verify the helper before sourcing it, then verify the complete runtime
   payload before loading the patch.
2. Recognize the live file, read both settings, and validate or create the backup.
3. Build one candidate beside `Common.js`, check its digest and permissions,
   and flush it. This happens before changing NVRAM.
4. Set and read back both settings, skipping values that already match.
5. Rename the complete candidate over `Common.js`, flush the directory, and
   verify the live file and settings again.
6. Finalize writes, restore the read-only root mount and watchdog, then request
   Mazda's `SafeReboot`.

A transaction failure restores and verifies the entry file and setting values.
Catchable termination follows the same cleanup path. Cleanup also runs on normal
exit; a cleanup or rollback failure prevents the installer from requesting a
restart. There is no raw-reboot fallback.

There is no required transaction receipt. Logs describe what happened; the live
file and settings determine what the next run can do. Old receipt files are
ignored. An interrupted rename leaves a complete old or new file, but neither
shell traps nor atomic rename guarantee recovery from power loss, failed flash,
or an interrupted NVRAM commit. Host tests do not model those hardware effects.

## Private backup

`/data/touchtune/backups/common-js` contains the stock file, metadata describing
its profile and original settings, and a digest of that metadata. The existing
`touchtune-backup-v3` format remains readable. It is built in a temporary
directory, fully validated and flushed, then renamed into place. A failed write
must never publish an incomplete backup. Existing backups are verified and
never overwritten.

For an exact 1.1 patched file without a private backup, reversing the known line
change must produce the exact stock digest. The original 1.1 installer used
factory `enable` values for removal, so migration preserves that behavior.
An initial stock install saves the actual entry values instead. TouchTune never
reads a shared backup tree or redistributes a complete Mazda `Common.js`.

## USB and release package

The launcher selects exactly one volume with the TouchTune identity marker.
`PAYLOAD.SHA256` covers the executable scripts, launcher, and runtime metadata.
Unexpected patch scripts or conflicting launchers are refused. Harmless files
and system directories on the USB do not invalidate the installer.

`tools/release.py` defines the release contents, produces the manifest, and
builds reproducible ZIPs. License, attribution, and source information are
required when packaging; their contents do not gate a running installation.
This detects accidental damage and mixed releases, not deliberate tampering
with both the verifier and its manifest.

## Development checks

After changing runtime files, regenerate the manifest and run the tests:

```sh
./tools/payload-manifest.sh --write
./tests/run.sh
python3 tools/release.py package /tmp/TouchTune-1.2.0.zip
```

The host tests use disposable file trees. They cover install, repair, removal,
1.1 migration, backup validation, damaged files/media, failed writes and
setting changes, interruption, rollback, and cleanup. They never contact a CMU.

Before releasing changed installer bytes, test the packaged contents on the
bench. Record the starting firmware, file hashes, settings, watchdog and root
mount state; verify installation and removal across managed restarts; confirm
the stock file and original settings return. Keep the package checksum and
results with the test report. Do not inject storage failures or cut power on
the physical CMU; use fixtures for destructive failure cases.

See the [September 9 bench report](docs/bench-validation-2026-09-09.md) for the
tested 1.2 package and results.
