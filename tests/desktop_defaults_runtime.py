"""Exercise generated preferences with native desktop tools in an isolated HOME.

Run on a disposable Linux test environment with gio, exo-open/xfce-open,
kreadconfig6, GHC/XMonad and xdg-terminal-exec. Supply the unmodified application
desktop files from the same channel pin used to evaluate the generated system.
Terminal/browser executables are replaced with argv recorders; no GUI application
or external URL is opened. This tests launch integration, not terminal rendering.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guix_installer import core


def command(argv, env, *, timeout=15):
    result = subprocess.run(
        argv,
        env=env,
        cwd=env["HOME"],
        text=True,
        encoding="utf-8",
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(
            f"{argv[0]} exited {result.returncode}: "
            f"{result.stdout[-2000:]}{result.stderr[-2000:]}"
        )
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entries", type=Path, required=True)
    parser.add_argument("--terminal-helper", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() == 0:
        parser.error("run as an unprivileged user in a disposable Linux environment")
    helper = args.terminal_helper.resolve(strict=True)
    tools = {name: shutil.which(name) for name in ("gio", "kreadconfig6", "ghc")}
    xfce = shutil.which("xfce-open") or shutil.which("exo-open")
    if not all(tools.values()) or not xfce:
        parser.error(
            "gio, kreadconfig6, GHC/XMonad and xfce-open/exo-open are required"
        )

    with tempfile.TemporaryDirectory(prefix="desktop-defaults-") as temporary:
        root = Path(temporary)
        home = root / "home"
        binary = root / "bin"
        data = home / ".local/share"
        apps = data / "applications"
        runtime = root / "runtime"
        for path in (home, binary, apps, runtime):
            path.mkdir(parents=True, exist_ok=True)
        runtime.chmod(0o700)
        record = root / "argv.jsonl"
        env = {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(data),
            "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_CONFIG_DIRS": str(root / "empty-config"),
            "XDG_DATA_DIRS": str(root / "empty-data"),
            "XDG_RUNTIME_DIR": str(runtime),
            "LC_ALL": "C.UTF-8",
            "PATH": str(binary) + os.pathsep + os.environ.get("PATH", ""),
            "RECORD_PATH": str(record),
        }
        # A private test bus/display may be provided by dbus-run-session/Xvfb.
        for name in ("DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
            if name in os.environ:
                env[name] = os.environ[name]
        recorder = binary / "record-launch"
        recorder.write_text(
            f"#!{sys.executable}\nimport json,os,sys\n"
            "with open(os.environ['RECORD_PATH'],'a',encoding='utf-8') as f:\n"
            " f.write(json.dumps([os.path.basename(sys.argv[0]),sys.argv[1:]],"
            "ensure_ascii=False)+'\\n')\n",
            encoding="utf-8",
        )
        recorder.chmod(0o755)
        (binary / "xdg-terminal-exec").symlink_to(helper)
        for name, desktop_id in core.TERMINAL_DESKTOP_IDS.items():
            (binary / name).symlink_to(recorder)
            entry = (args.entries / desktop_id).read_text(encoding="utf-8")
            # Preserve every original Exec argument, category and terminal key.
            entry = re.sub(
                r"(?m)^(Exec|TryExec)=\S+",
                lambda match, name=name: f"{match[1]}={binary / name}",
                entry,
            )
            (apps / desktop_id).write_text(entry, encoding="utf-8")
        for name, desktop_id in core.BROWSER_DESKTOP_IDS.items():
            executable = core.BROWSER_BINARIES[name]
            if not (binary / executable).exists():
                (binary / executable).symlink_to(recorder)
            entry = (args.entries / desktop_id).read_text(encoding="utf-8")
            entry = re.sub(
                r"(?m)^(Exec|TryExec)=\S+",
                lambda match, executable=executable: (
                    f"{match[1]}={binary / executable}"
                ),
                entry,
            )
            (apps / desktop_id).write_text(entry, encoding="utf-8")

        generation = 0
        timestamp_base = int(time.time()) - 86400

        def preferences(desktop, terminal="wezterm", browser="torbrowser"):
            nonlocal generation
            options = core.Options(
                mode="system",
                disk="/dev/example",
                desktop=desktop,
                terminals=tuple(core.TERMINAL_DESKTOP_IDS),
                default_terminal=terminal,
                browsers=tuple(core.BROWSER_DESKTOP_IDS),
                default_browser=browser,
            )
            core.validate_options(options)
            for target, content in core._application_skeletons(options):
                path = home / target
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            # Upstream hashes ls -l output (minute granularity). Exercise cache
            # refresh with distinct displayed minutes, not nanosecond timestamps.
            generation += 1
            stamp = timestamp_base + generation * 120
            for path in (home / ".config").rglob("*"):
                if path.is_file():
                    os.utime(path, (stamp, stamp))

        def launch(argv):
            record.unlink(missing_ok=True)
            command(argv, env)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if record.exists():
                    lines = record.read_text(encoding="utf-8").splitlines()
                    if lines:
                        return json.loads(lines[-1])
                time.sleep(0.02)
            raise AssertionError(f"no recorded launch from {argv[0]}")

        payload = ["printf", "two words", "ação", "$(touch SHOULD_NOT_EXIST)", "a;b"]
        prefixes = {
            "wezterm": ["start", "--cwd", ".", "--"],
            "kitty": ["--"],
            "foot": ["--"],
            "alacritty": ["-e"],
        }
        for terminal in core.TERMINAL_DESKTOP_IDS:
            preferences("gnome", terminal)
            actual = launch([str(helper), *payload])
            assert actual == [terminal, prefixes[terminal] + payload], actual
            desktop = root / "terminal-payload.desktop"
            desktop.write_text(
                "[Desktop Entry]\nType=Application\nName=Terminal fixture\n"
                "Terminal=true\nExec=/usr/bin/true\n",
                encoding="utf-8",
            )
            actual = launch([tools["gio"], "launch", str(desktop)])
            assert actual == [terminal, prefixes[terminal] + ["/usr/bin/true"]], actual
        print("PASS native terminal selection, argv preservation and gio Terminal=true")
        assert not (home / "SHOULD_NOT_EXIST").exists()

        for browser, desktop_id in core.BROWSER_DESKTOP_IDS.items():
            preferences("gnome", browser=browser)
            for mime in (
                "x-scheme-handler/http",
                "x-scheme-handler/https",
                "text/html",
                "application/xhtml+xml",
            ):
                output = command([tools["gio"], "mime", mime], env)
                assert desktop_id in output.splitlines()[0], output
        print("PASS native browser MIME defaults, including entries without MimeType")

        for terminal in ("wezterm", "kitty", "alacritty"):
            preferences("xfce", terminal)
            actual = launch([xfce, "--launch", "TerminalEmulator"])
            expected = ["start"] if terminal == "wezterm" else []
            assert actual == [terminal, expected], actual
        url = (
            "https://example.invalid/ação?q=two words&literal=$(touch SHOULD_NOT_EXIST)"
        )
        actual = launch([xfce, "--launch", "WebBrowser", url])
        assert actual == [core.BROWSER_BINARIES["torbrowser"], [url]], actual
        print("PASS native XFCE terminal/browser helpers with literal URL arguments")

        for terminal, expected in core.TERMINAL_COMMANDS.items():
            preferences("kde", terminal)
            for key, value in (
                ("TerminalApplication", expected),
                ("TerminalService", core.TERMINAL_DESKTOP_IDS[terminal]),
            ):
                actual = command(
                    [
                        tools["kreadconfig6"],
                        "--file",
                        "kdeglobals",
                        "--group",
                        "General",
                        "--key",
                        key,
                    ],
                    env,
                ).strip()
                assert actual == value, (key, actual)
        print("PASS native KDE terminal preference parsing")

        preferences("xmonad-xlibre", "alacritty")
        command(
            [
                tools["ghc"],
                "-fno-code",
                "-outputdir",
                str(root / "ghc"),
                str(home / ".xmonad/xmonad.hs"),
            ],
            env,
            timeout=60,
        )
        print("PASS native XMonad configuration compilation")


if __name__ == "__main__":
    main()
