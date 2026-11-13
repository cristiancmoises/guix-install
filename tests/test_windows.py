import ctypes
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from guix_installer import windows


class FakeKernel:
    def __init__(self, image_bytes, disk):
        self.image = image_bytes
        self.disk = disk
        self.ioctls = []
        self.offset = 0

    def CreateFileW(self, device, access, share, *rest):
        self.device = device
        return 12345

    def DeviceIoControl(self, handle, code, *rest):
        self.ioctls.append(code)
        return True

    def SetFilePointerEx(self, handle, offset, *rest):
        self.offset = offset
        return True

    def WriteFile(self, handle, buffer, length, done, *rest):
        view = memoryview(buffer)
        self.disk.extend(view[:length])
        done._obj.value = length
        return True

    def ReadFile(self, handle, buffer, length, done, *rest):
        start = self.offset
        ctypes.memmove(buffer, bytes(self.disk[start : start + length]), length)
        self.offset += length
        done._obj.value = length
        return True

    def FlushFileBuffers(self, handle):
        return True

    def CloseHandle(self, handle):
        return True


class WindowsImagerTests(unittest.TestCase):
    def test_image_bigger_than_disk_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "guix.iso"
            image.write_bytes(b"x" * 4096)
            with (
                patch.object(windows, "require_windows"),
                patch.object(windows, "require_admin"),
                patch.object(windows, "disk_capacity", return_value=1024),
                self.assertRaises(windows.WindowsError),
            ):
                windows.write_image(str(image), 1)

    def test_write_image_locks_chunks_and_unlocks(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "guix.iso"
            image.write_bytes(b"0123456789abcdef" * 4)
            disk = bytearray()
            fake = FakeKernel(image.read_bytes(), disk)
            with (
                patch.object(windows, "require_windows"),
                patch.object(windows, "require_admin"),
                patch.object(windows, "disk_capacity", return_value=1 << 20),
                patch.object(windows, "CHUNK", 16),
                patch.object(windows, "_kernel32", return_value=fake),
            ):
                windows.write_image(str(image), 1)
            self.assertEqual(bytes(disk), image.read_bytes())
            self.assertEqual(fake.device, r"\\.\PhysicalDrive1")
            self.assertEqual(fake.ioctls[0], windows.FSCTL_LOCK_VOLUME)
            self.assertEqual(fake.ioctls[-1], windows.FSCTL_UNLOCK_VOLUME)

    def test_write_image_verifies_read_back(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "guix.iso"
            image.write_bytes(b"verifiable-payload" * 8)
            fake = FakeKernel(image.read_bytes(), bytearray())
            with (
                patch.object(windows, "require_windows"),
                patch.object(windows, "require_admin"),
                patch.object(windows, "disk_capacity", return_value=1 << 20),
                patch.object(windows, "CHUNK", 16),
                patch.object(windows, "_kernel32", return_value=fake),
            ):
                windows.write_image(str(image), 2, verify=True)
            self.assertEqual(bytes(fake.disk), image.read_bytes())

    def test_single_disk_json_is_wrapped(self):
        with (
            patch.object(windows, "require_windows"),
            patch.object(
                windows,
                "powershell_json",
                return_value={"Number": 1, "FriendlyName": "USB"},
            ),
        ):
            self.assertEqual(len(windows.list_disks()), 1)

    def test_download_image_streams_with_progress(self):
        payload = b"data" * 100
        response = io.BytesIO(payload)
        response.headers = {"Content-Length": str(len(payload))}
        calls = []

        class Response:
            def __init__(self):
                self.headers = {"Content-Length": str(len(payload))}

            def read(self, size=-1):
                data = response.read(size)
                return data

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "out.iso"
            with (
                patch.object(windows, "require_windows"),
                patch.object(
                    windows.urllib.request,
                    "urlopen",
                    return_value=Response(),
                ),
            ):
                total = windows.download_image(
                    "https://example.invalid/image",
                    str(destination),
                    progress=lambda done, final: calls.append((done, final)),
                )
            self.assertEqual(total, len(payload))
            self.assertEqual(destination.read_bytes(), payload)
            self.assertEqual(calls[-1][1], len(payload))


if __name__ == "__main__":
    unittest.main()
