"""Read one bounded kernel configuration with the selecting user's authority."""

import os
import pwd
import stat
import subprocess
import sys
from pathlib import Path

MAX_BYTES = 4 * 1024**2


def read_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise ValueError("Select a regular defconfig of at most 4 MiB.")
        data = stream.read(MAX_BYTES + 1)
        after = os.fstat(stream.fileno())
    if len(data) > MAX_BYTES or (
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    ) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise ValueError("The selected defconfig changed while it was read.")
    return data


def read_selected(path):
    # sudo supplies the selecting account; do not turn a pathname read into a
    # stronger capability merely because installation requires root.
    uid = int(os.environ.get("SUDO_UID", "0")) if os.geteuid() == 0 else 0
    if uid:
        account = pwd.getpwuid(uid)
        result = subprocess.run(
            [sys.executable, "-I", str(Path(__file__).resolve()), str(path)],
            user=account.pw_uid,
            group=account.pw_gid,
            extra_groups=os.getgrouplist(account.pw_name, account.pw_gid),
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"},
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
        if result.returncode or len(result.stdout) > MAX_BYTES:
            raise ValueError("The selecting user cannot read this regular defconfig.")
        data = result.stdout
    else:
        data = read_file(path)
    return data.decode("utf-8")


if __name__ == "__main__":
    try:
        sys.stdout.buffer.write(read_file(sys.argv[1]))
    except (OSError, ValueError, IndexError):
        raise SystemExit(1) from None
