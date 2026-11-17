import unittest

from guix_installer import core


class DesktopWindowManagerTests(unittest.TestCase):
    UUID = "11111111-1111-1111-1111-111111111111"

    def test_x11_desktops_refuse_foot_as_default(self):
        for desktop in ("xfce", "xmonad-xlibre"):
            with self.subTest(desktop=desktop):
                options = core.Options(
                    mode="system",
                    disk="/dev/example",
                    desktop=desktop,
                    terminals=("foot",),
                    default_terminal="foot",
                )
                with self.assertRaisesRegex(core.InstallError, "Foot requires Wayland"):
                    core.validate_options(options)

    def test_x11_desktops_allow_foot_as_an_additional_terminal(self):
        for desktop in ("xfce", "xmonad-xlibre"):
            with self.subTest(desktop=desktop):
                core.validate_options(
                    core.Options(
                        mode="system",
                        disk="/dev/example",
                        desktop=desktop,
                        terminals=("foot", "kitty"),
                        default_terminal="kitty",
                    )
                )

    def test_manager_ignores_inactive_terminal_session_compatibility(self):
        core.validate_options(
            core.Options(desktop="xfce", terminals=("foot",), default_terminal="foot")
        )

    def render(self, **changes):
        options = core.Options(mode="system", disk="/dev/example", **changes)
        return core.render_config(options, self.UUID, "ABCD-1234")

    def test_selected_browser_is_default_for_web_links_and_html(self):
        browsers = ("torbrowser", "librewolf", "chromium", "zen-browser")
        for browser, desktop_id in zip(
            browsers,
            (
                "torbrowser.desktop",
                "librewolf.desktop",
                "chromium.desktop",
                "zen-browser.desktop",
            ),
        ):
            with self.subTest(browser=browser):
                config = self.render(browsers=browsers, default_browser=browser)
                self.assertIn(".config/mimeapps.list", config)
                self.assertIn("[Default Applications]", config)
                self.assertIn("[Added Associations]", config)
                for mime in (
                    "x-scheme-handler/http",
                    "x-scheme-handler/https",
                    "text/html",
                    "application/xhtml+xml",
                ):
                    self.assertEqual(config.count(f"{mime}={desktop_id};"), 2)

    def test_application_defaults_preserve_sway_bindings(self):
        config = self.render(
            desktop="sway",
            terminals=("foot",),
            default_terminal="foot",
            browsers=("chromium",),
            default_browser="chromium",
        )
        self.assertIn(".config/mimeapps.list", config)
        self.assertIn(".config/xdg-terminals.list", config)
        self.assertIn(".config/sway/config", config)
        self.assertIn("set $term foot", config)
        self.assertIn("set $browser chromium", config)

    def test_xmonad_config_uses_selected_terminal(self):
        config = self.render(
            desktop="xmonad-xlibre",
            terminals=("kitty", "alacritty"),
            default_terminal="alacritty",
        )
        self.assertIn(".xmonad/xmonad.hs", config)
        self.assertIn(r"terminal = \"alacritty\"", config)

    def test_xfce_default_terminal_has_a_real_helper(self):
        config = self.render(desktop="xfce")
        self.assertIn(".config/xfce4/helpers.rc", config)
        self.assertIn("TerminalEmulator=guix-install-terminal", config)
        self.assertIn(
            ".local/share/xfce4/helpers/guix-install-terminal.desktop", config
        )
        self.assertIn("X-XFCE-CommandsWithParameter=wezterm start --", config)

    def test_kde_default_terminal_uses_pinned_desktop_id(self):
        config = self.render(desktop="kde")
        self.assertIn(".config/kdeglobals", config)
        self.assertIn("TerminalApplication=wezterm start", config)
        self.assertIn("TerminalService=wezterm.desktop", config)

    def test_gnome_installs_the_pinned_standard_terminal_helper(self):
        config = self.render(desktop="gnome")
        self.assertIn("wezterm guix-install-xdg-terminal-exec", config)
        self.assertIn("80d6ea72054089b59356919e0391a1395460788d", config)
        self.assertIn('#:test-target "test"', config)
        self.assertIn("(native-inputs (list scdoc bats))", config)

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
        self.assertIn(
            "(modify-services %desktop-services (delete gdm-service-type))", config
        )

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

    def test_xmonad_xlibre_requires_securityops_channel(self):
        from guix_installer import channels

        self.assertIn(
            "securityops",
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

    def test_target_channels_file_carries_browser_dependency(self):
        options = core.Options(
            mode="system",
            disk="/dev/example",
            browsers=("torbrowser",),
            default_browser="torbrowser",
        )
        self.assertIn("(name 'securityops)", core.render_channels_file(options))
        without = core.Options(mode="system", disk="/dev/example")
        self.assertNotIn("(name 'securityops)", core.render_channels_file(without))


if __name__ == "__main__":
    unittest.main()
