import unittest

from guix_installer import core


class DesktopWindowManagerTests(unittest.TestCase):
    UUID = "11111111-1111-1111-1111-111111111111"

    def render(self, **changes):
        options = core.Options(mode="system", disk="/dev/example", **changes)
        return core.render_config(options, self.UUID, "ABCD-1234")

    def test_sway_skeleton_uses_selected_terminal(self):
        config = self.render(
            desktop="sway", terminals=("foot",), default_terminal="foot"
        )
        self.assertIn("set $term foot", config)
        self.assertIn("foot", config)
        self.assertIn('(plain-file "config"', config)
        self.assertIn(".config/sway/config", config)

    def test_river_skeleton_uses_selected_terminal(self):
        config = self.render(
            desktop="river-xmonad",
            terminals=("kitty",),
            default_terminal="kitty",
        )
        self.assertIn("spawn kitty", config)
        self.assertIn("riverctl default-layout rivertile", config)
        self.assertIn(".config/river/init", config)

    def test_xmonad_xlibre_overrides_gdm_server(self):
        config = self.render(
            desktop="xmonad-xlibre", kernel="linux", kernel_version="7.3.4"
        )
        self.assertIn("(xlibre)", config)
        self.assertIn("(xlibre-configuration", config)
        self.assertIn("gdm-service-type", config)
        self.assertIn("xlibre-video-amdgpu", config)

    def test_kde_uses_plasma_service(self):
        config = self.render(desktop="kde")
        self.assertIn("(service plasma-desktop-service-type)", config)
        self.assertIn("plasma plasma-workspace", config)

    def test_terminal_choices_are_validated(self):
        with self.assertRaises(core.InstallError):
            core.validate_options(
                core.Options(
                    mode="system",
                    disk="/dev/example",
                    terminals=("xterm",),
                    default_terminal="xterm",
                )
            )

    def test_xmonad_xlibre_requires_xlibre_channel(self):
        from guix_installer import channels

        self.assertIn(
            "guix-xlibre",
            channels.normalize((), "linux-libre", "xmonad-xlibre"),
        )

    def test_sway_skeleton_binds_default_browser(self):
        config = self.render(
            desktop="sway",
            browsers=("librewolf", "torbrowser"),
            default_browser="librewolf",
        )
        self.assertIn("set $browser librewolf", config)
        self.assertIn("bindsym $mod+e exec $browser", config)
        self.assertIn("librewolf", config)
        self.assertIn("torbrowser", config)

    def test_browsers_add_securityops_channel_and_modules(self):
        from guix_installer import channels

        self.assertIn(
            "securityops",
            channels.normalize((), "linux-libre", "gnome", ("torbrowser",)),
        )
        config = self.render(desktop="gnome", browsers=("torbrowser",))
        self.assertIn("(securityops packages tor)", config)
        self.assertIn("torbrowser", config)
        self.assertIn("(packages (append (list wezterm torbrowser", config)

    def test_browser_default_must_be_selected(self):
        with self.assertRaises(core.InstallError):
            core.validate_options(
                core.Options(
                    mode="system",
                    disk="/dev/example",
                    browsers=("chromium",),
                    default_browser="zen-browser",
                )
            )

    def test_browsers_require_securityops_channel(self):
        from guix_installer import channels

        selected = channels.normalize(
            (), "linux-libre", "gnome", browsers=("librewolf",)
        )
        self.assertIn("securityops", selected)
        self.assertNotIn(
            "securityops",
            channels.normalize((), "linux-libre", "gnome"),
        )


if __name__ == "__main__":
    unittest.main()
