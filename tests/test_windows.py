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
    def setUp(self):
        self.target = {
            "Number": 1,
            "UniqueId": "fixture",
            "SerialNumber": "fixture",
            "Size": 1048576,
            "IsBoot": False,
            "IsSystem": False,
            "IsReadOnly": False,
            "IsOffline": False,
        }
        self.disk_patch = patch.object(
            windows, "inspect_writable_disk", return_value=self.target
        )
        self.volume_patch = patch.object(windows, "volume_paths", return_value=[])
        self.disk_patch.start()
        self.volume_patch.start()
        self.addCleanup(self.disk_patch.stop)
        self.addCleanup(self.volume_patch.stop)

    def test_locks_volume_handles_instead_of_physical_drive(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "fixture.iso"
            image.write_bytes(b"data")
            fake = FakeKernel(b"data", bytearray())
            handles = {}
            operations = []

            def create(device, *args):
                handle = len(handles) + 1
                handles[handle] = device
                return handle

            def ioctl(handle, code, *args):
                operations.append((handles[handle], code))
                return True

            fake.CreateFileW = create
            fake.DeviceIoControl = ioctl
            with (
                patch.object(windows, "require_windows"),
                patch.object(windows, "require_admin"),
                patch.object(
                    windows,
                    "volume_paths",
                    return_value=[r"\\?\Volume{12345678-1234-1234-1234-123456789abc}"],
                ),
                patch.object(windows, "disk_capacity", return_value=1048576),
                patch.object(windows, "_kernel32", return_value=fake),
            ):
                windows.write_image(image, 1)
            self.assertTrue(operations)
            self.assertTrue(
                all("PhysicalDrive" not in device for device, code in operations)
            )

    def test_readback_detects_corruption_after_input_is_truncated_or_replaced(self):
        for mutation in ("truncate", "replace", "same-size"):
            with (
                self.subTest(mutation=mutation),
                tempfile.TemporaryDirectory() as temporary,
            ):
                image = Path(temporary) / "fixture.iso"
                payload = b"x" * 1024
                image.write_bytes(payload)
                fake = FakeKernel(payload, bytearray())

                def flush(
                    handle, fake=fake, image=image, mutation=mutation, payload=payload
                ):
                    fake.disk[-1] = ord("!")
                    if mutation == "replace":
                        replacement = image.with_suffix(".new")
                        replacement.write_bytes(b"")
                        replacement.replace(image)
                    elif mutation == "same-size":
                        image.write_bytes(payload[:-1] + b"!")
                    else:
                        image.write_bytes(b"")
                    return True

                fake.FlushFileBuffers = flush
                with (
                    patch.object(windows, "require_windows"),
                    patch.object(windows, "require_admin"),
                    patch.object(windows, "disk_capacity", return_value=1048576),
                    patch.object(windows, "_kernel32", return_value=fake),
                    self.assertRaisesRegex(windows.WindowsError, "verification failed"),
                ):
                    windows.write_image(image, 1, verify=True)

    def test_readback_succeeds_if_the_written_image_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "fixture.iso"
            payload = b"x" * 1024
            image.write_bytes(payload)
            fake = FakeKernel(payload, bytearray())

            def flush(handle):
                image.unlink(missing_ok=True)
                return True

            fake.FlushFileBuffers = flush
            with (
                patch.object(windows, "require_windows"),
                patch.object(windows, "require_admin"),
                patch.object(windows, "disk_capacity", return_value=1048576),
                patch.object(windows, "_kernel32", return_value=fake),
            ):
                windows.write_image(image, 1, verify=True)
            self.assertEqual(bytes(fake.disk), payload)

    def test_growing_image_never_writes_beyond_the_original_size(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "fixture.iso"
            payload = b"x" * 1024
            image.write_bytes(payload)
            fake = FakeKernel(payload, bytearray())
            write = fake.WriteFile

            def grow_after_write(*args):
                result = write(*args)
                if len(fake.disk) == len(payload):
                    with image.open("ab") as stream:
                        stream.write(b"unexpected tail")
                return result

            fake.WriteFile = grow_after_write
            with (
                patch.object(windows, "require_windows"),
                patch.object(windows, "require_admin"),
                patch.object(windows, "disk_capacity", return_value=1048576),
                patch.object(windows, "_kernel32", return_value=fake),
                self.assertRaises(windows.WindowsError),
            ):
                windows.write_image(image, 1, verify=True)
            self.assertEqual(bytes(fake.disk), payload)

    def test_changed_disk_is_refused_before_open(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "fixture.iso"
            image.write_bytes(b"data")
            with (
                patch.object(windows, "require_admin"),
                patch.object(windows, "require_windows"),
                patch.object(windows, "_kernel32") as kernel,
                self.assertRaisesRegex(windows.WindowsError, "identity changed"),
            ):
                windows.write_image(
                    image, 1, expected_disk={**self.target, "UniqueId": "other"}
                )
            kernel.assert_not_called()

    def test_failed_volume_lock_closes_handle_without_writing(self):
        fake = FakeKernel(b"", bytearray())
        closed = []
        fake.CloseHandle = lambda handle: closed.append(handle) or True
        fake.DeviceIoControl = lambda *args: False
        with (
            patch.object(
                windows, "raise_win_error", side_effect=windows.WindowsError("locked")
            ),
            self.assertRaisesRegex(windows.WindowsError, "locked"),
            windows.locked_volumes(
                fake, [r"\\?\Volume{12345678-1234-1234-1234-123456789abc}"]
            ),
        ):
            self.fail("Lock failure entered the write context")
        self.assertEqual(closed, [12345])

    def test_download_rejects_empty_truncated_and_wrong_digest(self):
        import hashlib

        for payload, length, digest in (
            (b"", "0", hashlib.sha256(b"").hexdigest()),
            (b"data", "8", hashlib.sha256(b"data").hexdigest()),
            (b"data", "4", "0" * 64),
        ):
            with (
                self.subTest(payload=payload, length=length),
                tempfile.TemporaryDirectory() as temporary,
            ):
                response = io.BytesIO(payload)
                response.headers = {"Content-Length": length}
                target = Path(temporary) / "out.iso"
                with (
                    patch.object(windows, "require_windows"),
                    patch.object(
                        windows.urllib.request, "urlopen", return_value=response
                    ),
                    self.assertRaises(windows.WindowsError),
                ):
                    windows.download_image(
                        "https://example.invalid/image", target, expected_sha256=digest
                    )
                self.assertFalse(target.exists())

    def test_invalid_write_counts_stop_and_release_handles(self):
        for count in (0, 5):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as temporary:
                image = Path(temporary) / "fixture.iso"
                image.write_bytes(b"data")
                fake = FakeKernel(b"data", bytearray())
                writes = []
                closed = []

                def write(
                    handle, buffer, length, done, *rest, writes=writes, count=count
                ):
                    writes.append(length)
                    done._obj.value = count
                    return True

                fake.WriteFile = write
                fake.CloseHandle = lambda handle, closed=closed: (
                    closed.append(handle) or True
                )
                with (
                    patch.object(windows, "require_windows"),
                    patch.object(windows, "require_admin"),
                    patch.object(windows, "disk_capacity", return_value=1024),
                    patch.object(windows, "_kernel32", return_value=fake),
                    self.assertRaisesRegex(windows.WindowsError, "invalid byte count"),
                ):
                    windows.write_image(image, 1)
                self.assertEqual(writes, [4])
                self.assertEqual(closed, [12345])
                self.assertEqual(fake.ioctls, [])

    def test_failed_seeks_abort_and_release_handles(self):
        for failure_at in (1, 2):
            with (
                self.subTest(failure_at=failure_at),
                tempfile.TemporaryDirectory() as temporary,
            ):
                image = Path(temporary) / "fixture.iso"
                image.write_bytes(b"data")
                fake = FakeKernel(b"data", bytearray())
                seeks = []
                closed = []

                def seek(handle, offset, *rest, seeks=seeks, failure_at=failure_at):
                    seeks.append(offset)
                    return len(seeks) != failure_at

                fake.SetFilePointerEx = seek
                fake.CloseHandle = lambda handle, closed=closed: (
                    closed.append(handle) or True
                )
                with (
                    patch.object(windows, "require_windows"),
                    patch.object(windows, "require_admin"),
                    patch.object(windows, "disk_capacity", return_value=1024),
                    patch.object(windows, "_kernel32", return_value=fake),
                    patch.object(
                        windows,
                        "raise_win_error",
                        side_effect=windows.WindowsError("seek failed"),
                    ),
                    self.assertRaisesRegex(windows.WindowsError, "seek failed"),
                ):
                    windows.write_image(image, 1, verify=True)
                self.assertEqual(len(seeks), failure_at)
                self.assertEqual(closed, [12345])
                self.assertEqual(fake.ioctls, [])
                if failure_at == 1:
                    self.assertEqual(fake.disk, bytearray())

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
            self.assertEqual(fake.ioctls, [])

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
                    expected_sha256=__import__("hashlib").sha256(payload).hexdigest(),
                )
            self.assertEqual(total, len(payload))
            self.assertEqual(destination.read_bytes(), payload)
            self.assertEqual(calls[-1][1], len(payload))


class WindowsTargetPolicyTests(unittest.TestCase):
    def test_default_image_uses_verified_mirror_after_network_failure(self):
        with patch.object(
            windows, "download_image", side_effect=[OSError("offline"), 512]
        ) as download:
            self.assertEqual(windows.download_default_image("out.iso"), 512)
        self.assertEqual(download.call_count, 2)
        self.assertTrue(
            all(
                call.kwargs["expected_sha256"] == windows.DEFAULT_IMAGE_SHA256
                for call in download.call_args_list
            )
        )

    def test_protected_and_unknown_disks_are_refused(self):
        target = {
            "Number": 1,
            "UniqueId": "fixture",
            "Size": 1048576,
            "IsBoot": False,
            "IsSystem": False,
            "IsReadOnly": False,
            "IsOffline": False,
        }
        for field in ("IsBoot", "IsSystem", "IsReadOnly", "IsOffline"):
            for value in (True, None):
                with (
                    self.subTest(field=field, value=value),
                    patch.object(
                        windows, "list_disks", return_value=[{**target, field: value}]
                    ),
                    self.assertRaises(windows.WindowsError),
                ):
                    windows.inspect_writable_disk(1)
        with patch.object(windows, "list_disks", return_value=[target]):
            self.assertEqual(windows.inspect_writable_disk(1), target)

    def test_volume_paths_accepts_only_volume_guids(self):
        with (
            patch.object(windows, "powershell_json", return_value="C:\\"),
            self.assertRaises(windows.WindowsError),
        ):
            windows.volume_paths(1)
        expected = r"\\?\Volume{12345678-1234-1234-1234-123456789abc}"
        with patch.object(windows, "powershell_json", return_value=expected + "\\"):
            self.assertEqual(windows.volume_paths(1), (expected,))


if __name__ == "__main__":
    unittest.main()
