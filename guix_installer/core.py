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
    nonguix: bool = False


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
    if options.desktop not in {"gnome", "xfce", "minimal"}:
        raise InstallError("Desktop must be gnome, xfce or minimal.")
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
    return [
        f"ERASE ALL DATA: {options.disk} (minimum 32 GiB).",
        "Require x86_64 UEFI and Secure Boot disabled; reject busy/protected disks.",
        "Create GPT: 1 GiB FAT32 ESP + remaining ext4 root (unencrypted).",
        f"Configure {options.hostname}; user {options.username}; desktop {options.desktop}.",
        f"Locale {options.locale}; timezone {options.timezone}; keyboard {options.keyboard}.",
        "Kernel: "
        + (
            "Linux + proprietary firmware (Nonguix opt-in)."
            if options.nonguix
            else "Linux-libre (GNU Guix default)."
        ),
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
    kernel = ""
    if options.nonguix:
        modules += (
            "\n(use-modules (nongnu packages linux) (nongnu system linux-initrd))"
        )
        kernel = "\n  (kernel linux)\n  (firmware (list linux-firmware))\n  (initrd microcode-initrd)"
    service = (
        ""
        if options.desktop == "minimal"
        else f"\n    (service {options.desktop}-desktop-service-type)"
    )
    services = "%base-services" if options.desktop == "minimal" else "%desktop-services"
    return f'''{modules}
(use-service-modules desktop networking)
(operating-system
  (host-name "{options.hostname}")
  (timezone "{options.timezone}")
  (locale "{options.locale}")
  (keyboard-layout (keyboard-layout "{options.keyboard}")){kernel}
  (bootloader (bootloader-configuration
    (bootloader grub-efi-bootloader)
    (targets '("/boot/efi"))
    (keyboard-layout keyboard-layout)))
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
  (services (append (list{service}
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
            shutil.copyfile(
                ROOT / ("channels.scm" if options.nonguix else "channel.scm"), channels
            )
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
