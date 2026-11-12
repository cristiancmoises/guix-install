#!/usr/bin/env python3
"""Recreate the CC-BY-SA ASCII adaptation from the bundled official logo PNG."""

import subprocess
from pathlib import Path

assets = Path(__file__).resolve().parents[1] / "assets"
raw = subprocess.check_output(
    [
        "convert",
        str(assets / "guix-logo.png"),
        "-resize",
        "36x16!",
        "-depth",
        "8",
        "rgba:-",
    ]
)
lines = [
    "".join(" #"[raw[(y * 36 + x) * 4 + 3] >= 100] for x in range(36)).rstrip()
    for y in range(16)
]
(assets / "guix-logo.txt").write_text("\n".join(lines).strip("\n") + "\n")
