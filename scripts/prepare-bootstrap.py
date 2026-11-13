#!/usr/bin/env python3
"""Pin the launcher to an already committed, verified runtime source set."""

import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.search(
    r'__version__ = "([^"]+)"',
    (ROOT / "guix_installer/__init__.py").read_text(),
).group(1)
FILES = [
    "installer.sh",
    "install.sh",
    "run.py",
    "channel.scm",
    "channels.scm",
    "LICENSE",
    "guix_installer/__init__.py",
    "guix_installer/__main__.py",
    "guix_installer/core.py",
    "guix_installer/branding.py",
    "guix_installer/channels.py",
    "guix_installer/kernels.py",
    "guix_installer/windows.py",
    "guix_installer/check-daemon.scm",
    "assets/guix-logo.svg",
    "assets/guix-logo.png",
    "assets/guix-logo.txt",
    "assets/guix-logo.ico",
    "assets/securityops.defconfig",
    "assets/provenance.json",
    "assets/README.md",
    "guix_installer/gui.py",
    "guix_installer/i18n.py",
    "windows_main.py",
    "vendor/guix-install.sh",
    "vendor/provenance.json",
]


def main():
    commit = (
        sys.argv[1]
        if len(sys.argv) > 1
        else subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip()
    )
    if not re.fullmatch("[0-9a-f]{40}", commit):
        raise SystemExit("Expected a full commit SHA")
    files = {}
    for name in FILES:
        data = subprocess.check_output(["git", "show", f"{commit}:{name}"], cwd=ROOT)
        if data != (ROOT / name).read_bytes():
            raise SystemExit(
                f"Uncommitted runtime changes in {name}; commit and verify first"
            )
        files[name] = hashlib.sha256(data).hexdigest()
    template = (ROOT / "scripts/bootstrap-template.sh").read_text()
    (ROOT / "bootstrap.sh").write_text(
        template.replace("@@COMMIT@@", commit)
        .replace("@@FILES@@", repr(files))
        .replace("@@VERSION@@", VERSION)
    )
    (ROOT / "bootstrap.sh").chmod(0o755)
    print("Pinned payload:", commit)


if __name__ == "__main__":
    main()
