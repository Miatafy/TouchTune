# TouchTune by Miatafy

[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)
[![Release: v1.2.1](https://img.shields.io/badge/release-v1.2.1-brightgreen.svg)](VERSION)

TouchTune keeps the Mazda Connect touchscreen enabled while the car is moving.
It is a free, open-source USB installer for **Gen 6 Mazda Connect
74.00.324 / 74.00.324A**. There is no account, desktop app, or configuration.

![TouchTune install prompt on Mazda Connect](docs/touchtune-install-prompt.png)

## Install

1. Check your firmware in **Settings → System → About**. It must be
   **74.00.324** or **74.00.324A**. See the [firmware guide](https://miatafy.com/mazda-connect/check-firmware/).
2. Prepare an empty USB stick formatted **FAT32 with an MBR partition map**.
   [USB requirements](https://miatafy.com/support/usb-requirements/)
3. Extract the release ZIP onto the USB root. From a source checkout, copy the
   **contents** of `usb/`, including the unusually named `.up` file. Do not merge
   releases or copy the enclosing folder.
4. Eject the stick. On macOS, run the helper included in the release:
   `sh /Volumes/NAME/macos-usb-eject.sh /Volumes/NAME`. It removes Finder
   sidecars, checks the installer files, and ejects the stick. From a source
   checkout, run `sh macos-usb-eject.sh /Volumes/NAME` instead.
5. With the car on, insert the stick and choose **INSTALL** when the TouchTune
   dialog appears. Leave it connected while installation runs.
6. Remove the USB when the completion message asks you to. Mazda Connect restarts
   to load the change.

Keep the USB: the same stick can repair or remove TouchTune later.

> The `$(...).up` filename is how the Mazda update scanner starts the installer.
> Copy it along with the other files; do not type its name into a shell.

## Repair or remove

Insert the same USB again. Choose **REPAIR** to reapply TouchTune, **REMOVE** to
restore its original file and settings, or **CANCEL** to leave things as they are.

TouchTune changes only `Common.js` and the two factory speed-restriction settings.
Its backup lives under `/data/touchtune/backups/common-js`. It does not restore
files from other tweaks or use ScreenTune's backups. An exact TouchTune 1.1
installation can be upgraded or removed with this USB.

## If installation stops

Read the on-screen message and keep `touchtune.log` from the USB. A damaged
download, unsupported firmware, an unexpected `Common.js`, or an invalid backup
stops installation. A failed install does not request a restart.

For a USB validation error, prepare a fresh stick from the release ZIP. If the log
reports an unexpected system file or backup, preserve it for diagnosis rather
than replacing files on the CMU. If no dialog appears, check the USB layout and
remove other USB storage devices before trying again.

## What changed in 1.2.1

1.2.0 refused to install on most cars with "Common.js permissions do not match
the supported profile". The installer expected the file ownership of the test
bench, which had been changed by earlier tools; Mazda's own firmware uses a
different owner. 1.2.1 keeps whatever mode and ownership the car already has,
on both installation and removal. It also handles units where Mazda has not yet
created the speed-restriction settings, and logs exactly what it found when a
check fails.

## What changed in 1.2

The installer now builds and checks a complete replacement before touching the
live file. It saves a private, verified backup, checks that setting changes took
effect, and rolls back a failed transaction. Cleanup restores the watchdog and
read-only root mount before requesting Mazda's managed restart.

These changes address cases where the old installer could report success after
an incomplete write. They cannot make failing storage or power loss harmless.
See the [changelog](CHANGELOG.md) and [developer notes](SAFETY.md) for details.

## Compatibility

TouchTune supports the Gen 6 `74.00.324` / `74.00.324A` firmware family and the
exact stock or TouchTune-patched `Common.js` described in the developer notes.
It refuses other versions and unknown modifications to that file. The About
screen sometimes omits the trailing `A`.

The inspected NA and EU firmware copies contain the same supported file. Bench
testing uses a 2019 CX-5 CMU with NA 74.00.324A; this does not establish support
for every vehicle or region. [Vehicle compatibility](https://miatafy.com/compatibility/supported-vehicles/)

## Contributing

The installer is shell code in `usb/install-patches.sh`,
`usb/patches/touch-while-driving.sh`, and `usb/lib/touchtune-helpers.sh`.
Run `./tests/run.sh` for disposable host tests. The [developer notes](SAFETY.md)
explain file replacement, backups, packaging, and bench validation.
The [1.2 bench report](docs/bench-validation-2026-09-09.md) records the tested
package and install/removal results.

## License

GPL-3.0-or-later, with no warranty. TouchTune builds on the Mazda Connect
community's MZD-AIO work; see [LICENSE](LICENSE), [NOTICE](NOTICE), and
[DISCLAIMER.md](DISCLAIMER.md). It disables a factory speed lockout: understand
the change and keep your attention on driving.
