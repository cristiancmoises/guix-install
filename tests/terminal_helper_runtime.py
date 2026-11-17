"""Build the generated terminal helper with an ordinary Guix daemon.

Run as an unprivileged account on a disposable, qualified Guix host. Dependencies
may be substituted; the generated package runs its upstream check phase.
"""

import argparse
import gzip
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guix_installer import core


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guix", default="guix")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("use an unprivileged Guix client account")
    with tempfile.TemporaryDirectory(prefix="terminal-helper-") as temporary:
        root = Path(temporary)
        recipe = root / "helper.scm"
        recipe.write_text(
            "(use-modules (guix packages) (guix gexp) (guix download) "
            "(guix build-system gnu) (gnu packages base) (gnu packages bash) "
            "(gnu packages gawk) (gnu packages man) "
            "((guix licenses) #:prefix license:))\n"
            + core._terminal_helper_definition()
            + "\nguix-install-xdg-terminal-exec\n",
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                args.guix,
                "build",
                "--no-offload",
                "--no-grafts",
                "--max-jobs=1",
                "--cores=1",
                "--timeout=120",
                "--file=" + str(recipe),
            ],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            timeout=180,
        )
        # Rebuild the requested output even if the first build was substituted.
        # Dependencies stay cached; Guix compares the rebuilt target output.
        subprocess.run(
            [
                args.guix,
                "build",
                "--check",
                "--no-offload",
                "--no-grafts",
                "--max-jobs=1",
                "--cores=1",
                "--timeout=60",
                "--file=" + str(recipe),
            ],
            check=True,
            timeout=90,
        )
        output = Path(result.stdout.strip())
        if not output.is_absolute() or not output.resolve().is_relative_to(
            "/gnu/store"
        ):
            raise RuntimeError("helper build must return one store output")
        binary = output / "bin/xdg-terminal-exec"
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError("terminal helper was not installed executable")
        for item in ("share/xdg-terminal-exec/xdg-terminals.list",):
            if not (output / item).is_file():
                raise RuntimeError(f"missing installed helper file: {item}")
        man = output / "share/man/man1/xdg-terminal-exec.1"
        if man.is_file():
            manual = man.read_bytes()
        elif man.with_suffix(".1.gz").is_file():
            manual = gzip.decompress(man.with_suffix(".1.gz").read_bytes())
        elif man.with_suffix(".1.zst").is_file():
            manual = subprocess.run(
                ["zstd", "-dc", str(man.with_suffix(".1.zst"))],
                stdout=subprocess.PIPE,
                check=True,
                timeout=5,
            ).stdout
        else:
            raise RuntimeError("missing installed terminal helper manual")
        if b"XDG-TERMINAL-EXEC" not in manual.upper():
            raise RuntimeError("installed manual has incorrect contents")
        config = root / "config"
        data = root / "data"
        config.mkdir()
        (data / "applications").mkdir(parents=True)
        (config / "xdg-terminals.list").write_text("fixture.desktop\n")
        (data / "applications/fixture.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Fixture terminal\n"
            f"Exec={sys.executable}\nCategories=TerminalEmulator;\n"
            "X-TerminalArgExec=--\n"
        )
        environment = {
            **os.environ,
            "HOME": str(root),
            "XDG_CONFIG_HOME": str(config),
            "XDG_CONFIG_DIRS": str(root / "empty-config"),
            "XDG_DATA_HOME": str(data),
            "XDG_DATA_DIRS": str(root / "empty-data"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_CURRENT_DESKTOP": "",
        }
        selected = subprocess.run(
            [str(binary), "--print-id"],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            check=True,
            timeout=5,
        ).stdout.strip()
        if selected != "fixture.desktop":
            raise RuntimeError("installed helper did not select the fixture terminal")
        print(
            "PASS: generated Guix helper package built, checked and installed",
            flush=True,
        )


if __name__ == "__main__":
    main()
