import sys
import unittest
from unittest.mock import patch

from guix_installer import core
from guix_installer.gui import terminal_command


class GuiCommandTests(unittest.TestCase):
    def test_terminal_receives_arguments_without_shell(self):
        with patch(
            "shutil.which",
            side_effect=lambda name: "/usr/bin/xterm" if name == "xterm" else None,
        ):
            command = terminal_command(core.Options(), "pt-BR")
        self.assertEqual(command[:2], ["/usr/bin/xterm", "-e"])
        self.assertIn(sys.executable, command)
        self.assertIn("install", command)
        self.assertIn("pt-BR", command)
        self.assertNotIn("sh", command)

    def test_missing_terminal_is_actionable(self):
        with (
            patch("shutil.which", return_value=None),
            self.assertRaises(core.InstallError),
        ):
            terminal_command(core.Options(), "en")

    def test_terminal_preserves_theme_selection(self):
        with patch("shutil.which", return_value="/usr/bin/xterm"):
            command = terminal_command(core.Options(), "en", "light")
        self.assertEqual(command[command.index("--theme") + 1], "light")
