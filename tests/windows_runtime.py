"""Native Windows qualification using a disposable file-backed virtual disk."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guix_installer import windows


@unittest.skipUnless(os.name == "nt", "requires native Windows")
class WindowsVirtualDiskTests(unittest.TestCase):
    def test_write_and_verify_disposable_vhd(self):
        self.write_and_verify("MBR")

    def test_write_and_verify_disposable_gpt_vhd(self):
        self.write_and_verify("GPT")

    def write_and_verify(self, partition_style):
        windows.require_admin()
        with tempfile.TemporaryDirectory(
            prefix="guix-install-vhd-test-", ignore_cleanup_errors=True
        ) as temporary:
            directory = Path(temporary)
            vhd = directory / "qualification.vhd"
            commands = directory / "create.txt"
            commands.write_text(
                f'create vdisk file="{vhd}" maximum=64 type=expandable\n'
                f'select vdisk file="{vhd}"\nattach vdisk\n',
                encoding="ascii",
            )
            image_path_literal = str(vhd).replace("'", "''")
            try:
                result = subprocess.run(
                    ["diskpart", "/s", str(commands)],
                    capture_output=True,
                    text=True,
                    timeout=60,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(vhd.is_file(), result.stdout + result.stderr)
                disk = windows.powershell_json(
                    "$ErrorActionPreference='Stop'; "
                    f"Get-DiskImage -ImagePath '{image_path_literal}' | Get-Disk "
                    "| Select-Object Number,BusType | ConvertTo-Json -Compress"
                )
                self.assertIn(disk["BusType"], ("File Backed Virtual", "Virtual", 15))
                number = disk["Number"]
                self.assertEqual(windows.volume_paths(number), ())
                windows.powershell_json(
                    "$ErrorActionPreference='Stop'; "
                    f"Set-Disk -Number {number} -IsOffline $false; "
                    f"Initialize-Disk -Number {number} -PartitionStyle {partition_style}; "
                    f"New-Partition -DiskNumber {number} -UseMaximumSize -AssignDriveLetter "
                    "| Format-Volume -FileSystem NTFS -Confirm:$false | Out-Null; "
                    "'true'"
                )
                target = windows.inspect_writable_disk(number)
                self.assertTrue(windows.volume_paths(number))
                image = directory / "payload.img"
                image.write_bytes(bytes(range(256)) * 8192)
                windows.write_image(image, number, verify=True, expected_disk=target)
            finally:
                windows.powershell_json(
                    "$ErrorActionPreference='Stop'; "
                    f"Get-DiskImage -ImagePath '{image_path_literal}' "
                    "| Where-Object Attached | Dismount-DiskImage -ErrorAction Stop | Out-Null; 'true'"
                )


if __name__ == "__main__":
    unittest.main()
