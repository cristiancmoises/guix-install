import unittest
from unittest.mock import patch

from guix_installer import core, kernels


class KernelResolutionTests(unittest.TestCase):
    def test_nix_base32_matches_known_vectors(self):
        self.assertEqual(
            kernels.nix_base32(
                "039aef84f2b0994aeda3f4fcfc3d02ec9d7a9bbb9020ea264c43f446c860f606"
            ),
            "01pnc344dx239hkfl84hpfdpm7gc08yzrz7llgnlm6dhya2fz6h3",
        )
        self.assertEqual(
            kernels.nix_base32(
                "b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f"
            ),
            "07zx81c5n6bzj29b1di3m9fbba4l96m1mds0y0grk3jy57w6s6xi",
        )

    def test_latest_stable_picks_non_eol_stable(self):
        fixture = {
            "releases": [
                {"moniker": "mainline", "version": "7.4-rc2", "iseol": False},
                {"moniker": "stable", "version": "7.3.4", "iseol": False},
                {"moniker": "stable", "version": "7.2.15", "iseol": True},
                {"moniker": "longterm", "version": "6.12.117", "iseol": False},
            ]
        }
        with patch.object(kernels, "fetch_json", return_value=fixture):
            self.assertEqual(kernels.latest_stable_version(), "7.3.4")

    def test_latest_stable_falls_back_offline(self):
        with patch.object(kernels, "fetch_json", side_effect=OSError("offline")):
            self.assertEqual(kernels.latest_stable_version(), kernels.DEFAULT_LATEST)

    def test_bundled_hashes_work_offline(self):
        self.assertEqual(kernels.sha256_hex("7.3.4"), kernels.BUNDLED_SHA256["7.3.4"])
        self.assertEqual(kernels.sha256_hex("7.3"), kernels.BUNDLED_SHA256["7.3"])

    def test_unknown_version_needs_network(self):
        with (
            patch.object(kernels.urllib.request, "urlopen", side_effect=OSError),
            self.assertRaises(kernels.KernelError),
        ):
            kernels.sha256_hex("9.9.9")

    def test_source_origin_embeds_verified_hash(self):
        origin = kernels.source_origin("7.3.4", kernels.BUNDLED_SHA256["7.3.4"])
        self.assertIn("linux-7.3.4.tar.xz", origin)
        self.assertIn(
            '(sha256 (base32 "07zx81c5n6bzj29b1di3m9fbba4l96m1mds0y0grk3jy57w6s6xi"))',
            origin,
        )


class KernelConfigTests(unittest.TestCase):
    UUID = "11111111-1111-1111-1111-111111111111"

    def test_linux_libre_config_stays_channel_pinned(self):
        config = core.render_config(
            core.Options(mode="system", disk="/dev/example"), self.UUID, "ABCD-1234"
        )
        self.assertNotIn("nongnu", config)
        self.assertNotIn("(kernel", config)

    def test_linux_config_uses_newest_kernel_org_source(self):
        options = core.Options(
            mode="system", disk="/dev/example", kernel="linux", kernel_version="7.3.4"
        )
        config = core.render_config(options, self.UUID, "ABCD-1234")
        self.assertIn("(define linux-latest", config)
        self.assertIn('(version "7.3.4")', config)
        self.assertIn("linux-7.3.4.tar.xz", config)
        self.assertIn("(kernel linux-latest)", config)
        self.assertIn("(firmware (list linux-firmware))", config)

    def test_securityops_config_reproduces_maintainer_recipe(self):
        options = core.Options(
            mode="system",
            disk="/dev/example",
            kernel="securityops",
            kernel_version="7.3.4",
        )
        config = core.render_config(options, self.UUID, "ABCD-1234")
        self.assertIn("(inherit linux)", config)
        self.assertIn(
            '((#:defconfig _) (list (local-file "/etc/securityops.defconfig")))',
            config,
        )
        self.assertIn('(kernel-arguments \'("mitigations=on"', config)
        self.assertIn('"slab_nomerge"', config)
        self.assertIn("(kernel securityops)", config)

    def test_defconfig_only_for_securityops(self):
        with self.assertRaises(core.InstallError):
            core.validate_options(
                core.Options(
                    mode="system",
                    kernel="linux-libre",
                    kernel_config="/etc/securityops.defconfig",
                )
            )

    def test_invalid_kernel_version_is_refused(self):
        with self.assertRaises(core.InstallError):
            core.validate_options(
                core.Options(mode="system", kernel_version="7.3.4; rm -rf")
            )


if __name__ == "__main__":
    unittest.main()
