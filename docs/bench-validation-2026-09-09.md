# TouchTune 1.2 bench validation — September 9, 2026

The simplified installer passed install and removal on the 2019 CX-5 bench CMU
running NA `74.00.324A`. The CMU finished at the normal home screen with its
original file and settings, watchdog enabled, and root read-only. The USB was
synced and unmounted after testing.

## Tested package

`TouchTune-1.2.0.zip`, built with `tools/release.py`:

```text
SHA-256: 8ec6b8993808ef0d3b22ee9941e13a1de6b47f3ff71dabe411a5ba6d853b5d36
```

All 13 packaged files were read back from the physical FAT32 USB and compared
byte-for-byte with the ZIP, both before installation and after removal. The ZIP
includes the standalone macOS cleanup helper.

## Checks before deployment

- All 39 host regression tests passed, along with shell syntax, release-input,
  media-verification, and reproducible-package checks.
- An independent ARM-container audit used the firmware's BusyBox 1.19.2 and
  OpenSSL with the actual supported `Common.js`. Lifecycle, repeated actions,
  eight failure/retry scenarios, and TERM-triggered rollback after publication
  passed. That audit preceded the final popup wording adjustment; the final
  package received the full host suite and physical checks below.
- Independent implementation reviews found and resolved cleanup ordering and
  unreadable-NVRAM rollback issues before deployment.

## Physical cycle

The bench initially showed a startup overlay despite stable uptime. One normal
managed restart, with the old USB trigger temporarily disabled, returned it to
the home screen before the new package was staged.

| Check | Before install | After install and reboot | After removal and reboot |
| --- | --- | --- | --- |
| `Common.js` | Exact stock digest | Exact TouchTune digest | Exact stock digest |
| Bytes | 98,348 | 98,375 | 98,348 |
| Mode / UID / GID | 775 / 0 / 0 | 775 / 0 / 0 | 775 / 0 / 0 |
| BCM restriction | enable | disable | enable |
| LVDS restriction | enable | disable | enable |
| Watchdog disabled flag | 0 | 0 | 0 |
| Effective root mount | read-only | read-only | read-only |

Install and removal used the final package's explicit `touch-while-driving` and
`--restore` actions over SSH. Both completed through the installer's managed
reboot path; distinct boot IDs verified both restarts. The native USB launcher
automatically reopened the correct action dialog after each reboot. The install
and repair/remove dialogs rendered at 800×480. Native Cancel was selected through
the virtual mouse input and logged cancellation without changing system state.

The existing backup-v3 bundle and old diagnostic receipt remained byte-for-byte
unchanged. Recorded hashes for `version.ini`, `GuiFramework.js`, `sm.conf`,
`sm_WCP.conf`, and `start_network.sh` also matched the starting values. No
installer guard remained after cleanup. A final compositor capture showed the
normal Mazda home screen.

This run validates the installer on this unit. Destructive write failures and
signals during mutation were tested in disposable fixtures, not on the physical
CMU. Physical panel touch, driving behavior, cold power loss, and other firmware
or vehicle configurations were not tested here.
