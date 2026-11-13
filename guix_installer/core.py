"""Shared installation policy and GNU/Linux orchestration.

Planning is pure. Disk operations require a fresh inventory, typed consent,
exclusive process lock, and an unchanged kernel disk sequence number.
"""

import fcntl
import hashlib
import json
import logging
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from . import channels as channels_catalog
from . import kernels

ROOT = Path(__file__).resolve().parents[1]
LOGGER = logging.getLogger(__name__)
MIN_DISK = 32 * 1024**3
SYSTEM_TOOLS = (
    "lsblk",
    "findmnt",
    "blkid",
    "blockdev",
    "parted",
    "partprobe",
    "udevadm",
    "mkfs.ext4",
    "mkfs.fat",
    "mount",
    "umount",
    "openssl",
    "guix",
    "sync",
)


class InstallError(RuntimeError):
    """An actionable refusal or failed installation step."""


@dataclass
class Options:
    mode: str = "manager"
    disk: str = ""
    hostname: str = "guix"
    username: str = "guest"
    timezone: str = "UTC"
    locale: str = "en_US.utf8"
    keyboard: str = "us"
    desktop: str = "gnome"
    terminals: tuple = ("wezterm",)
    default_terminal: str = "wezterm"
    browsers: tuple = ()
    default_browser: str = ""
    kernel: str = "linux-libre"
    kernel_version: str = ""
    kernel_config: str = ""
    channels: tuple = ()


WM_PACKAGES = {
    "sway": (
        "sway",
        "swaybg",
        "swayidle",
        "swaylock",
        "waybar",
        "wofi",
        "mako",
    ),
    "river-xmonad": (
        "river-xmonad-runtime",
        "xmonad-wayland",
        "waybar",
        "wofi",
        "mako",
    ),
    "xmonad-xlibre": (
        "xlibre-server",
        "xmonad",
        "ghc-xmonad-contrib",
        "xmobar",
        "xterm",
        "dmenu",
        "feh",
        "picom",
        "rofi",
        "xset",
        "setxkbmap",
    ),
    "kde": ("plasma", "plasma-workspace"),
}


def sway_skeleton(terminal, browser=""):
    bindsym = (
        "\n".join(
            (
                "set $browser " + browser,
                "bindsym $mod+e exec $browser",
            )
        )
        if browser
        else ""
    )
    return "\n".join(
        [
            "set $mod Mod4",
            f"set $term {terminal}",
            "set $menu wofi --show drun",
            "output * bg #080808 solid_color",
            "default_border pixel 2",
            "exec mako",
            "exec waybar",
            "bar { swaybar_command waybar }",
            "bindsym $mod+Return exec $term",
            "bindsym $mod+d exec $menu",
            "bindsym $mod+q kill",
            "bindsym $mod+Shift+c reload",
            "bindsym $mod+Shift+e exec swaymsg exit",
            bindsym,
            "",
        ]
    )


def river_skeleton(terminal, browser="", manager=""):
    browser_bind = f"riverctl map normal Super E spawn {browser}" if browser else ""
    manager_spawn = f"riverctl spawn {manager}" if manager else ""
    return "\n".join(
        [
            "#!/bin/sh",
            "# XMonad-style keybindings for River (Wayland).",
            "riverctl default-layout rivertile",
            f"riverctl map normal Super Return spawn {terminal}",
            'riverctl map normal Super D spawn "wofi --show drun"',
            "riverctl map normal Super Q close",
            "riverctl map normal Super J focus-view next",
            "riverctl map normal Super K focus-view previous",
            "riverctl map normal Super+Shift J swap next",
            "riverctl map normal Super+Shift K swap previous",
            "riverctl map normal Super Space zoom",
            "riverctl map normal Super+Shift E exit",
            browser_bind,
            manager_spawn,
            "riverctl spawn waybar",
            "",
        ]
    )


TERMINAL_CHOICES = ("wezterm", "kitty", "foot", "alacritty")

BROWSER_CHOICES = {
    "torbrowser": ("torbrowser", "(securityops packages tor)"),
    "librewolf": ("librewolf", "(securityops packages librewolf)"),
    "chromium": ("ungoogled-chromium", "(securityops packages browsers)"),
    "zen-browser": ("zen-browser-bin", "(securityops packages zen)"),
}

BROWSER_BINARIES = {
    "torbrowser": "torbrowser",
    "librewolf": "librewolf",
    "chromium": "chromium",
    "zen-browser": "zen-browser",
}


def validate_options(options):
    if options.mode not in {"manager", "system"}:
        raise InstallError("Choose manager or system.")
    checks = [
        (options.hostname, r"[a-z][a-z0-9-]{0,62}", "hostname"),
        (options.username, r"[a-z][a-z0-9_-]{0,30}", "username"),
        (options.keyboard, r"[a-z][a-z0-9-]{0,15}", "keyboard"),
        (options.locale, r"[a-z]{2}_[A-Z]{2}\.utf8", "locale"),
        (options.timezone, r"[A-Za-z_+-]+(?:/[A-Za-z0-9_+-]+)*", "timezone"),
    ]
    for value, pattern, name in checks:
        if not re.fullmatch(pattern, value):
            raise InstallError(f"Invalid {name}: {value!r}")
    if options.hostname.endswith("-") or options.username in {
        "root",
        "nobody",
        "guixbuilder",
    }:
        raise InstallError("Choose a non-reserved username and a valid hostname.")
    try:
        if options.timezone != "UTC":
            tzdir = os.environ.get("TZDIR")
            if tzdir:
                with (Path(tzdir) / options.timezone).open("rb") as stream:
                    ZoneInfo.from_file(stream)
            else:
                ZoneInfo(options.timezone)
    except (OSError, ZoneInfoNotFoundError, ValueError) as exc:
        raise InstallError(
            "Timezone not found; install your distribution's tzdata package."
        ) from exc
    if options.desktop not in {
        "gnome",
        "xfce",
        "minimal",
        "kde",
        "sway",
        "xmonad-xlibre",
        "river-xmonad",
    }:
        raise InstallError(
            "Desktop must be gnome, xfce, minimal, kde, sway, xmonad-xlibre "
            "or river-xmonad."
        )
    unknown_terminals = set(options.terminals) - set(TERMINAL_CHOICES)
    if unknown_terminals:
        raise InstallError("Unknown terminals: " + ", ".join(sorted(unknown_terminals)))
    if options.default_terminal not in options.terminals:
        raise InstallError("Default terminal must be one of the selected terminals.")
    unknown_browsers = set(options.browsers) - set(BROWSER_CHOICES)
    if unknown_browsers:
        raise InstallError("Unknown browsers: " + ", ".join(sorted(unknown_browsers)))
    if options.default_browser and options.default_browser not in options.browsers:
        raise InstallError("Default browser must be one of the selected browsers.")
    if options.kernel not in {"linux-libre", "linux", "securityops"}:
        raise InstallError("Kernel must be linux-libre, linux or securityops.")
    if options.kernel_version and not kernels.VERSION_PATTERN.fullmatch(
        options.kernel_version
    ):
        raise InstallError("Kernel version must look like 7.3.4, 7.3, or latest.")
    if options.kernel_config and options.kernel != "securityops":
        raise InstallError("A defconfig only applies to the securityops kernel.")
    if options.kernel_config:
        path = Path(options.kernel_config)
        if not path.is_file():
            raise InstallError(f"Defconfig not found: {options.kernel_config}")
    unknown = [
        name for name in options.channels if name not in channels_catalog.OPTIONAL_NAMES
    ]
    if unknown:
        raise InstallError("Unknown channels: " + ", ".join(sorted(unknown)))
    if options.mode == "system" and not re.fullmatch(
        r"/dev/[a-zA-Z0-9_/-]+", options.disk
    ):
        raise InstallError("Choose an explicit whole disk under /dev.")


def run(args, *, capture=False, input_text=None, env=None, timeout=None):
    """No shell evaluation. Preserve native failure and stream long operations."""
    LOGGER.info("Starting command: %s", args)
    try:
        result = subprocess.run(
            args,
            check=False,
            text=True,
            input=input_text,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            env=env,
            umask=0o022,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise InstallError(f"{args[0]} timed out after {timeout} seconds.") from exc
    except OSError as exc:
        raise InstallError(f"Cannot run {args[0]}: {exc}") from exc
    LOGGER.info("Command %s exited %s", args[0], result.returncode)
    if result.returncode:
        detail = (result.stderr or "").strip() if capture else "see terminal output"
        raise InstallError(f"{args[0]} exited {result.returncode}: {detail}")
    return result.stdout.strip() if capture else ""


def inventory():
    return json.loads(
        run(
            [
                "lsblk",
                "--json",
                "--bytes",
                "--paths",
                "--output",
                "NAME,TYPE,SIZE,RO,RM,MOUNTPOINTS,MAJ:MIN,SERIAL,WWN",
            ],
            capture=True,
            timeout=10,
        )
    )["blockdevices"]


def flatten(entries):
    for entry in entries:
        yield entry
        yield from flatten(entry.get("children", []))


def find_disk(path):
    canonical = str(Path(path).resolve(strict=True))
    for entry in flatten(inventory()):
        if entry["name"] == canonical:
            return entry
    raise InstallError("Disk disappeared from the block-device inventory.")


def validate_disk(entry, protected, swaps, holders):
    try:
        if (
            entry["type"] != "disk"
            or entry["ro"] not in (False, 0)
            or int(entry["size"]) < MIN_DISK
        ):
            raise InstallError("Select a writable whole disk of at least 32 GiB.")
        for node in flatten([entry]):
            if not node["maj:min"] or not isinstance(node["mountpoints"], list):
                raise InstallError("Incomplete disk inventory; refusing writes.")
            if node["name"] in protected:
                raise InstallError("This disk backs the running system or boot media.")
            if any(node["mountpoints"]):
                raise InstallError(
                    f"{node['name']} is mounted; unmount it explicitly first."
                )
            if node["name"] in swaps or node["maj:min"] in holders:
                raise InstallError(
                    "Target has active swap or device-mapper/RAID/LVM holders."
                )
    except (KeyError, TypeError, ValueError) as exc:
        raise InstallError("Incomplete disk inventory; refusing writes.") from exc


def backing_disks(device):
    if device.startswith("/dev/loop"):
        backing = run(
            ["losetup", "--noheadings", "--output", "BACK-FILE", device], capture=True
        )
        if not backing or backing.endswith(" (deleted)"):
            raise InstallError("Cannot resolve live media loop backing file.")
        device = run(
            ["findmnt", "--noheadings", "--output", "SOURCE", "--target", backing],
            capture=True,
        )
    if not device.startswith("/dev/"):
        raise InstallError(
            "Cannot resolve the running system's backing disk; use a supported live environment."
        )
    rows = run(
        [
            "lsblk",
            "--inverse",
            "--noheadings",
            "--raw",
            "--paths",
            "--output",
            "NAME,TYPE",
            device.split("[", 1)[0],
        ],
        capture=True,
    )
    disks = {row.split()[0] for row in rows.splitlines() if row.split()[-1] == "disk"}
    if not disks:
        raise InstallError(
            "No physical backing disk could be resolved; refusing writes."
        )
    return disks


def protected_disks():
    source = run(["findmnt", "--noheadings", "--output", "SOURCE", "/"], capture=True)
    protected = set()
    if source.startswith("/dev/"):
        protected |= backing_disks(source)
    else:
        specs = [
            word[5:]
            for word in Path("/proc/cmdline").read_text().split()
            if word.startswith("root=")
        ]
        if len(specs) != 1:
            raise InstallError(
                "Cannot identify live root media unambiguously; refusing disk installation."
            )
        spec = specs[0]
        if re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", spec):
            try:
                digits = bytes.fromhex(spec.replace("-", "")).decode("ascii")
            except (ValueError, UnicodeError) as exc:
                raise InstallError("Unrecognized live root UUID.") from exc
            if not re.fullmatch(r"[0-9]{16}", digits):
                raise InstallError("Unrecognized live root UUID.")
            spec = "UUID=" + "-".join(
                [digits[:4]] + [digits[i : i + 2] for i in range(4, 16, 2)]
            )
        if spec.startswith(("UUID=", "LABEL=", "PARTUUID=", "PARTLABEL=")):
            devices = run(
                ["blkid", "-t", spec, "-o", "device"], capture=True
            ).splitlines()
        elif spec.startswith("/dev/"):
            devices = [spec]
        else:
            raise InstallError("Unsupported live root specification; refusing writes.")
        for device in devices:
            protected |= backing_disks(device)
        if not protected:
            raise InstallError("Live media could not be resolved.")
    # Protect every mounted device as well, including ESPs and ISO loop media.
    for node in flatten(inventory()):
        if any(node.get("mountpoints") or []):
            protected |= backing_disks(node["name"])
    return protected


def inspect_target(path):
    entry = find_disk(path)
    holders = set()
    for node in flatten([entry]):
        directory = Path("/sys/dev/block") / node["maj:min"] / "holders"
        if not directory.is_dir():
            raise InstallError("Kernel holder information is unavailable.")
        if any(directory.iterdir()):
            holders.add(node["maj:min"])
        # An independent mounted-source check complements lsblk's mountpoints.
        result = subprocess.run(
            ["findmnt", "--noheadings", "--source", node["name"]],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode == 0:
            raise InstallError(f"{node['name']} is mounted.")
        if result.returncode != 1:
            raise InstallError("Cannot query mount state.")
    swaps = {
        str(Path(row.split()[0]).resolve())
        for row in Path("/proc/swaps").read_text().splitlines()[1:]
    }
    validate_disk(entry, protected_disks(), swaps, holders)
    return disk_identity(
        entry, run(["blockdev", "--getdiskseq", entry["name"]], capture=True)
    )


def disk_identity(entry, sequence):
    if not sequence.isdigit():
        raise InstallError("Kernel disk sequence number unavailable; refusing writes.")
    return (
        entry["name"],
        entry["maj:min"],
        int(entry["size"]),
        sequence,
        entry.get("serial"),
        entry.get("wwn"),
    )


def require_same_identity(expected, current):
    if expected != current:
        raise InstallError("Disk identity changed. Refusing the next write.")


@dataclass(frozen=True)
class Partition:
    number: int
    device: str
    major_minor: str
    size: int
    start_sector: int


def partition_layout(entry):
    """Bind each freshly created partition to kernel identity and size."""
    children = entry.get("children", [])
    if len(children) != 2:
        raise InstallError("Expected exactly two target partitions.")
    result = []
    for child in children:
        if child.get("type") != "part":
            raise InstallError("Unexpected non-partition child on target disk.")
        number = int(
            (Path("/sys/dev/block") / child["maj:min"] / "partition")
            .read_text()
            .strip()
        )
        result.append(
            Partition(
                number,
                child["name"],
                child["maj:min"],
                int(child["size"]),
                int(
                    (Path("/sys/dev/block") / child["maj:min"] / "start")
                    .read_text()
                    .strip()
                ),
            )
        )
    if {part.number for part in result} != {1, 2} or any(
        part.size <= 0 for part in result
    ):
        raise InstallError("Unexpected partition numbering or size.")
    return tuple(sorted(result, key=lambda part: part.number))


def require_partition_layout(expected, actual):
    if expected != actual:
        raise InstallError(
            "Target partition identity or size changed; refusing the next operation."
        )


def require_mount(path, major_minor, identity=None):
    fields = run(
        [
            "findmnt",
            "--noheadings",
            "--raw",
            "--output",
            "ID,MAJ:MIN,FSROOT",
            "--mountpoint",
            str(path),
        ],
        capture=True,
        timeout=10,
    ).split()
    if len(fields) != 3 or not fields[0].isdigit() or fields[1] != major_minor:
        raise InstallError(
            f"Mount identity changed at {path}; refusing access or cleanup."
        )
    current = (fields[0], fields[2])
    if identity is not None and current != identity:
        raise InstallError(f"Mount was replaced at {path}; refusing access or cleanup.")
    return current


def unmount_owned(path, major_minor, identity):
    require_mount(path, major_minor, identity)
    run(["umount", "--", str(path)])


def secure_boot_disabled():
    variables = list(Path("/sys/firmware/efi/efivars").glob("SecureBoot-*"))
    if len(variables) != 1:
        return False
    data = variables[0].read_bytes()
    return len(data) == 5 and data[4] == 0


def doctor(mode):
    tools = SYSTEM_TOOLS if mode == "system" else ("bash", "wget", "gpg", "xz", "tar")
    findings = [(f"Tool: {tool}", bool(shutil.which(tool))) for tool in tools]
    findings.append(("GNU/Linux", os.uname().sysname == "Linux"))
    if mode == "system":
        findings.extend(
            [
                (
                    "x86_64 UEFI host",
                    os.uname().machine == "x86_64"
                    and Path("/sys/firmware/efi").is_dir(),
                ),
                ("Secure Boot explicitly disabled", secure_boot_disabled()),
            ]
        )
    return findings


def make_plan(options):
    validate_options(options)
    if options.mode == "manager":
        return [
            "Install GNU Guix alongside the current distribution.",
            "Verify the bundled upstream installer SHA-256.",
            "Request sudo and run the official interactive installer.",
            "Upstream verifies the binary archive OpenPGP signature.",
            "Upstream may configure build users, daemon, profiles and official substitutes.",
            "No partitioning. Open a new login shell when finished.",
        ]
    if options.kernel == "linux-libre":
        kernel_line = "Linux-libre (GNU Guix default; channel-pinned)."
    elif options.kernel == "linux":
        version = kernels.resolve(options.kernel_version)[0]
        kernel_line = f"Linux {version} (kernel.org, newest stable) + firmware."
    else:
        version = kernels.resolve(options.kernel_version)[0]
        kernel_line = (
            f"SecurityOps {version} (kernel.org newest stable + hardened defconfig)."
        )
    channel_names = ("guix",) + channels_catalog.normalize(
        options.channels,
        options.kernel,
        options.desktop,
        options.browsers,
    )
    desktop_line = f"Configure {options.hostname}; user {options.username}; desktop {options.desktop}."
    selection_lines = []
    if options.terminals:
        terminal_list = ", ".join(
            (f"{name} (default)" if name == options.default_terminal else name)
            for name in options.terminals
        )
        selection_lines.append(f"Terminals: {terminal_list}.")
    if options.browsers:
        browser_list = ", ".join(
            (f"{name} (default)" if name == options.default_browser else name)
            for name in options.browsers
        )
        selection_lines.append(f"Browsers: {browser_list}.")
    return [
        f"ERASE ALL DATA: {options.disk} (minimum 32 GiB).",
        "Require x86_64 UEFI and Secure Boot disabled; reject busy/protected disks.",
        "Create GPT: 1 GiB FAT32 ESP + remaining ext4 root (unencrypted).",
        desktop_line,
        *selection_lines,
        f"Locale {options.locale}; timezone {options.timezone}; keyboard {options.keyboard}.",
        "Kernel: " + kernel_line,
        "Channels: " + ", ".join(channel_names),
        "Use authenticated, commit-pinned channels and guix system init.",
        "Keep root locked; request an administrator password privately.",
        f"Required confirmation: ERASE {options.disk}",
        "No automatic reboot. Interrupted writes cannot be rolled back.",
    ]


def render_config(options, root_uuid, esp_uuid):
    validate_options(options)
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", root_uuid) or not re.fullmatch(
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}", esp_uuid
    ):
        raise InstallError("Invalid filesystem UUID returned by blkid.")
    modules = "(use-modules (gnu) (gnu services desktop) (gnu system shadow))"
    kernel_fields = ""
    definitions = ""
    if options.kernel in {"linux", "securityops"}:
        modules += (
            "\n(use-modules (guix download) (guix gexp) (guix packages) (guix utils)"
            "\n             (nongnu packages linux) (nongnu system linux-initrd))"
        )
        version, digest = kernels.resolve(options.kernel_version)
        name = "securityops" if options.kernel == "securityops" else "linux-latest"
        definitions = (
            f"(define {name}\n"
            f"  (package\n"
            f"    (inherit linux)\n"
            f'    (name "{name}")\n'
            f'    (version "{version}")\n'
            f"    (source {kernels.source_origin(version, digest)})"
        )
        if options.kernel == "securityops":
            definitions += (
                "\n    (arguments\n"
                "     (substitute-keyword-arguments (package-arguments linux)\n"
                '       ((#:defconfig _) (list (local-file "/etc/securityops.defconfig")))\n'
                "       ((#:phases phases) phases)))"
            )
        definitions += "))\n\n"
        kernel_fields = (
            f"\n  (kernel {name})"
            "\n  (firmware (list linux-firmware))"
            "\n  (initrd microcode-initrd)"
        )
        if options.kernel == "securityops":
            kernel_fields += (
                "\n  (kernel-arguments '("
                + " ".join(
                    f'"{argument}"' for argument in kernels.SECURITYOPS_KERNEL_ARGUMENTS
                )
                + "))"
            )
    desktop_service = ""
    packages_field = ""
    skeletons_field = ""
    browser_symbols = tuple(BROWSER_CHOICES[name][0] for name in options.browsers)
    browser_bin = BROWSER_BINARIES.get(options.default_browser, "")
    if options.browsers:
        modules += (
            "\n(use-modules "
            + " ".join(sorted({BROWSER_CHOICES[name][1] for name in options.browsers}))
            + ")"
        )
    extra_packages = " ".join(tuple(options.terminals) + browser_symbols)
    if options.desktop in {"gnome", "xfce"}:
        desktop_service = f"\n    (service {options.desktop}-desktop-service-type)"
        if extra_packages:
            modules += "\n(use-modules (gnu packages terminals))"
            packages_field = (
                "\n  (packages (append (list " + extra_packages + ") %base-packages))"
            )
    elif options.desktop == "minimal":
        if extra_packages:
            modules += "\n(use-modules (gnu packages terminals))"
            packages_field = (
                "\n  (packages (append (list " + extra_packages + ") %base-packages))"
            )
    elif options.desktop == "kde":
        modules += "\n(use-modules (gnu packages kde-plasma) (gnu packages terminals))"
        desktop_service = "\n    (service plasma-desktop-service-type)"
        packages_field = (
            "\n  (packages (append (list plasma plasma-workspace "
            + extra_packages
            + ") %base-packages))"
        )
    elif options.desktop in WM_PACKAGES:
        modules += (
            "\n(use-modules (gnu packages wm) (gnu packages window-management)"
            "\n             (gnu packages zig-xyz) (gnu packages terminals)"
            "\n             (gnu packages xdisorg) (gnu packages xorg)"
            "\n             (gnu packages suckless) (gnu packages image-viewers)"
            "\n             (gnu packages compton))"
        )
        session_entry = ""
        if options.desktop == "river-xmonad":
            modules += (
                "\n(use-modules (securityops packages river)"
                "\n             (securityops packages xmonad-wayland)"
                "\n             (guix packages) (guix build-system trivial)"
                "\n             ((guix licenses) #:prefix license:))"
            )
            definitions += (
                "(define river-xmonad-session-entry\n"
                "  (package\n"
                '    (name "river-xmonad-session-entry")\n'
                '    (version "0.4.0")\n'
                "    (source #f)\n"
                "    (build-system trivial-build-system)\n"
                "    (arguments\n"
                "     (list #:modules '((guix build utils))\n"
                "           #:builder\n"
                "           #~(begin\n"
                "               (use-modules (guix build utils))\n"
                '               (mkdir-p (string-append #$output "/share/wayland-sessions"))\n'
                "               (call-with-output-file\n"
                '                   (string-append #$output "/share/wayland-sessions/river-xmonad.desktop")\n'
                "                 (lambda (port)\n"
                '                   (format port "[Desktop Entry]~%Name=River + XMonad (Wayland)~%'
                "Comment=XMonad window management on River~%Exec=river~%"
                'Type=Application~%"))))))\n'
                '    (home-page "https://codeberg.org/berkeley/xmonad-wayland")\n'
                '    (synopsis "GDM session entry for River + XMonad Wayland")\n'
                '    (description "Login-session entry that starts the River compositor.")\n'
                "    (license license:expat)))\n\n"
            )
            session_entry = " river-xmonad-session-entry"
        packages_field = (
            "\n  (packages (append (list "
            + " ".join(
                WM_PACKAGES[options.desktop]
                + tuple(options.terminals)
                + browser_symbols
            )
            + session_entry
            + ") %base-packages))"
        )
        if options.desktop in {"sway", "river-xmonad"}:
            if options.desktop == "sway":
                target, content = (
                    ".config/sway/config",
                    sway_skeleton(options.default_terminal, browser_bin),
                )
            else:
                target, content = (
                    ".config/river/init",
                    river_skeleton(
                        options.default_terminal, browser_bin, manager="xmonad-wayland"
                    ),
                )
            escaped = content.replace("\\", "\\\\").replace('"', '\\"')
            skeletons_field = (
                f'\n  (skeletons (cons (list "{target}" '
                f'(plain-file "{target.split("/")[-1]}" "{escaped}")) '
                "(default-skeletons)))"
            )
        if options.desktop == "xmonad-xlibre":
            modules += "\n(use-modules (gnu services xorg) (xlibre))"
            desktop_service = (
                "\n    (service gdm-service-type"
                "\n      (gdm-configuration"
                "\n        (xorg-configuration"
                "\n          (xlibre-configuration"
                "\n            (keyboard-layout %kbd)"
                "\n            (modules"
                "\n              (list xlibre-video-amdgpu xlibre-video-ati"
                "\n                    xlibre-video-cirrus xlibre-video-fbdev"
                "\n                    xlibre-video-nouveau xlibre-video-vesa"
                "\n                    xlibre-input-libinput xlibre-input-evdev"
                "\n                    xlibre-input-mouse))))))"
            )
    services = "%base-services" if options.desktop == "minimal" else "%desktop-services"
    return f'''{modules}
(use-service-modules desktop networking)
{definitions}(define %kbd (keyboard-layout "{options.keyboard}"))
(operating-system
  (host-name "{options.hostname}"){kernel_fields}
  (timezone "{options.timezone}")
  (locale "{options.locale}")
  (keyboard-layout %kbd)
  (bootloader (bootloader-configuration
    (bootloader grub-efi-bootloader)
    (targets '("/boot/efi"))
    (keyboard-layout keyboard-layout)))
{skeletons_field}{packages_field}
  (users (cons*
    (user-account
      (name "{options.username}")
      (comment "Administrator")
      (group "users")
      (home-directory "/home/{options.username}")
      (password "!")
      (supplementary-groups '("wheel" "netdev" "audio" "video")))
    (user-account (inherit %root-account) (password "!"))
    (filter (lambda (account) (not (string=? (user-account-name account) "root"))) %base-user-accounts)))
  (services (append (list{desktop_service}
    {"(service dhcp-client-service-type)" if options.desktop == "minimal" else ""}) {services}))
  (file-systems (cons*
    (file-system (mount-point "/")
      (device (uuid "{root_uuid}")) (type "ext4"))
    (file-system (mount-point "/boot/efi")
      (device (uuid "{esp_uuid}" 'fat32)) (type "vfat"))
    %base-file-systems)))
'''


def install_manager():
    manifest = json.loads((ROOT / "vendor/provenance.json").read_text())
    script = ROOT / "vendor/guix-install.sh"
    if hashlib.sha256(script.read_bytes()).hexdigest() != manifest["sha256"]:
        raise InstallError("Bundled upstream installer integrity check failed.")
    # Exclude upstream bypass/overwrite knobs from the ambient environment.
    environment = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(("GUIX_", "BASH_", "LD_"))
        and k not in {"ENV", "SHELLOPTS", "GLOBIGNORE"}
    }
    run(["bash", str(script)], env=environment)


def stage_securityops_defconfig(options, target):
    """Reproduce the maintainer's kernel recipe: /etc/securityops.defconfig.

    The generated config references the defconfig through `local-file`, so the
    host file is evaluated during `guix system init` and the identical file is
    shipped to the target for later `guix system reconfigure`.
    """
    if options.kernel != "securityops":
        return
    source = (
        Path(options.kernel_config)
        if options.kernel_config
        else ROOT / "assets/securityops.defconfig"
    )
    if not source.is_file():
        raise InstallError(f"Defconfig not found: {source}")
    content = source.read_text()
    host_path = Path("/etc/securityops.defconfig")
    if host_path.is_symlink():
        raise InstallError("Refusing symlink /etc/securityops.defconfig.")
    if host_path.exists():
        if host_path.read_text() != content:
            raise InstallError(
                "/etc/securityops.defconfig differs from the selected source; "
                "remove it or select it with --kernel-config."
            )
    else:
        host_path.write_text(content)
        host_path.chmod(0o644)
    target_etc = target / "etc"
    target_etc.mkdir(mode=0o755, exist_ok=True)
    target_etc.chmod(0o755)
    target_path = target_etc / "securityops.defconfig"
    target_path.write_text(content)
    target_path.chmod(0o644)


def validate_password_hash(password_hash):
    if not re.fullmatch(r"\$6\$[A-Za-z0-9./$]+", password_hash):
        raise InstallError("Invalid SHA-512 password verifier.")


def seed_shadow(target, username, password_hash):
    """Seed protected shadow entries for Guix's first-boot account merge.

    No verifier is included in the declarative configuration or Guix store.
    Existing Guix shadow entries take precedence over a locked declaration.
    """
    validate_password_hash(password_hash)
    validate_options(Options(username=username))
    etc = target / "etc"
    if etc.is_symlink() or etc.stat().st_uid != os.geteuid():
        raise InstallError("Unsafe target account directory.")
    shadow = etc / "shadow"
    if shadow.is_symlink():
        raise InstallError("Refusing symlink target shadow file.")
    entries = {}
    if shadow.exists():
        metadata = shadow.stat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077
        ):
            raise InstallError("Unsafe target shadow ownership or permissions.")
        for line in shadow.read_text().splitlines():
            fields = line.split(":")
            if len(fields) != 9 or not fields[0] or fields[0] in entries:
                raise InstallError("Malformed target shadow database.")
            entries[fields[0]] = fields
    day = str(max(1, int(time.time() // 86400)))
    entries["root"] = ["root", "!", day, "0", "99999", "7", "", "", ""]
    entries[username] = [username, password_hash, day, "0", "99999", "7", "", "", ""]
    descriptor, temporary = tempfile.mkstemp(prefix=".guix-install-shadow-", dir=etc)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(
                "".join(":".join(fields) + "\n" for fields in entries.values())
            )
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, shadow)
        directory = os.open(etc, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if Path(temporary).exists():
            Path(temporary).unlink()


@contextmanager
def staging_directory():
    # Never use recursive temporary-directory cleanup around a mountpoint.
    directory = Path(tempfile.mkdtemp(prefix="guix-install-", dir="/run"))
    target = directory / "target"
    target.mkdir()
    try:
        yield target
    finally:
        try:
            target.rmdir()
            directory.rmdir()
        except OSError:
            print(f"Recovery directory preserved: {directory}")


def install_system(options, confirmation, password_hash, expected_identity):
    validate_options(options)
    if confirmation != f"ERASE {options.disk}":
        raise InstallError("Erase phrase does not match. Nothing written.")
    failed = [name for name, ok in doctor("system") if not ok]
    if failed:
        raise InstallError("Prerequisites missing: " + ", ".join(failed))
    # Validate generated fields/password before the first disk write.
    render_config(options, "11111111-1111-1111-1111-111111111111", "ABCD-1234")
    validate_password_hash(password_hash)
    run(
        ["guix", "repl", "-q", "--", str(ROOT / "guix_installer/check-daemon.scm")],
        capture=True,
        timeout=15,
    )
    expected = inspect_target(options.disk)
    require_same_identity(expected_identity, expected)
    options.disk = expected[0]
    with staging_directory() as target:
        mounts = []
        layout = None
        try:

            def guarded(args):
                require_same_identity(expected, inspect_target(options.disk))
                if layout is not None:
                    require_partition_layout(
                        layout, partition_layout(find_disk(options.disk))
                    )
                run(args)

            guarded(
                [
                    "parted",
                    "--script",
                    "--",
                    options.disk,
                    "mklabel",
                    "gpt",
                    "mkpart",
                    "ESP",
                    "fat32",
                    "1MiB",
                    "1025MiB",
                    "set",
                    "1",
                    "esp",
                    "on",
                    "mkpart",
                    "root",
                    "ext4",
                    "1025MiB",
                    "100%",
                ]
            )
            run(["partprobe", options.disk])
            run(["udevadm", "settle", "--timeout=30"])
            layout = partition_layout(find_disk(options.disk))
            esp, root = layout[0].device, layout[1].device
            guarded(["mkfs.fat", "-F", "32", esp])
            guarded(["mkfs.ext4", "-F", root])
            guarded(["mount", "--", root, str(target)])
            mounts.append(
                (
                    target,
                    layout[1].major_minor,
                    require_mount(target, layout[1].major_minor),
                )
            )
            (target / "boot/efi").mkdir(parents=True)
            (target / "boot").chmod(0o755)
            (target / "boot/efi").chmod(0o755)

            def mounted_target_is_current():
                current = find_disk(options.disk)
                require_same_identity(
                    expected,
                    disk_identity(
                        current,
                        run(
                            ["blockdev", "--getdiskseq", options.disk],
                            capture=True,
                            timeout=10,
                        ),
                    ),
                )
                require_partition_layout(layout, partition_layout(current))
                for path, major_minor, mount_identity in mounts:
                    require_mount(path, major_minor, mount_identity)

            mounted_target_is_current()
            run(["mount", "--", esp, str(target / "boot/efi")])
            mounts.append(
                (
                    target / "boot/efi",
                    layout[0].major_minor,
                    require_mount(target / "boot/efi", layout[0].major_minor),
                )
            )
            mounted_target_is_current()
            root_uuid = run(["blkid", "-s", "UUID", "-o", "value", root], capture=True)
            esp_uuid = run(["blkid", "-s", "UUID", "-o", "value", esp], capture=True)
            etc = target / "etc"
            etc.mkdir(mode=0o755)
            etc.chmod(0o755)
            config = etc / "config.scm"
            config.write_text(render_config(options, root_uuid, esp_uuid))
            config.chmod(0o600)
            channels = etc / "channels.scm"
            channels.write_text(
                channels_catalog.render(
                    options.channels, options.kernel, options.desktop
                )
            )
            channels.chmod(0o600)
            stage_securityops_defconfig(options, target)
            mounted_target_is_current()
            run(
                [
                    "guix",
                    "time-machine",
                    "-C",
                    str(channels),
                    "--",
                    "system",
                    "init",
                    str(config),
                    str(target),
                    "--fallback",
                ]
            )
            if not (target / "boot/grub/grub.cfg").is_file():
                raise InstallError(
                    "Guix init returned without a bootloader configuration."
                )
            mounted_target_is_current()
            seed_shadow(target, options.username, password_hash)
            run(["sync", "-f", str(target)])
            run(["sync", "-f", str(target / "boot/efi")])
        finally:
            # Never recurse into arbitrary mounts. Leave failures visible for recovery.
            errors = []
            for mount, major_minor, mount_identity in reversed(mounts):
                try:
                    unmount_owned(mount, major_minor, mount_identity)
                except InstallError as exc:
                    errors.append(str(exc))
            if errors:
                raise InstallError(
                    "Unmount failed; recovery directory preserved: " + "; ".join(errors)
                )


def exclusive_lock():
    """Root-owned non-following lock; caller retains descriptor for process lifetime."""
    path = "/run/guix-install.lock"
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    metadata = os.fstat(descriptor)
    if (
        metadata.st_uid != 0
        or metadata.st_mode & 0o077
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        os.close(descriptor)
        raise InstallError("Unsafe installation lock ownership or permissions.")
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(descriptor)
        raise InstallError("Another installation is running.") from exc
    return descriptor
