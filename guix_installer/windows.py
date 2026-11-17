"""Windows-only migration helpers: disk inventory and raw image writing.

Standard library only. Disks are enumerated through PowerShell (present on
every supported Windows) and written through the raw ``\\\\.\\PhysicalDriveN``
device with a volume lock held for the duration of the write.
"""

import ctypes
import hashlib
import hmac
import json
import os
import re
import subprocess
import tempfile
import urllib.request
from contextlib import ExitStack, contextmanager
from pathlib import Path, PureWindowsPath

CHUNK = 8 * 1024 * 1024
FSCTL_LOCK_VOLUME = 0x00090018
FSCTL_UNLOCK_VOLUME = 0x0009001C
FSCTL_DISMOUNT_VOLUME = 0x00090020
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_READ = 1
FILE_SHARE_WRITE = 2
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
DEFAULT_IMAGE_URL = (
    "https://ftp.gnu.org/gnu/guix/guix-system-install-1.5.0.x86_64-linux.iso"
)
DEFAULT_IMAGE_SHA256 = (
    "107e0a8082f03a10b15c1fb9383d2d752c1cdeda41b8db575a15550e1c2d8b4a"
)
DEFAULT_IMAGE_MIRRORS = (
    DEFAULT_IMAGE_URL,
    "https://mirrors.nic.funet.fi/pub/gnu/gnu/guix/guix-system-install-1.5.0.x86_64-linux.iso",
)
WinDLL = getattr(ctypes, "WinDLL", None)
WinError = getattr(ctypes, "WinError", None)
get_last_error = getattr(ctypes, "get_last_error", None)
windll = getattr(ctypes, "windll", None)


class WindowsError(RuntimeError):
    """An actionable Windows migration failure."""


def is_admin():
    assert windll is not None, "ctypes Windows support unavailable"
    return bool(windll.shell32.IsUserAnAdmin())


def raise_win_error():
    assert WinError is not None and get_last_error is not None
    raise WinError(get_last_error())


def require_windows():
    if os.name != "nt":
        raise WindowsError("This command is for Windows; use ./installer.sh here.")


def require_admin():
    require_windows()
    if not is_admin():
        raise WindowsError("Run as Administrator to write a disk image.")


def system_directory():
    """Resolve the OS directory without consulting PATH or SystemRoot."""
    if WinDLL is None:
        raise WindowsError("Native Windows helpers are unavailable.")
    kernel = WinDLL("kernel32", use_last_error=True)
    kernel.GetSystemDirectoryW.argtypes = (ctypes.c_wchar_p, ctypes.c_uint32)
    kernel.GetSystemDirectoryW.restype = ctypes.c_uint32
    buffer = ctypes.create_unicode_buffer(32768)
    length = kernel.GetSystemDirectoryW(buffer, len(buffer))
    if not 0 < length < len(buffer):
        raise WindowsError("Cannot resolve the native Windows system directory.")
    directory = PureWindowsPath(buffer.value)
    if not directory.is_absolute():
        raise WindowsError("Windows returned an invalid system directory.")
    return directory


def powershell_json(script):
    directory = system_directory()
    powershell = directory / "WindowsPowerShell/v1.0/powershell.exe"
    environment = {
        "SystemRoot": str(directory.parent),
        "WINDIR": str(directory.parent),
        "PATH": str(directory) + ";" + str(powershell.parent),
    }
    result = subprocess.run(
        [
            str(powershell),
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "$env:PSModulePath = Join-Path $PSHOME 'Modules'; "
            "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); "
            + script,
        ],
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
        timeout=60,
    )
    if result.returncode:
        raise WindowsError("PowerShell query failed: " + (result.stderr or "").strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def list_disks():
    """Return friendly disk records via Get-Disk."""
    require_windows()
    script = (
        "Get-Disk | Select-Object Number,FriendlyName,SerialNumber,"
        "Size,BusType,PartitionStyle,UniqueId,IsBoot,IsSystem,IsReadOnly,IsOffline "
        "| ConvertTo-Json -Compress"
    )
    payload = powershell_json(script)
    if isinstance(payload, dict):  # single disk serializes as an object
        payload = [payload]
    return payload or []


def disk_capacity(disk_number):
    for disk in list_disks():
        if disk.get("Number") == disk_number:
            return int(disk.get("Size") or 0)
    raise WindowsError(f"Disk {disk_number} not found. Re-run list first.")


def inspect_writable_disk(disk_number):
    if type(disk_number) is not int or disk_number < 0:
        raise WindowsError("Select a non-negative physical disk number.")
    for disk in list_disks():
        if disk.get("Number") != disk_number:
            continue
        if any(
            disk.get(field) is not False
            for field in ("IsBoot", "IsSystem", "IsReadOnly", "IsOffline")
        ):
            raise WindowsError(
                "Refusing a boot, system, read-only, offline or unknown disk."
            )
        if not disk.get("UniqueId") or int(disk.get("Size") or 0) <= 0:
            raise WindowsError("Disk identity or capacity is unavailable.")
        return disk
    raise WindowsError(f"Disk {disk_number} not found. Re-run list first.")


def volume_paths(disk_number):
    if type(disk_number) is not int or disk_number < 0:
        raise WindowsError("Invalid disk number.")
    paths = powershell_json(
        "$ErrorActionPreference='Stop'; @(Get-Partition -ErrorAction Stop "
        f"| Where-Object {{ $_.DiskNumber -eq {disk_number} }} "
        "| ForEach-Object { $_.AccessPaths } "
        "| Where-Object { $_ -and $_.StartsWith('\\\\?\\Volume{') }) "
        "| ConvertTo-Json -Compress"
    )
    if isinstance(paths, str):
        paths = [paths]
    result = []
    for path in paths or []:
        path = str(path).rstrip("\\")
        if not re.fullmatch(r"\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}", path):
            raise WindowsError("Unexpected Windows volume path; refusing writes.")
        result.append(path)
    return tuple(sorted(set(result)))


@contextmanager
def locked_volumes(kernel, paths):
    with ExitStack() as cleanup:
        for path in paths:
            handle = kernel.CreateFileW(
                path,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                None,
                OPEN_EXISTING,
                0,
                None,
            )
            if handle == INVALID_HANDLE_VALUE:
                raise_win_error()
            cleanup.callback(kernel.CloseHandle, handle)
            _ioctl(kernel, handle, FSCTL_LOCK_VOLUME)
            cleanup.callback(_ioctl, kernel, handle, FSCTL_UNLOCK_VOLUME)
            _ioctl(kernel, handle, FSCTL_DISMOUNT_VOLUME)
        yield


def download_image(url, destination, progress=None, expected_sha256=None):
    """Download and verify an image before atomically making it available."""
    require_windows()
    if not url.startswith("https://"):
        raise WindowsError("Image downloads require HTTPS.")
    expected_sha256 = expected_sha256 or (
        DEFAULT_IMAGE_SHA256 if url == DEFAULT_IMAGE_URL else ""
    )
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256):
        raise WindowsError("Provide the publisher's SHA-256 for a custom image URL.")
    request = urllib.request.Request(url, headers={"User-Agent": "guix-install"})
    total = 0
    destination = Path(destination)
    descriptor, temporary = tempfile.mkstemp(
        prefix=".guix-image-", dir=destination.parent
    )
    digest = hashlib.sha256()
    try:
        with os.fdopen(descriptor, "wb") as output:
            with urllib.request.urlopen(request, timeout=60) as response:
                length = response.headers.get("Content-Length")
                final = int(length) if length and length.isdigit() else None
                while True:
                    block = response.read(CHUNK)
                    if not block:
                        break
                    output.write(block)
                    digest.update(block)
                    total += len(block)
                    if progress:
                        progress(total, final or total)
            if not total or (final is not None and total != final):
                raise WindowsError("Empty or incomplete image download.")
            if not hmac.compare_digest(digest.hexdigest(), expected_sha256.lower()):
                raise WindowsError("Image SHA-256 verification failed.")
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return total


def download_default_image(destination, progress=None):
    last_error = None
    for url in DEFAULT_IMAGE_MIRRORS:
        try:
            return download_image(
                url,
                destination,
                progress=progress,
                expected_sha256=DEFAULT_IMAGE_SHA256,
            )
        except (OSError, WindowsError) as exc:
            last_error = exc
    raise WindowsError(
        f"Cannot download a verified Guix image: {last_error}"
    ) from last_error


def _kernel32():
    assert WinDLL is not None, "ctypes Windows support unavailable"
    kernel = WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CreateFileW.argtypes = (
        ctypes.c_wchar_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
    )
    kernel.DeviceIoControl.argtypes = (
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    )
    kernel.DeviceIoControl.restype = ctypes.c_int32
    kernel.SetFilePointerEx.argtypes = (
        ctypes.c_void_p,
        ctypes.c_longlong,
        ctypes.c_void_p,
        ctypes.c_uint32,
    )
    kernel.SetFilePointerEx.restype = ctypes.c_int32
    kernel.WriteFile.restype = ctypes.c_int32
    kernel.WriteFile.argtypes = (
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    )
    kernel.ReadFile.restype = ctypes.c_int32
    kernel.ReadFile.argtypes = (
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    )
    kernel.FlushFileBuffers.restype = ctypes.c_int32
    kernel.FlushFileBuffers.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.restype = ctypes.c_int32
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    return kernel


def _ioctl(kernel, handle, code):
    returned = ctypes.c_uint32()
    if not kernel.DeviceIoControl(
        handle, code, None, 0, None, 0, ctypes.byref(returned), None
    ):
        raise_win_error()


def write_image(
    image_path, disk_number, verify=False, progress=None, expected_disk=None
):
    """Write an image byte-for-byte to a physical disk under a volume lock."""
    require_windows()
    require_admin()
    image = Path(image_path)
    image_size = image.stat().st_size
    if image_size <= 0:
        raise WindowsError("Image must be nonempty.")
    target = inspect_writable_disk(disk_number)
    if expected_disk is not None and target != expected_disk:
        raise WindowsError("Disk identity changed since confirmation; refusing writes.")
    capacity = disk_capacity(disk_number)
    if image_size > capacity:
        raise WindowsError(
            f"Image ({image_size} bytes) exceeds disk {disk_number} ({capacity} bytes)."
        )
    kernel = _kernel32()
    device = rf"\\.\PhysicalDrive{disk_number}"
    handle = kernel.CreateFileW(
        device,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        None,
        OPEN_EXISTING,
        0,
        None,
    )
    if handle == INVALID_HANDLE_VALUE:
        raise_win_error()
    try:
        paths = volume_paths(disk_number)
        with locked_volumes(kernel, paths):
            if (
                inspect_writable_disk(disk_number) != target
                or volume_paths(disk_number) != paths
            ):
                raise WindowsError("Disk or volume identity changed; refusing writes.")
            if not kernel.SetFilePointerEx(handle, 0, None, 0):
                raise_win_error()
            written = 0
            written_digest = hashlib.sha256()
            with open(image, "rb") as source:
                while written < image_size:
                    block = source.read(min(CHUNK, image_size - written))
                    if not block:
                        break
                    if verify:
                        written_digest.update(block)
                    remaining = memoryview(block)
                    while remaining:
                        done = ctypes.c_uint32()
                        buffer = (ctypes.c_char * len(remaining)).from_buffer_copy(
                            remaining
                        )
                        if not kernel.WriteFile(
                            handle,
                            buffer,
                            len(remaining),
                            ctypes.byref(done),
                            None,
                        ):
                            raise_win_error()
                        if done.value == 0 or done.value > len(remaining):
                            raise WindowsError(
                                "Disk write returned an invalid byte count."
                            )
                        written += done.value
                        remaining = remaining[done.value :]
                        if progress:
                            progress(written, image_size)
                if source.read(1):
                    raise WindowsError("Image size changed during writing.")
            if written != image_size:
                raise WindowsError(
                    f"Incomplete write: {written} of {image_size} bytes."
                )
            if not kernel.FlushFileBuffers(handle):
                raise_win_error()
            if verify:
                if not kernel.SetFilePointerEx(handle, 0, None, 0):
                    raise_win_error()
                verified = 0
                readback_digest = hashlib.sha256()
                while verified < image_size:
                    count = min(CHUNK, image_size - verified)
                    done = ctypes.c_uint32()
                    actual = (ctypes.c_char * count)()
                    if not kernel.ReadFile(
                        handle,
                        actual,
                        count,
                        ctypes.byref(done),
                        None,
                    ):
                        raise_win_error()
                    if done.value != count:
                        raise WindowsError("Read-back verification failed.")
                    readback_digest.update(actual.raw)
                    verified += count
                    if progress:
                        progress(verified, image_size)
                if readback_digest.digest() != written_digest.digest():
                    raise WindowsError("Read-back verification failed.")
            if not kernel.FlushFileBuffers(handle):
                raise_win_error()
    finally:
        kernel.CloseHandle(handle)
