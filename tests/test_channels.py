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
        self.assertIn('(commit "505ade83fc62b438c558653dd57f7fb3b197cc8f")', text)
        self.assertIn('(commit "017b9e3aa09bbafca341dfba7c91ca96211e8020")', text)
        self.assertIn("(openpgp-fingerprint", text)

    def test_xlibre_now_comes_from_securityops(self):
        selected = channels.normalize(("securityops",), "linux-libre", "xmonad-xlibre")
        self.assertIn("securityops", selected)
        self.assertNotIn("guix-xlibre", channels.OPTIONAL_NAMES)

    def test_radix_and_rosenthal_are_authenticated(self):
        text = channels.render(("radix", "rosenthal"), "linux-libre")
        for name in ("radix", "rosenthal"):
            block = text.split(f"(name '{name})")[1].split(")\n (channel")[0]
            self.assertIn("make-channel-introduction", block)
        self.assertIn('(commit "d12acbe81ae3a5ff9ad8b705a13a5d1613384df4")', text)
        self.assertIn('(commit "bfe0d7379d399c7886e7c991d0c4bd01a3dfb015")', text)

    def test_selected_descriptions_exist_in_both_languages(self):
        for channel in channels.CHANNELS.values():
            self.assertEqual(len(channel.description), 2)
            self.assertTrue(all(channel.description))


if __name__ == "__main__":
    unittest.main()
