import json
import os
import re
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from guix_installer import core


class ManagerVerificationTests(unittest.TestCase):
    def test_release_verification_binds_archive_and_release_signer(self):
        script = (core.ROOT / "vendor/guix-install.sh").read_text()
        function = re.search(r"(?ms)^guix_verify_release\(\)\n\{.*?^\}\n", script)
        self.assertIsNotNone(function)
        allowed = "A" * 40
        subkey = "B" * 40
        unrelated = "C" * 40
        for signer, primary, status, suffix, expected in (
            (allowed, allowed, 0, "", 0),
            (subkey, allowed, 0, "", 0),
            (unrelated, unrelated, 0, "", 1),
            (allowed, allowed, 1, "", 1),
            ("", "", 0, "", 1),
            (allowed, allowed, 0, "EXPSIG", 1),
            (allowed, allowed, 0, "EXPKEYSIG", 1),
            (allowed, allowed, 0, "REVKEYSIG", 1),
            (allowed, allowed, 0, "KEYEXPIRED", 0),
        ):
            with self.subTest(signer=signer, status=status):
                harness = f"""
declare -A GPG_SIGNING_KEYS=([release]={allowed})
gpg() {{
    [[ " $* " == *' --verify release.sig release.tar.xz '* ]] || return 90
    [[ " $* " == *' --no-options '* ]] || return 91
    [[ " $* " == *' --no-auto-key-retrieve '* ]] || return 92
    if [[ -n {signer!r} ]]; then
        printf '%s\\n' '[GNUPG:] VALIDSIG {signer} 2026-01-01 1 0 4 0 1 10 00 {primary}'
        printf '%s\\n' '[GNUPG:] {suffix}'
    fi
    return {status}
}}
{function.group(0)}
guix_verify_release release.sig release.tar.xz
"""
                result = subprocess.run(
                    ["bash", "--noprofile", "--norc", "-c", harness],
                    env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
                    capture_output=True,
                    check=False,
                    timeout=5,
                )
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_manager_uses_private_ephemeral_keyring(self):
        directories = []

        def command(args, *, env):
            directory = Path(env["GNUPGHOME"])
            directories.append(directory)
            self.assertTrue(directory.is_dir())
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            self.assertNotEqual(str(directory), "/unused-ambient-keyring")
            self.assertNotIn("GPG_AGENT_INFO", env)
            self.assertNotIn("GPG_TTY", env)

        with (
            patch.dict(
                os.environ,
                {
                    "GNUPGHOME": "/unused-ambient-keyring",
                    "GPG_AGENT_INFO": "unused",
                    "GPG_TTY": "unused",
                },
            ),
            patch.object(core, "run", side_effect=command),
        ):
            core.install_manager()
        self.assertEqual(len(directories), 1)
        self.assertFalse(directories[0].exists())

    def test_manager_does_not_customize_user_shell_files_as_root(self):
        script = (core.ROOT / "vendor/guix-install.sh").read_text()
        self.assertNotIn("sys_customize_bashrc", script)

    def test_daemon_acl_ownership_follows_selected_service_mode(self):
        script = (core.ROOT / "vendor/guix-install.sh").read_text()
        function = re.search(r"(?ms)^sys_authorize_build_farms\(\)\n\{.*?^\}\n", script)
        self.assertIsNotNone(function)
        self.assertIn("if install_unprivileged_daemon; then", function.group(0))
        self.assertNotIn("if id guix-daemon", function.group(0))

    def test_local_changes_keep_upstream_provenance(self):
        manifest = json.loads((core.ROOT / "vendor/provenance.json").read_text())
        self.assertEqual(len(manifest["upstream_sha256"]), 64)
        self.assertTrue(manifest["local_changes"])


if __name__ == "__main__":
    unittest.main()
