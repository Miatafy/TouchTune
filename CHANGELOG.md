# Changelog

## 1.2.0 (2026-09-09)

- Replace the in-place edit with one complete, flushed replacement, checked
  against the expected SHA-256 before and after atomic publication.
- Keep verified private backups and restore only TouchTune's file and settings.
  Validate the complete backup before publishing it so failed writes can retry.
- Check NVRAM changes, skip unchanged values, and roll back failed transactions.
- Restore the root mount and watchdog on exit and catchable interruption, and
  use Mazda's managed restart after successful cleanup.
- Verify runtime USB files, select one identified TouchTune volume, and reject
  conflicting scripts or launchers while accepting harmless USB contents.
- Add reproducible packaging, bundled license/source information, and host
  regression tests for failed writes, interruptions, rollback, and USB damage.
- Validate the packaged install and removal across managed reboots on the
  74.00.324A bench CMU, restoring the original file and settings.

## 1.1.0 (2026-08-18)

- Add a reusable USB action dialog with install, repair, and removal choices.
- Add firmware gating for the `74.00.324` / `74.00.324A` family.

## 1.0.0

- Initial public TouchTune release.
