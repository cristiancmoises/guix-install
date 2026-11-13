import hashlib
import json
import unittest
from pathlib import Path
from unittest.mock import patch

from guix_installer import core


def disk(**changes):
    value = {
        "name": "/dev/testdisk",
        "type": "disk",
        "size": 80 * 1024**3,
        "ro": False,
        "rm": False,
        "maj:min": "8:64",
        "serial": "TEST",
        "wwn": "test",
        "mountpoints": [None],
        "children": [],
    }
    value.update(changes)
    return value


class SafetyTests(unittest.TestCase):
    def test_rejects_busy_protected_readonly_and_small_disks(self):
        for entry, protected in [
            (
                disk(
                    children=[
                        dict(
                            disk(),
                            name="/dev/testdisk1",
                            type="part",
                            mountpoints=["/"],
                        )
                    ]
                ),
                set(),
            ),
            (disk(), {"/dev/testdisk"}),
            (disk(ro=True), set()),
            (disk(type="loop"), set()),
            (disk(size=1024), set()),
        ]:
            with self.subTest(entry=entry), self.assertRaises(core.InstallError):
                core.validate_disk(entry, protected, set(), set())

    def test_rejects_swap_and_device_mapper_holders(self):
        entry = disk(children=[dict(disk(), name="/dev/testdisk1", type="part")])
        for swaps, holders in [({"/dev/testdisk1"}, set()), (set(), {"8:64"})]:
            with self.assertRaises(core.InstallError):
                core.validate_disk(entry, set(), swaps, holders)

    def test_unknown_inventory_fails_closed(self):
        for key in ["mountpoints", "size", "maj:min", "ro", "type"]:
            entry = disk()
            del entry[key]
            with self.assertRaises(core.InstallError):
                core.validate_disk(entry, set(), set(), set())

    def test_identity_change_is_refused(self):
        initial = core.disk_identity(disk(), "14")
        with self.assertRaises(core.InstallError):
            core.require_same_identity(initial, core.disk_identity(disk(), "15"))
        core.require_same_identity(initial, core.disk_identity(disk(), "14"))

    def test_valid_disk_is_accepted(self):
        core.validate_disk(disk(), set(), set(), set())

    def test_scheme_injection_and_invalid_options_rejected(self):
        for changes in [
            {"hostname": 'x") (system "bad'},
            {"username": "root"},
            {"timezone": "../etc/passwd"},
            {"keyboard": "us\n"},
            {"desktop": "unknown"},
            {"locale": "bad"},
            {"disk": "/dev/x;reboot"},
        ]:
            with self.subTest(changes=changes), self.assertRaises(core.InstallError):
                core.validate_options(
                    core.Options(
                        **{"mode": "system", "disk": "/dev/testdisk", **changes}
                    )
                )

    def test_config_has_locked_root_and_unique_desktop_service(self):
        config = core.render_config(
            core.Options(mode="system", disk="/dev/testdisk"),
            "11111111-1111-1111-1111-111111111111",
            "ABCD-1234",
        )
        self.assertIn('(password "!")', config)
        self.assertNotIn("$6$salt$hash", config)
        self.assertIn('(uuid "11111111-1111-1111-1111-111111111111")', config)
        self.assertEqual(config.count("(service gnome-desktop-service-type)"), 1)
        self.assertNotIn("(service gdm-service-type)", config)
        self.assertNotIn("openssh-service-type", config)

    def test_blob_kernel_is_opt_in(self):
        for kernel in ("linux-libre", "linux"):
            config = core.render_config(
                core.Options(
                    mode="system",
                    disk="/dev/testdisk",
                    kernel=kernel,
                    kernel_version="7.3.4",
                ),
                "11111111-1111-1111-1111-111111111111",
                "ABCD-1234",
            )
            self.assertEqual("(kernel linux-latest)" in config, kernel == "linux")
            self.assertEqual("(nongnu packages linux)" in config, kernel == "linux")

    def test_plan_does_not_execute_commands(self):
        with patch(
            "subprocess.run", side_effect=AssertionError("plan executed a command")
        ):
            plan = core.make_plan(core.Options(mode="system", disk="/dev/testdisk"))
        self.assertIn("/dev/testdisk", "\n".join(plan))
        self.assertIn("ERASE /dev/testdisk", "\n".join(plan))

    def test_vendored_installer_matches_provenance(self):
        root = Path(__file__).resolve().parents[1] / "vendor"
        manifest = json.loads((root / "provenance.json").read_text())
        self.assertEqual(
            hashlib.sha256((root / "guix-install.sh").read_bytes()).hexdigest(),
            manifest["sha256"],
        )
        self.assertIn("/raw/commit/", manifest["url"])

    def test_upstream_failure_is_propagated(self):
        with (
            patch.object(core, "run", side_effect=core.InstallError("exit 19")),
            self.assertRaises(core.InstallError),
        ):
            core.install_manager()


if __name__ == "__main__":
    unittest.main()
