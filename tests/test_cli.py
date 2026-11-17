import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CliTests(unittest.TestCase):
    def test_all_selected_options_survive_gui_and_sudo_forwarding(self):
        from guix_installer import core
        from guix_installer.__main__ import option_args, parser

        options = core.Options(
            mode="system",
            disk="/dev/example",
            kernel="zen",
            kernel_version="7.3.4",
            kernel_config="/selected/config",
            terminals=("kitty", "foot"),
            default_terminal="foot",
            browsers=("librewolf", "chromium"),
            default_browser="chromium",
            channels=("nonguix",),
        )
        args = parser().parse_args(["install", *option_args(options)])
        for name in (
            "kernel_version",
            "kernel_config",
            "default_terminal",
            "default_browser",
        ):
            self.assertEqual(getattr(args, name), getattr(options, name))
        self.assertEqual(args.terminal, list(options.terminals))
        self.assertEqual(args.browser, list(options.browsers))
        self.assertEqual(args.channel, list(options.channels))

    def test_kernel_resolution_failure_is_actionable_without_traceback(self):
        from unittest.mock import patch

        from guix_installer import kernels
        from guix_installer.__main__ import main

        with (
            patch.object(
                kernels, "resolve", side_effect=kernels.KernelError("retry online")
            ),
            patch("sys.stderr") as error,
        ):
            status = main(
                [
                    "plan",
                    "--mode",
                    "system",
                    "--disk",
                    "/dev/example",
                    "--kernel",
                    "linux",
                ]
            )
        self.assertEqual(status, 1)
        output = "".join(call.args[0] for call in error.write.call_args_list)
        self.assertIn("retry online", output)
        self.assertNotIn("Traceback", output)

    def cli(self, *args, input_text=None):
        return subprocess.run(
            [sys.executable, "-m", "guix_installer", *args],
            cwd=ROOT,
            text=True,
            input=input_text,
            capture_output=True,
            check=False,
            env={**os.environ, "LC_ALL": "C"},
            timeout=15,
        )

    def test_help_and_version(self):
        result = self.cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wizard", result.stdout)
        self.assertIn("0.5.5", self.cli("--version").stdout)

    def test_plan_is_unprivileged_and_explicit(self):
        result = self.cli("plan", "--mode", "system", "--disk", "/dev/example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ERASE /dev/example", result.stdout)
        self.assertIn("PLAN ONLY", result.stdout)

    def test_portuguese_plan(self):
        result = self.cli("plan", "--lang", "pt-BR")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PLANO", result.stdout)
        self.assertIn("distribuição", result.stdout)

    def test_invalid_config_fails_before_privilege(self):
        result = self.cli(
            "plan", "--mode", "system", "--disk", "/dev/example", "--username", "root"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sudo", result.stdout)

    def test_install_refuses_noninteractive_stdin(self):
        result = self.cli("install", input_text="yes\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("terminal", result.stderr.lower())

    def test_both_themes_support_planning(self):
        for theme in ["dark", "light"]:
            result = self.cli("plan", "--theme", theme)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.cli("plan", "--theme", "invalid").returncode, 0)

    def test_interruption_does_not_claim_no_disk_changes(self):
        from unittest.mock import patch

        from guix_installer.__main__ import main

        with (
            patch("guix_installer.__main__.install", side_effect=KeyboardInterrupt),
            patch("sys.stderr") as error,
        ):
            status = main(["install"])
        self.assertEqual(status, 130)
        output = "".join(call.args[0] for call in error.write.call_args_list)
        self.assertIn("modified", output)
        self.assertNotIn("No installation started", output)

    def test_elevation_preserves_terminal_retention(self):
        from unittest.mock import patch

        from guix_installer.__main__ import elevate
        from guix_installer.core import Options

        with (
            patch("os.geteuid", return_value=1000),
            patch("shutil.which", return_value="/usr/bin/sudo"),
            patch("os.execv") as execute,
        ):
            elevate(Options(), "en", "light", hold=True)
        self.assertIn("--hold", execute.call_args.args[1])
        self.assertIn("light", execute.call_args.args[1])

    def test_json_plan_has_no_logo_or_ansi(self):
        import json

        result = self.cli("plan", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["executed"])
        self.assertNotIn("\033[", result.stdout)

    def test_no_yes_or_force_bypass(self):
        self.assertNotEqual(self.cli("install", "--yes").returncode, 0)
        self.assertNotEqual(self.cli("install", "--force").returncode, 0)

    def test_multi_select_terminals_and_browsers(self):
        import json

        result = self.cli(
            "plan",
            "--json",
            "--mode",
            "system",
            "--disk",
            "/dev/example",
            "--terminal",
            "kitty",
            "--terminal",
            "foot",
            "--default-terminal",
            "foot",
            "--browser",
            "librewolf",
            "--browser",
            "zen-browser",
            "--default-browser",
            "zen-browser",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["options"]["terminals"], ["kitty", "foot"])
        self.assertEqual(plan["options"]["default_terminal"], "foot")
        self.assertEqual(plan["options"]["browsers"], ["librewolf", "zen-browser"])
        self.assertEqual(plan["options"]["default_browser"], "zen-browser")

    def test_default_terminal_must_be_selected(self):
        result = self.cli(
            "plan",
            "--mode",
            "system",
            "--disk",
            "/dev/example",
            "--terminal",
            "kitty",
            "--default-terminal",
            "foot",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Default terminal", result.stderr)


if __name__ == "__main__":
    unittest.main()
