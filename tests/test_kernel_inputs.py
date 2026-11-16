import os
import pwd
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from guix_installer import core


class KernelInputTests(unittest.TestCase):
    def test_staging_reuses_validated_content_after_source_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "selected.config"
            source.write_text("CONFIG_MODULES=y\n")
            host = directory / "host.config"
            options = core.Options(kernel="linux", kernel_config=str(source))
            content = core.check_kernel_defconfig(options, str(host))
            source.write_text("CONFIG_MODULES=n\n")
            (directory / "target").mkdir()
            with patch.object(
                Path, "read_text", side_effect=AssertionError("source reread")
            ):
                core.stage_kernel_defconfig(
                    options, directory / "target", str(host), content=content
                )
            self.assertEqual(host.read_text(), content)
            self.assertEqual(
                (directory / "target/etc/host.config").read_text(), content
            )

    def test_selected_symlink_is_rejected_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "source.config"
            source.write_text("CONFIG_MODULES=y\n")
            selected = directory / "selected.config"
            selected.symlink_to(source)
            with self.assertRaises(core.InstallError):
                core.check_kernel_defconfig(
                    core.Options(kernel="linux", kernel_config=str(selected)),
                    directory / "host",
                )

    def test_sudo_selected_input_is_read_with_callers_credentials(self):
        from guix_installer import defconfig

        account = pwd.getpwnam("nobody")
        with (
            patch.object(os, "geteuid", return_value=0),
            patch.dict(os.environ, {"SUDO_UID": str(account.pw_uid)}),
            patch.object(defconfig.subprocess, "run") as command,
        ):
            command.return_value.returncode = 0
            command.return_value.stdout = b"CONFIG_MODULES=y\n"
            self.assertEqual(
                defconfig.read_selected("/selected/config"), "CONFIG_MODULES=y\n"
            )
        self.assertEqual(command.call_args.kwargs["user"], account.pw_uid)
        self.assertEqual(command.call_args.kwargs["group"], account.pw_gid)
        self.assertEqual(
            command.call_args.kwargs["extra_groups"],
            os.getgrouplist(account.pw_name, account.pw_gid),
        )
        self.assertNotIn("SUDO_UID", command.call_args.kwargs["env"])


if __name__ == "__main__":
    unittest.main()
