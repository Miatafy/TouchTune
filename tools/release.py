#!/usr/bin/env python3
import hashlib
import io
import os
from pathlib import Path
import stat
import sys
import zipfile


ROOT = Path(__file__).resolve().parent.parent
USB = ROOT / "usb"
LAUNCHER_SOURCE = ROOT / "launcher"
ZIP_TIME = (2026, 6, 18, 17, 37, 52)

# Runtime files are hashed on the USB before installation. Release documents are
# checked here, when packaging, so a missing notice cannot block a CMU repair.
PAYLOAD_FILES = {
    "TOUCHTUNE.ID": 0o644,
    "VERSION": 0o644,
    "LAUNCHER.NAME": 0o644,
    "install-patches.sh": 0o755,
    "jci-autoupdate": 0o644,
    "lib/touchtune-helpers.sh": 0o644,
    "patches/touch-while-driving.sh": 0o644,
}
USB_FILES = {
    **PAYLOAD_FILES,
    "PAYLOAD.SHA256": 0o644,
    "LICENSE": 0o644,
    "NOTICE": 0o644,
    "SOURCE.txt": 0o644,
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def launcher_name():
    raw = (USB / "LAUNCHER.NAME").read_text(encoding="ascii")
    if not raw.endswith("\n") or "\n" in raw[:-1]:
        raise SystemExit("ERROR: LAUNCHER.NAME must contain one safe filename")
    name = raw[:-1]
    fat_forbidden = '<>:"/\\|?*'
    unsafe = any(ord(char) < 32 or char in fat_forbidden for char in name)
    if (
        unsafe
        or name.endswith((" ", "."))
        or len(name.encode("utf-8")) > 255
        or not name.endswith(").up")
    ):
        raise SystemExit("ERROR: launcher filename is invalid")
    return name


def launcher_bytes():
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name in ("main_instructions.ini", "versions.ini"):
            info = zipfile.ZipInfo(name, ZIP_TIME)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.create_version = 20
            info.extract_version = 20
            info.external_attr = 0o600 << 16
            archive.writestr(info, (LAUNCHER_SOURCE / name).read_bytes())
    return output.getvalue()


def manifest_bytes():
    entries = [(name, USB / name) for name in PAYLOAD_FILES]
    entries.append(("@launcher", USB / launcher_name()))
    lines = [f"{digest(path.read_bytes())}  {name}\n" for name, path in entries]
    return "".join(lines).encode("ascii")


def check_manifest():
    if (USB / "PAYLOAD.SHA256").read_bytes() != manifest_bytes():
        raise SystemExit("ERROR: PAYLOAD.SHA256 is stale; run tools/payload-manifest.sh --write and review the new digests")


def write_manifest():
    path = USB / "PAYLOAD.SHA256"
    path.write_bytes(manifest_bytes())
    os.chmod(path, 0o644)
    print(f"Updated {path}; review the new digests before release.")


def release_sources():
    files = USB_FILES | {launcher_name(): 0o644}
    sources = {name: (USB / name, mode) for name, mode in files.items()}
    # Bundle the host helper without keeping a second source copy under usb/.
    sources["macos-usb-eject.sh"] = (ROOT / "macos-usb-eject.sh", 0o755)
    return sources


def check():
    name = launcher_name()
    launcher = USB / name
    files = USB_FILES | {name: 0o644}
    directories = {str(Path(relative).parent) for relative in files} - {"."}
    expected = set(files) | directories
    actual = {
        path.relative_to(USB).as_posix()
        for path in USB.rglob("*")
        if path.name != ".DS_Store"
    }
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise SystemExit(f"ERROR: USB inventory mismatch; missing={missing} extra={extra}")
    for relative in directories:
        path = USB / relative
        if path.is_symlink() or not path.is_dir():
            raise SystemExit(f"ERROR: release directory is invalid: {relative}")
    for relative, (path, mode) in release_sources().items():
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f"ERROR: release file is not regular: {relative}")
        actual_mode = stat.S_IMODE(path.stat().st_mode)
        if actual_mode != mode:
            raise SystemExit(f"ERROR: {relative} mode is {actual_mode:o}, expected {mode:o}")
    if launcher.read_bytes() != launcher_bytes():
        raise SystemExit("ERROR: checked-in launcher does not match its public source")
    check_manifest()
    if (USB / "TOUCHTUNE.ID").read_text(encoding="ascii") != "touchtune-oss-v2\n":
        raise SystemExit("ERROR: media identity is invalid")
    if (USB / "jci-autoupdate").read_bytes():
        raise SystemExit("ERROR: jci-autoupdate must be empty")
    for name in ("LICENSE", "NOTICE", "VERSION"):
        if (USB / name).read_bytes() != (ROOT / name).read_bytes():
            raise SystemExit(f"ERROR: root and USB {name} differ")
    version = (ROOT / "VERSION").read_text(encoding="ascii").strip()
    expected_source = f"TouchTune {version} source code\nhttps://github.com/Miatafy/TouchTune\n"
    if (USB / "SOURCE.txt").read_text(encoding="ascii") != expected_source:
        raise SystemExit("ERROR: SOURCE.txt does not match VERSION")
    print("TouchTune release inputs are reproducible and complete.")


def write_launcher():
    path = USB / launcher_name()
    path.write_bytes(launcher_bytes())
    os.chmod(path, 0o644)
    print(f"Updated {path}")


def package(output_name):
    check()
    output = Path(output_name).resolve()
    if not output.parent.is_dir():
        raise SystemExit(f"ERROR: output directory does not exist: {output.parent}")
    with zipfile.ZipFile(output, "w") as archive:
        for relative, (path, mode) in sorted(release_sources().items()):
            info = zipfile.ZipInfo(relative, ZIP_TIME)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, path.read_bytes())
    checksum = digest(output.read_bytes())
    output.with_name(output.name + ".sha256").write_text(f"{checksum}  {output.name}\n", encoding="ascii")
    print(f"Created {output}")
    print(f"SHA-256: {checksum}")


def usage():
    raise SystemExit("Usage: tools/release.py check | check-manifest | write-manifest | write-launcher | package OUTPUT.zip")


if len(sys.argv) == 2 and sys.argv[1] == "check":
    check()
elif len(sys.argv) == 2 and sys.argv[1] == "check-manifest":
    check_manifest()
    print("TouchTune payload manifest is current.")
elif len(sys.argv) == 2 and sys.argv[1] == "write-manifest":
    write_manifest()
elif len(sys.argv) == 2 and sys.argv[1] == "write-launcher":
    write_launcher()
elif len(sys.argv) == 3 and sys.argv[1] == "package":
    package(sys.argv[2])
else:
    usage()
