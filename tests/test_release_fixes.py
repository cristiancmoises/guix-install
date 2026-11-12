import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from test_core import disk

from guix_installer import core


class ReleaseFixTests(unittest.TestCase):
    def test_unknown_readonly_state_is_refused(self):
        with self.assertRaises(core.InstallError):
            core.validate_disk(disk(ro=None), set(), set(), set())

    def test_query_timeout_becomes_actionable_error(self):
        with (
            patch("subprocess.run", side_effect=subprocess.TimeoutExpired("lsblk", 10)),
            self.assertRaises(core.InstallError),
        ):
            core.run(["lsblk"], capture=True, timeout=10)

    def test_changed_partition_size_or_device_is_refused(self):
        entry = disk(
            children=[
                dict(disk(), name="/dev/testdisk1", type="part", **{"maj:min": "8:65"}),
                dict(disk(), name="/dev/testdisk2", type="part", **{"maj:min": "8:66"}),
            ]
        )
        with patch.object(
            Path,
            "read_text",
            lambda path: (
                ("1" if "8:65" in str(path) else "2")
                if path.name == "partition"
                else "2048"
            ),
        ):
            original = core.partition_layout(entry)
            entry["children"][1]["size"] -= 4096
            with self.assertRaises(core.InstallError):
                core.require_partition_layout(original, core.partition_layout(entry))

    def test_replaced_mount_is_never_unmounted(self):
        with (
            patch.object(core, "run", return_value="8:99") as run,
            self.assertRaises(core.InstallError),
        ):
            core.unmount_owned(Path("/run/test-target"), "8:65", ("10", "/"))
        self.assertFalse(
            any(call.args[0][0] == "umount" for call in run.call_args_list)
        )

    def test_shifted_start_sector_is_refused(self):
        entry = disk(
            children=[
                dict(disk(), name="/dev/testdisk1", type="part", **{"maj:min": "8:65"}),
                dict(disk(), name="/dev/testdisk2", type="part", **{"maj:min": "8:66"}),
            ]
        )
        start = [2048]

        def read(path, *args, **kwargs):
            if path.name == "partition":
                return "1" if "8:65" in str(path) else "2"
            return str(start[0])

        with patch.object(Path, "read_text", read):
            original = core.partition_layout(entry)
            start[0] += 8192
            with self.assertRaises(core.InstallError):
                core.require_partition_layout(original, core.partition_layout(entry))

    def test_same_device_replacement_mount_is_refused(self):
        with (
            patch.object(core, "run", return_value="99 8:65 /subtree") as run,
            self.assertRaises(core.InstallError),
        ):
            core.unmount_owned(Path("/run/test-target"), "8:65", ("10", "/"))
        self.assertFalse(
            any(call.args[0][0] == "umount" for call in run.call_args_list)
        )
