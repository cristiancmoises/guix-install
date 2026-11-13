import unittest

from guix_installer import channels, core


class ChannelSelectionTests(unittest.TestCase):
    def test_dependencies_close_automatically(self):
        self.assertEqual(
            channels.normalize(("small-guix",), "linux-libre"),
            ("small-guix", "sops-guix", "gocix"),
        )

    def test_blob_kernels_require_nonguix(self):
        self.assertIn("nonguix", channels.normalize((), "linux"))
        self.assertIn("nonguix", channels.normalize((), "securityops"))
        self.assertNotIn("nonguix", channels.normalize((), "linux-libre"))

    def test_unknown_channels_are_refused(self):
        with self.assertRaises(core.InstallError):
            core.validate_options(core.Options(channels=("typo-channel",)))

    def test_render_pins_and_introductions(self):
        text = channels.render(("securityops",), "linux-libre")
        self.assertIn("(list\n", text)
        self.assertIn("(name 'guix)", text)
        self.assertIn('(commit "b9a35ee6b53438d53d66cbe3e82f26bb22a44b5b")', text)
        self.assertIn("(openpgp-fingerprint", text)

    def test_guix_xlibre_has_no_introduction(self):
        text = channels.render(("guix-xlibre",), "linux-libre")
        xlibre = text.split("(name 'guix-xlibre)")[1].split(")\n (channel")[0]
        self.assertNotIn("make-channel-introduction", xlibre)

    def test_selected_descriptions_exist_in_both_languages(self):
        for channel in channels.CHANNELS.values():
            self.assertEqual(len(channel.description), 2)
            self.assertTrue(all(channel.description))


if __name__ == "__main__":
    unittest.main()
