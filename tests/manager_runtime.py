"""Explicit native qualification; installs Guix on a disposable Linux host.

Run as root with ``python3 tests/manager_runtime.py --disposable-host``.
This is deliberately outside unittest discovery and leaves Guix installed.
"""

import argparse
import os
import pwd
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
USERNAME = "guix-runtime-check"
SYSTEM_ENV = {
    "PATH": "/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME": "/root",
    "USER": "root",
    "LOGNAME": "root",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "TERM": "dumb",
}
KERNEL_CONTROLS = (
    Path("/proc/sys/kernel/unprivileged_userns_clone"),
    Path("/proc/sys/user/max_user_namespaces"),
    Path("/proc/sys/kernel/apparmor_restrict_unprivileged_userns"),
    Path("/sys/module/apparmor/parameters/enabled"),
)


def account_failure_diagnostics(pid=None):
    """Emit bounded public service diagnostics, never arguments or environment."""
    if pid is not None:
        counters = {
            "rchar",
            "wchar",
            "syscr",
            "syscw",
            "read_bytes",
            "write_bytes",
            "cancelled_write_bytes",
        }
        try:
            with Path(f"/proc/{pid}/io").open(encoding="ascii") as source:
                lines = source.read(1024).splitlines()
            for line in lines:
                key, separator, value = line.partition(":")
                value = value.strip()
                if separator and key in counters and value.isdecimal():
                    print(f"useradd io {key}={value}", flush=True)
        except OSError as error:
            print(f"useradd io: unavailable ({type(error).__name__})", flush=True)
        try:
            with os.scandir(f"/proc/{pid}/fd") as descriptors:
                for index, descriptor in enumerate(descriptors):
                    if index == 32:
                        print("[descriptor output limited]", flush=True)
                        break
                    try:
                        target = os.readlink(descriptor.path)
                    except OSError as error:
                        target = f"unavailable ({type(error).__name__})"
                    print(
                        f"useradd fd={descriptor.name} target={target[:240]!r}",
                        flush=True,
                    )
        except OSError as error:
            print(f"useradd fd: unavailable ({type(error).__name__})", flush=True)
    processes = [
        "ps",
        "-C",
        "useradd,nscd,guix-daemon",
        "-o",
        "pid=,ppid=,comm=,wchan:32=",
    ]
    if pid is not None:
        processes.extend(["--pid", str(pid), "--ppid", str(pid)])
    commands = [
        ("process pid/ppid/comm/wchan", processes),
        (
            "account log size/allocation (512-byte blocks)",
            [
                "stat",
                "--format=%n size=%s blocks=%b",
                "--",
                "/var/log/lastlog",
                "/var/log/faillog",
            ],
        ),
        (
            "selected service state",
            [
                "systemctl",
                "show",
                "nscd.service",
                "guix-daemon.service",
                "--property=Id,ActiveState,SubState,Result,MainPID,NRestarts",
                "--no-pager",
            ],
        ),
    ]
    for service in ("nscd.service", "guix-daemon.service"):
        commands.append(
            (
                f"recent {service} messages",
                [
                    "journalctl",
                    "--unit=" + service,
                    "--lines=12",
                    "--output=cat",
                    "--no-pager",
                    "--quiet",
                ],
            )
        )
    for label, command in commands:
        try:
            result = subprocess.run(
                command,
                env=SYSTEM_ENV,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
                timeout=3,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"{label}: unavailable ({type(error).__name__})", flush=True)
            continue
        print(f"{label}: exit {result.returncode}", flush=True)
        lines = result.stdout.splitlines()
        for line in lines[:24]:
            print(line[:240], flush=True)
        if len(lines) > 24 or any(len(line) > 240 for line in lines[:24]):
            print("[diagnostic output limited]", flush=True)


def qualify():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--disposable-host",
        action="store_true",
        help="consent to installing Guix and a dummy account on this disposable host",
    )
    arguments = parser.parse_args()
    if not arguments.disposable_host:
        parser.error("--disposable-host is required; this installs Guix on the host")
    if sys.platform != "linux" or os.geteuid() != 0:
        parser.error("qualification requires root on a disposable Linux host")
    for path in ("/gnu", "/var/guix"):
        if os.path.lexists(path):
            parser.error(f"refusing a pre-existing installation path: {path}")
    if not Path("/run/systemd/system").is_dir():
        parser.error("qualification requires the normal systemd service manager")
    try:
        pwd.getpwnam(USERNAME)
    except KeyError:
        pass
    else:
        parser.error(f"refusing a pre-existing dummy account: {USERNAME}")
    if os.path.lexists(f"/home/{USERNAME}"):
        parser.error("refusing a pre-existing dummy account home")

    controls = {path: path.read_text() for path in KERNEL_CONTROLS if path.exists()}
    userns = Path("/proc/sys/kernel/unprivileged_userns_clone")
    if userns in controls and controls[userns].strip() != "1":
        parser.error(
            "user namespaces must already be enabled; controls are not changed"
        )
    maximum = Path("/proc/sys/user/max_user_namespaces")
    if maximum in controls and int(controls[maximum]) == 0:
        parser.error("user namespaces are unavailable; controls are not changed")

    print("Installing the bundled manager through core.install_manager()", flush=True)
    # Start with literal public values only. No ambient CI credentials, shell
    # settings, installer overrides, or personal keyring enter this child.
    subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            (
                "import sys; sys.path.insert(0, sys.argv[1]); "
                "from guix_installer import core; core.install_manager()"
            ),
            str(ROOT),
        ],
        cwd=ROOT,
        env=SYSTEM_ENV,
        input="\n" + "yes\n" * 64,
        text=True,
        check=True,
        timeout=1200,
    )
    if any(path.read_text() != value for path, value in controls.items()):
        raise RuntimeError("installation changed a kernel security control")
    subprocess.run(
        ["systemctl", "is-active", "--quiet", "guix-daemon.service"],
        env=SYSTEM_ENV,
        check=True,
        timeout=30,
    )
    socket = Path("/var/guix/daemon-socket/socket")
    if not stat.S_ISSOCK(socket.stat().st_mode):
        raise RuntimeError("the normal Guix daemon socket is unavailable")
    guix = Path("/usr/local/bin/guix")
    if not guix.is_file() or not guix.resolve().is_relative_to("/gnu/store"):
        raise RuntimeError("the installed Guix executable is unavailable")

    # The dedicated account needs an empty home, independent of host SDKs or
    # other content in /etc/skel. Root creates and retains this private fixture.
    with tempfile.TemporaryDirectory(prefix="guix-manager-skel-") as skeleton:
        command = [
            "useradd",
            "--create-home",
            "--user-group",
            "--skel",
            skeleton,
            "--shell",
            "/bin/sh",
            USERNAME,
        ]
        try:
            creation = subprocess.Popen(command, env=SYSTEM_ENV)
        except OSError:
            account_failure_diagnostics()
            raise
        try:
            status = creation.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                # Inspect the blocked process before termination removes its wchan.
                account_failure_diagnostics(creation.pid)
            finally:
                creation.kill()
                try:
                    creation.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    print("Timed-out useradd is still terminating", flush=True)
            raise
        if status:
            account_failure_diagnostics(creation.pid)
            raise subprocess.CalledProcessError(status, command)
    account = pwd.getpwnam(USERNAME)
    if account.pw_uid == 0 or account.pw_gid == 0:
        raise RuntimeError("the dummy account must be unprivileged")
    environment = {
        "PATH": SYSTEM_ENV["PATH"],
        "HOME": account.pw_dir,
        "USER": USERNAME,
        "LOGNAME": USERNAME,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }

    def as_user(command, *, capture=False):
        return subprocess.run(
            command,
            env=environment,
            cwd=account.pw_dir,
            user=account.pw_uid,
            group=account.pw_gid,
            extra_groups=[],
            stdout=subprocess.PIPE if capture else None,
            text=True,
            check=True,
            timeout=300,
        ).stdout

    as_user([str(guix), "--version"])
    nonce = uuid.uuid4().hex
    sentinel = Path(f"/guix-runtime-host-{nonce}")
    marker = f"Guix manager sandbox build passed: {nonce}\n"
    # Exclusive creation ensures cleanup can only remove our own dummy file.
    with sentinel.open("x", encoding="ascii") as output:
        output.write("public dummy host sentinel\n")
    try:
        # A readable file directly under / avoids confusing /root permissions
        # with sandbox isolation. The unprivileged client proves host visibility.
        sentinel.chmod(0o644)
        if as_user(["/usr/bin/cat", str(sentinel)], capture=True) != (
            "public dummy host sentinel\n"
        ):
            raise RuntimeError("the host visibility control failed")
        with tempfile.TemporaryDirectory(prefix="guix-manager-runtime-") as temporary:
            directory = Path(temporary)
            os.chown(directory, account.pw_uid, account.pw_gid)
            expression = directory / "sandbox.scm"
            expression.write_text(
                "(use-modules (guix gexp))\n"
                f'(computed-file "manager-runtime-{nonce}"\n'
                "  #~(begin\n"
                f'      (when (file-exists? "{sentinel}")\n'
                '        (error "host sentinel visible inside the build sandbox"))\n'
                "      (call-with-output-file #$output\n"
                "        (lambda (port)\n"
                f'          (display "Guix manager sandbox build passed: {nonce}\\n" port))))\n'
                "  #:local-build? #f\n"
                "  #:options '(#:substitutable? #f))\n",
                encoding="ascii",
            )
            expression.chmod(0o644)
            result = as_user(
                [
                    str(guix),
                    "build",
                    "--no-offload",
                    "--no-grafts",
                    "--file=" + str(expression),
                ],
                capture=True,
            ).strip()
            output = Path(result)
            if not output.is_absolute() or not output.resolve().is_relative_to(
                "/gnu/store"
            ):
                raise RuntimeError("build did not return a store output")
            if as_user(["/usr/bin/cat", str(output)], capture=True) != marker:
                raise RuntimeError("the computed-file build result is incorrect")
        if not sentinel.is_file():
            raise RuntimeError("the host sentinel disappeared during the build")
        subprocess.run(
            ["systemctl", "is-active", "--quiet", "guix-daemon.service"],
            env=SYSTEM_ENV,
            check=True,
            timeout=30,
        )
        print(
            "PASS: real manager install, active daemon, and unprivileged sandbox build"
        )
        as_user(
            [
                "/usr/bin/python3",
                str(Path(__file__).resolve().with_name("terminal_helper_runtime.py")),
                "--guix",
                str(guix),
            ]
        )
    finally:
        sentinel.unlink(missing_ok=True)


if __name__ == "__main__":
    qualify()
