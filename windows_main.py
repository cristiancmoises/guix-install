"""Windows migration entrypoint: download GNU Guix and write it to a disk.

Run as Administrator. Standard library only, so a single PyInstaller binary
and a thin WiX MSI are the whole Windows distribution.
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

from guix_installer import __version__, windows
from guix_installer.i18n import tr


def parser():
    result = argparse.ArgumentParser(
        description="GNU Guix Installer for Windows — bootable image writer"
    )
    result.add_argument("--version", action="version", version=__version__)
    result.add_argument(
        "command",
        nargs="?",
        default="list",
        choices=["image", "list", "doctor"],
    )
    result.add_argument("--lang", choices=["en", "pt-BR"], default="en")
    result.add_argument("--disk", type=int, help="physical disk number to write")
    result.add_argument("--image", help="local image file to write")
    result.add_argument("--image-url", help="image URL (default: GNU FTP)")
    result.add_argument(
        "--sha256", help="publisher SHA-256 required for a custom image URL"
    )
    result.add_argument(
        "--verify",
        action="store_true",
        default=True,
        help="read back and compare (always enabled)",
    )
    result.add_argument("--json", action="store_true", help="machine-readable output")
    return result


def progress(label, done, total):
    percent = 100.0 * done / total if total else 0.0
    print(f"\r{label}: {percent:5.1f}%  ({done}/{total})", end="", flush=True)
    if done >= total:
        print()


def choose_disk(language):
    disks = windows.list_disks()
    if not disks:
        raise windows.WindowsError(tr("windows_no_disks", language))
    for disk in disks:
        print(
            f"  {disk.get('Number')}: {disk.get('FriendlyName', '?')}  "
            f"{int(disk.get('Size') or 0) / 1024**3:.1f} GiB  "
            f"{disk.get('BusType', '?')}"
        )
    return disks


def write(language, disk_number, image_path, verify):
    windows.require_admin()
    disks = choose_disk(language)
    target = next((disk for disk in disks if disk.get("Number") == disk_number), None)
    if target is None:
        raise windows.WindowsError(f"Disk {disk_number} not found. Re-run list.")
    target = windows.inspect_writable_disk(disk_number)
    confirmation = input(tr("windows_disk_confirm", language)).strip()
    if confirmation != str(disk_number):
        raise windows.WindowsError("Cancelled. Nothing was written.")
    print(tr("windows_writing", language))
    windows.write_image(
        image_path,
        disk_number,
        verify=verify,
        expected_disk=target,
        progress=lambda done, total: progress(
            tr("windows_writing", language), done, total
        ),
    )
    if verify:
        print(tr("windows_verifying", language))
    print(tr("windows_done", language))


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        windows.require_windows()
        if args.command == "list":
            if args.json:
                print(json.dumps(windows.list_disks(), indent=2))
            else:
                choose_disk(args.lang)
        elif args.command == "doctor":
            findings = {
                "Windows": os.name == "nt",
                "Administrator": windows.is_admin(),
                "PowerShell": shutil.which("powershell") is not None,
            }
            if args.json:
                print(json.dumps(findings, indent=2))
            else:
                for name, ok in findings.items():
                    print(f"{'OK     ' if ok else 'MISSING'}  {name}")
        else:
            if args.disk is None:
                raise windows.WindowsError("Pass --disk NUMBER to write an image.")
            windows.require_admin()
            if args.image:
                image_path = str(Path(args.image).resolve())
                write(args.lang, args.disk, image_path, args.verify)
            else:
                with tempfile.TemporaryDirectory(prefix="guix-install-") as directory:
                    image_path = str(Path(directory) / "guix-system-install.iso")
                    print(tr("windows_download", args.lang))

                    def report_progress(done, final):
                        progress(tr("windows_download", args.lang), done, final)

                    if args.image_url:
                        windows.download_image(
                            args.image_url,
                            image_path,
                            expected_sha256=args.sha256,
                            progress=report_progress,
                        )
                    else:
                        windows.download_default_image(
                            image_path, progress=report_progress
                        )
                    print()
                    write(args.lang, args.disk, image_path, args.verify)
        return 0
    except (windows.WindowsError, OSError, ValueError) as exc:
        print(tr("error", args.lang) + ": " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
