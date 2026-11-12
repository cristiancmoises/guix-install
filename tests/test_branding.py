import hashlib
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch

from guix_installer.branding import terminal_logo


class BrandingTests(unittest.TestCase):
    def test_logo_is_derived_from_attributed_pinned_artwork(self):
        assets = Path(__file__).resolve().parents[1] / "assets"
        provenance = json.loads((assets / "provenance.json").read_text())
        self.assertEqual(provenance["license"], "CC-BY-SA-4.0")
        self.assertIn("/raw/commit/", provenance["url"])
        self.assertEqual(
            hashlib.sha256((assets / "guix-logo.svg").read_bytes()).hexdigest(),
            provenance["sha256"],
        )
        for name, digest in provenance["derived_files"].items():
            self.assertEqual(
                hashlib.sha256((assets / name).read_bytes()).hexdigest(), digest
            )

    def test_narrow_terminal_falls_back_to_wordmark(self):
        with patch("shutil.get_terminal_size", return_value=os.terminal_size((30, 24))):
            self.assertEqual(terminal_logo(), "GNU Guix")
        with patch(
            "shutil.get_terminal_size", return_value=os.terminal_size((100, 40))
        ):
            self.assertIn("#####", terminal_logo())
