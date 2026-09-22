# TouchTune 1.2.1 bench validation — September 22, 2026

TouchTune 1.2.1 passed install and removal on the 2019 CX-5 bench CMU running
NA `74.00.324A`, with `Common.js` at Mazda's stock ownership `uid/gid 1000`.
The CMU finished each cycle at the normal home screen with the expected file,
settings, watchdog enabled, and root read-only. No installer residue remained.

## Why this run differs from September 9

1.2.0 required `Common.js` to be `775 / 0 / 0`. That value came from this bench,
where earlier development had left the file root-owned. Mazda's firmware
installs the GUI tree as `1000 / 1000` (every sibling in
`/jci/gui/common/js/` and 4,533 of 4,581 files under `/jci/gui` on this unit),
so 1.2.0 refused stock cars with "Common.js permissions do not match the
supported profile" (GitHub #3, #4, #5, #6 and three support emails).

Before this run the bench file was returned to `1000:1000` so the cycle
exercises the failing case. 1.2.1 records the live file's mode and ownership at
entry and reproduces them on every replacement.

## Tested package

`TouchTune-1.2.1.zip`, built with `tools/release.py`:

```text
SHA-256: 3397a541aacebb1c0a4476c12eeb3479a643990ba67521745c7de47ad072dc68
```

No USB stick was on the bench, so the package contents were staged under
`/data/touchtune-bench-1.2.1` and all 13 files were compared byte-for-byte
with the ZIP before use. Install and removal used the explicit
`touch-while-driving` and `--restore` actions over SSH. The launcher and USB
detection code are unchanged from 1.2.0.

## Checks before deployment

- All 45 host regression tests passed, including the new cases for attribute
  inheritance, absent and malformed NVRAM keys, and failed NVRAM commits.
- `tools/release.py check` reported the release inputs reproducible and complete.

## Physical cycle

| Check | Before install | After install and reboot | After removal and reboot |
| --- | --- | --- | --- |
| `Common.js` | Exact stock digest | Exact TouchTune digest | Exact stock digest |
| Bytes | 98,348 | 98,375 | 98,348 |
| Mode / UID / GID | 775 / 1000 / 1000 | 775 / 1000 / 1000 | 775 / 1000 / 1000 |
| BCM restriction | enable | disable | enable |
| LVDS restriction | enable | disable | enable |
| Watchdog disabled flag | 0 | 0 | 0 |
| Effective root mount | read-only | read-only | read-only |

Both actions completed through Mazda's `SafeReboot`; distinct boot IDs
(`c9c0a3c3…` → `43bf71b1…` → `db4daf06…`) verified both restarts. The installer
logged the recorded attributes at entry:

```text
[touchtune] Common.js is the exact stock file with mode=775 uid=1000 gid=1000; replacements will keep these attributes
[touchtune] validated existing write-once TouchTune backup
```

The existing `touchtune-backup-v3` bundle from the 1.2.0 run was validated and
reused unchanged (all three digests identical before, during, and after).
Recorded hashes for `version.ini`, `GuiFramework.js`, `sm.conf`, `sm_WCP.conf`,
and `start_network.sh` matched the starting values. The staging directory,
installer guard, and candidate file were absent at the end. Compositor captures
after each reboot showed the normal Mazda home screen.

## Not covered here

The bench has both speed-restriction NVRAM keys, so the absent-key path from
GitHub #3 was validated only in host fixtures. Root-owned `Common.js` (units
already modified by 1.2.0) was not re-run on this cycle; 1.2.1 preserves that
ownership by the same code path. Physical panel touch while driving, power
loss, and other firmware or vehicle configurations were not tested.
