"""Offline branding derived from the attributed official Guix artwork."""

import shutil
from pathlib import Path


def terminal_logo():
    if shutil.get_terminal_size().columns < 44:
        return "GNU Guix"
    return (
        (Path(__file__).resolve().parents[1] / "assets/guix-logo.txt")
        .read_text()
        .rstrip()
    )
