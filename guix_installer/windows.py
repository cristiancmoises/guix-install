"""Windows-only migration helpers: disk inventory and raw image writing.

Standard library only. Disks are enumerated through PowerShell (present on
every supported Windows) and written through the raw ``\\\\.\\PhysicalDriveN``
device with a volume lock held for the duration of the write.
"""

import ctypes
import json
import os
import subprocess
import urllib.request
from pathlib import Path

CHUNK = 8 * 1024 * 1024
FSCTL_LOCK_VOLUME = 0x00090018
FSCTL_UNLOCK_VOLUME = 0x0009001C
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_READ = 1
FILE_SHARE_WRITE = 2
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
DEFAULT_IMAGE_URL = (
    "https://ftp.gnu.org/gnu/guix/guix-system-install-1.4.0.x86_64-linux.iso"
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


def powershell_json(script):
    result = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    if result.returncode:
        raise WindowsError("PowerShell query failed: " + (result.stderr or "").strip())
    return json.loads(result.stdout)


def list_disks():
    """Return friendly disk records via Get-Disk."""
    require_windows()
    script = (
        "Get-Disk | Select-Object Number,FriendlyName,SerialNumber,"
        "Size,BusType,PartitionStyle | ConvertTo-Json -Compress"
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


def download_image(url, destination, progress=None):
    """Stream a URL to a file with optional progress callbacks."""
    require_windows()
    request = urllib.request.Request(url, headers={"User-Agent": "guix-install"})
    total = 0
    with urllib.request.urlopen(request, timeout=60) as response:
        length = response.headers.get("Content-Length")
        final = int(length) if length and length.isdigit() else None
        with open(destination, "wb") as output:
            while True:
                block = response.read(CHUNK)
                if not block:
                    break
                output.write(block)
                total += len(block)
                if progress:
                    progress(total, final or total)
    return total


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
    kernel.SetFilePointerEx.argtypes = (
        ctypes.c_void_p,
        ctypes.c_longlong,
        ctypes.c_void_p,
        ctypes.c_uint32,
    )
    kernel.WriteFile.restype = ctypes.c_bool
    kernel.WriteFile.argtypes = (
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    )
    kernel.ReadFile.restype = ctypes.c_bool
    kernel.ReadFile.argtypes = (
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    )
    kernel.FlushFileBuffers.restype = ctypes.c_bool
    kernel.FlushFileBuffers.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.restype = ctypes.c_bool
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    return kernel


def _ioctl(kernel, handle, code):
    returned = ctypes.c_uint32()
    if not kernel.DeviceIoControl(
        handle, code, None, 0, None, 0, ctypes.byref(returned), None
    ):
        raise_win_error()


def write_image(image_path, disk_number, verify=False, progress=None):
    """Write an image byte-for-byte to a physical disk under a volume lock."""
    require_windows()
    require_admin()
    image = Path(image_path)
    image_size = image.stat().st_size
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
        _ioctl(kernel, handle, FSCTL_LOCK_VOLUME)
        try:
            kernel.SetFilePointerEx(handle, 0, None, 0)
            written = 0
            with open(image, "rb") as source:
                while True:
                    block = source.read(CHUNK)
                    if not block:
                        break
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
                        written += done.value
                        remaining = remaining[done.value :]
                        if progress:
                            progress(written, image_size)
            if written != image_size:
                raise WindowsError(
                    f"Incomplete write: {written} of {image_size} bytes."
                )
            if verify:
                kernel.SetFilePointerEx(handle, 0, None, 0)
                verified = 0
                with open(image, "rb") as source:
                    while True:
                        expected = source.read(CHUNK)
                        if not expected:
                            break
                        done = ctypes.c_uint32()
                        actual = (ctypes.c_char * len(expected))()
                        if not kernel.ReadFile(
                            handle,
                            actual,
                            len(expected),
                            ctypes.byref(done),
                            None,
                        ):
                            raise_win_error()
                        if done.value != len(expected) or actual.raw != expected:
                            raise WindowsError("Read-back verification failed.")
                        verified += len(expected)
                        if progress:
                            progress(verified, image_size)
            if not kernel.FlushFileBuffers(handle):
                raise_win_error()
        finally:
            _ioctl(kernel, handle, FSCTL_UNLOCK_VOLUME)
    finally:
        kernel.CloseHandle(handle)
