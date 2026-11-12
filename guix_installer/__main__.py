"""CLI entrypoint; installation is deliberately interactive."""

import argparse
import getpass
import json
import logging
import os
import shutil
import sys
import tempfile
from dataclasses import asdict

from . import __version__, core
from .branding import terminal_logo
from .i18n import tr, translated_plan


def parser():
    result = argparse.ArgumentParser(
        description="GNU Guix Installer — GUI and terminal wizard"
    )
    result.add_argument("--version", action="version", version=__version__)
    result.add_argument(
        "command",
        nargs="?",
        default="wizard",
        choices=["wizard", "gui", "doctor", "disks", "plan", "install"],
    )
    result.add_argument("--theme", choices=["dark", "light"], default="dark")
    result.add_argument("--lang", choices=["en", "pt-BR"], default="en")
    result.add_argument("--mode", choices=["manager", "system"], default="manager")
    for field in ["disk", "hostname", "username", "timezone", "locale", "keyboard"]:
        result.add_argument("--" + field, default=getattr(core.Options(), field))
    result.add_argument(
        "--desktop", choices=["gnome", "xfce", "minimal"], default="gnome"
    )
    result.add_argument(
        "--nonguix", action="store_true", help="opt into Linux and proprietary firmware"
    )
    result.add_argument(
        "--json",
        action="store_true",
        help="machine-readable plan, inventory or prerequisites",
    )
    result.add_argument("--hold", action="store_true", help=argparse.SUPPRESS)
    return result


def option_args(options):
    args = []
    for field, value in asdict(options).items():
        if isinstance(value, bool):
            if value:
                args.append("--" + field)
        elif value:
            args.extend(["--" + field, value])
    return args


def show_plan(options, language, json_output=False, theme="dark"):
    steps = translated_plan(options, language, core.make_plan(options))
    gold = (
        "\033[38;5;220m" if sys.stdout.isatty() and "NO_COLOR" not in os.environ else ""
    )
    orange = "\033[38;5;208m" if gold else ""
    white = ("\033[30;47m" if theme == "light" else "\033[97;40m") if gold else ""
    reset = "\033[0m" if gold else ""
    if json_output:
        print(
            json.dumps(
                {"options": asdict(options), "steps": steps, "executed": False},
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        print("\n" + gold + terminal_logo() + reset)
        print("\n  " + gold + "GNU GUIX INSTALLER  /  " + __version__ + reset)
        print("  " + tr("subtitle", language))
        print("\n  " + orange + tr("plan", language) + reset + "\n")
        for number, step in enumerate(steps, 1):
            print(f"  {gold}{number:02d}{reset}  {white}{step}{reset}")
        print()


def choose_options(options, language):
    print("\n" + terminal_logo() + "\nGNU GUIX INSTALLER\n" + tr("subtitle", language))
    print("1. " + tr("manager", language) + "\n2. " + tr("system", language))
    choice = input("[1/2] (1): ").strip() or "1"
    if choice not in {"1", "2"}:
        raise core.InstallError("Choose 1 or 2.")
    options.mode = "manager" if choice == "1" else "system"
    if options.mode == "system":
        for entry in core.inventory():
            if entry["type"] == "disk":
                print(f"  {entry['name']:20} {int(entry['size']) / 1024**3:7.1f} GiB")
        for field in [
            "disk",
            "hostname",
            "username",
            "timezone",
            "locale",
            "keyboard",
            "desktop",
        ]:
            default = getattr(options, field)
            value = input(f"{tr(field, language)} ({default}): ").strip()
            if value:
                setattr(options, field, value)
        options.nonguix = input(
            tr("firmware", language) + " [y/N]: "
        ).strip().lower() in {"y", "yes", "s", "sim"}
    return options


def elevate(options, language, theme, hold=False):
    if os.geteuid() == 0:
        return
    sudo = shutil.which("sudo")
    if not sudo:
        raise core.InstallError(
            "sudo is required. Run this command as root in a terminal."
        )
    # A real file entrypoint avoids relying on sudo preserving PYTHONPATH.
    launcher = str(core.ROOT / "run.py")
    os.execv(
        sudo,
        [
            sudo,
            "--",
            sys.executable,
            launcher,
            "install",
            "--lang",
            language,
            "--theme",
            theme,
            *(["--hold"] if hold else []),
            *option_args(options),
        ],
    )


def install(options, language, theme="dark", hold=False):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise core.InstallError(
            "Installation requires an interactive terminal; run plan for unattended inspection."
        )
    core.validate_options(options)
    elevate(options, language, theme, hold)
    os.umask(0o077)
    log_fd, log_path = tempfile.mkstemp(
        prefix="guix-install-", suffix=".log", dir="/var/log"
    )
    os.close(log_fd)
    logging.basicConfig(
        filename=log_path, level=logging.INFO, format="%(asctime)s %(message)s"
    )
    print("Command status log: " + log_path)
    lock = core.exclusive_lock()
    try:
        show_plan(options, language, theme=theme)
        if options.mode == "manager":
            if input(tr("continue", language)).strip() != "INSTALL":
                raise core.InstallError(tr("cancelled", language))
            core.install_manager()
        else:
            # Fail early on disk protection before requesting a password or erase consent.
            expected_identity = core.inspect_target(options.disk)
            phrase = input(tr("confirm", language) + f" (ERASE {options.disk}): ")
            if phrase != f"ERASE {options.disk}":
                raise core.InstallError(tr("cancelled", language))
            password = getpass.getpass(tr("password", language))
            repeated = getpass.getpass(tr("repeat", language))
            if (
                password != repeated
                or len(password) < 12
                or any(ord(ch) < 32 or ord(ch) == 127 for ch in password)
            ):
                raise core.InstallError(tr("password_error", language))
            verifier = core.run(
                ["openssl", "passwd", "-6", "-stdin"],
                capture=True,
                input_text=password + "\n",
            )
            password = repeated = ""
            core.install_system(options, phrase, verifier, expected_identity)
        print(tr("done", language))
    finally:
        os.close(lock)


def main(argv=None):
    args = parser().parse_args(argv)
    options = core.Options(
        **{field: getattr(args, field) for field in asdict(core.Options())}
    )
    status = 0
    try:
        if args.command == "gui":
            from .gui import launch

            launch(options, args.lang, args.theme)
        elif args.command == "doctor":
            findings = core.doctor(options.mode)
            print(
                json.dumps(dict(findings), indent=2)
                if args.json
                else "\n".join(
                    f"{'OK     ' if ok else 'MISSING'}  {name}" for name, ok in findings
                )
            )
            status = int(not all(ok for _, ok in findings))
        elif args.command == "disks":
            entries = core.inventory()
            if args.json:
                print(json.dumps(entries, indent=2))
            else:
                for node in core.flatten(entries):
                    if node["type"] == "disk":
                        print(
                            f"{node['name']:22} {int(node['size']) / 1024**3:8.1f} GiB  ro={node['ro']}"
                        )
        elif args.command == "plan":
            show_plan(options, args.lang, args.json, args.theme)
        else:
            if args.command == "wizard":
                if not sys.stdin.isatty():
                    raise core.InstallError(
                        "Wizard requires a terminal. Use plan or gui."
                    )
                options = choose_options(options, args.lang)
            install(options, args.lang, args.theme, args.hold)
    except (core.InstallError, OSError, ValueError, KeyError) as exc:
        print(tr("error", args.lang) + ": " + str(exc), file=sys.stderr)
        status = 1
    except (KeyboardInterrupt, EOFError):
        print("\n" + tr("interrupted", args.lang), file=sys.stderr)
        status = 130
    if args.hold and sys.stdin.isatty():
        input("\nEnter / Return...")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
