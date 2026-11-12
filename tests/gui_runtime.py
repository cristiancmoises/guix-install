"""Explicit native Tk checks: python3 tests/gui_runtime.py (requires a display)."""

import sys
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guix_installer import core
from guix_installer.gui import InstallerWindow


class NativeGuiTests(unittest.TestCase):
    def setUp(self):
        import tkinter as tk

        self.root = tk.Tk()
        self.root.withdraw()
        self.window = InstallerWindow(self.root, core.Options())
        self.errors = []
        self.window.error = self.errors.append

    def tearDown(self):
        self.root.update_idletasks()
        self.root.destroy()

    def spin(self, done, timeout=2):
        deadline = time.monotonic() + timeout
        while not done() and time.monotonic() < deadline:
            self.root.update()
            time.sleep(0.005)
        self.assertTrue(done(), "GUI operation did not complete")

    def test_slow_query_leaves_event_loop_responsive(self):
        def inventory():
            self.assertIsNot(threading.current_thread(), threading.main_thread())
            time.sleep(0.15)
            return []

        ticked = []
        self.root.after(10, lambda: ticked.append(True))
        with patch.object(core, "inventory", side_effect=inventory):
            self.window.review()
            self.window.refresh_disks()
            self.assertFalse(self.window.reviewed)
            self.spin(lambda: bool(ticked))
            self.assertTrue(self.window.query_running)
            self.spin(lambda: not self.window.query_running)
        self.assertFalse(self.errors)

    def test_changed_settings_discard_inflight_query_results(self):
        applied = []
        self.window.background_query(
            lambda: (time.sleep(0.1), "old data")[1], applied.append
        )
        self.window.values["hostname"].set("changed")
        self.spin(lambda: not self.window.query_running)
        self.assertEqual(applied, [])

    def test_language_and_theme_preserve_form_and_logo(self):
        self.window.values["username"].set("alice")
        self.window.change_theme("Light")
        self.window.change_language("Português (BR)")
        self.assertEqual(self.window.options().username, "alice")
        self.assertEqual(self.window.theme, "light")
        self.assertGreater(self.window.logo.width(), 0)
        self.window.review()
        self.assertTrue(self.window.reviewed)
        self.window.values["hostname"].set("changed")
        self.assertFalse(self.window.reviewed)


if __name__ == "__main__":
    unittest.main()
