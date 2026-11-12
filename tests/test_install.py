import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_core import disk

from guix_installer import core


class InstallationBoundaryTests(unittest.TestCase):
    def test_wrong_phrase_never_runs_a_command(self):
        with patch.object(core, "run") as run, self.assertRaises(core.InstallError):
            core.install_system(
                core.Options(mode="system", disk="/dev/testdisk"),
                "yes",
                "$6$salt$hash",
                ("identity",),
            )
        run.assert_not_called()

    def test_changed_disk_since_consent_never_partitions(self):
        with (
            patch.object(core, "doctor", return_value=[]),
            patch.object(core, "run") as run,
            patch.object(
                core, "inspect_target", return_value=core.disk_identity(disk(), "15")
            ),
            self.assertRaises(core.InstallError),
        ):
            core.install_system(
                core.Options(mode="system", disk="/dev/testdisk"),
                "ERASE /dev/testdisk",
                "$6$salt$hash",
                core.disk_identity(disk(), "14"),
            )
        self.assertFalse(
            any(call.args[0][0] == "parted" for call in run.call_args_list)
        )

    def test_mount_failure_never_recursively_deletes_target(self):
        # This context models a still-mounted target by leaving a file inside it.
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / "stage"
            base.mkdir()
            with (
                patch.object(core.tempfile, "mkdtemp", return_value=str(base)),
                self.assertRaises(core.InstallError),
                core.staging_directory() as target,
            ):
                (target / "still-mounted-data").write_text("preserve")
                raise core.InstallError("unmount failed")
            self.assertEqual(
                (base / "target/still-mounted-data").read_text(), "preserve"
            )

    def test_corrupted_upstream_script_never_executes(self):
        with (
            patch.object(core.Path, "read_bytes", return_value=b"corrupted"),
            patch.object(core, "run") as run,
            self.assertRaises(core.InstallError),
        ):
            core.install_manager()
        run.assert_not_called()

    def test_ambient_upstream_bypass_is_removed(self):
        with (
            patch.dict(
                "os.environ",
                {
                    "GUIX_BINARY_FILE_NAME": "/tmp/unsigned.tar.xz",
                    "GUIX_ALLOW_OVERWRITE": "yes",
                },
            ),
            patch.object(core, "run") as run,
        ):
            core.install_manager()
        environment = run.call_args.kwargs["env"]
        self.assertNotIn("GUIX_BINARY_FILE_NAME", environment)
        self.assertNotIn("GUIX_ALLOW_OVERWRITE", environment)

    def test_child_file_permissions_do_not_inherit_private_state_umask(self):
        import os
        import sys

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "created"
            previous = os.umask(0o077)
            try:
                core.run(
                    [
                        sys.executable,
                        "-c",
                        "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()",
                        str(output),
                    ]
                )
            finally:
                os.umask(previous)
            self.assertEqual(output.stat().st_mode & 0o777, 0o644)

    def test_shadow_seed_is_private_atomic_and_preserves_other_accounts(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)
            (target / "etc").mkdir()
            shadow = target / "etc/shadow"
            shadow.write_text("service:!:20000:0:99999:7:::\n")
            shadow.chmod(0o600)
            core.seed_shadow(target, "alice", "$6$salt$hash")
            rows = {
                line.split(":")[0]: line.split(":")
                for line in shadow.read_text().splitlines()
            }
            self.assertEqual(rows["alice"][1], "$6$salt$hash")
            self.assertEqual(rows["root"][1], "!")
            self.assertEqual(rows["service"][1], "!")
            self.assertTrue(all(len(row) == 9 for row in rows.values()))
            self.assertEqual(shadow.stat().st_mode & 0o777, 0o600)

    def test_shadow_seed_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)
            (target / "etc").mkdir()
            outside = target / "outside"
            outside.write_text("preserve")
            (target / "etc/shadow").symlink_to(outside)
            with self.assertRaises(core.InstallError):
                core.seed_shadow(target, "alice", "$6$salt$hash")
            self.assertEqual(outside.read_text(), "preserve")

    def test_failed_system_init_never_seeds_password_and_unmounts_own_targets(self):
        from contextlib import contextmanager

        from test_core import disk

        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "target"
            target.mkdir()

            @contextmanager
            def stage():
                yield target

            calls = []

            def command(args, **kwargs):
                calls.append(args)
                if args[:2] == ["guix", "time-machine"]:
                    raise core.InstallError("simulated build failure")
                if args[0] == "blockdev":
                    return "14"
                if args[0] == "findmnt":
                    return (
                        "11 8:65 /" if args[-1].endswith("/boot/efi") else "10 8:66 /"
                    )
                if args[0] == "blkid":
                    return (
                        "ABCD-1234"
                        if args[-1].endswith("1")
                        else "11111111-1111-1111-1111-111111111111"
                    )
                return ""

            original_read = Path.read_text

            def read(path, *args, **kwargs):
                if path.name == "start":
                    return "2048"
                if str(path) == "/sys/dev/block/8:65/partition":
                    return "1"
                if str(path) == "/sys/dev/block/8:66/partition":
                    return "2"
                return original_read(path, *args, **kwargs)

            entry = disk(
                children=[
                    dict(
                        disk(),
                        name="/dev/testdisk1",
                        type="part",
                        **{"maj:min": "8:65"},
                    ),
                    dict(
                        disk(),
                        name="/dev/testdisk2",
                        type="part",
                        **{"maj:min": "8:66"},
                    ),
                ]
            )
            expected = core.disk_identity(disk(), "14")
            with (
                patch.object(core, "doctor", return_value=[]),
                patch.object(core, "run", side_effect=command),
                patch.object(core, "inspect_target", return_value=expected),
                patch.object(core, "find_disk", return_value=entry),
                patch.object(core, "staging_directory", stage),
                patch.object(Path, "read_text", read),
                patch.object(core, "seed_shadow") as seed,
                self.assertRaises(core.InstallError),
            ):
                core.install_system(
                    core.Options(mode="system", disk="/dev/testdisk"),
                    "ERASE /dev/testdisk",
                    "$6$salt$hash",
                    expected,
                )
            seed.assert_not_called()
            self.assertEqual(
                [args[-1] for args in calls if args[0] == "umount"],
                [str(target / "boot/efi"), str(target)],
            )
