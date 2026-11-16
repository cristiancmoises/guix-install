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

    subprocess.run(
        ["useradd", "--create-home", "--user-group", "--shell", "/bin/sh", USERNAME],
        env=SYSTEM_ENV,
        check=True,
        timeout=30,
    )
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
    finally:
        sentinel.unlink(missing_ok=True)


if __name__ == "__main__":
    qualify()
