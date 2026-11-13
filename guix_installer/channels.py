"""Commit-pinned channel catalogue with short EN/PT descriptions.

Pins and introductions come from the maintainer's authenticated
`channels.guix` (securityops-iso). `guix` is always present and first;
everything else is opt-in with automatic dependency closure.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Channel:
    name: str
    url: str
    branch: str
    commit: str
    introduction: tuple  # (first-commit, openpgp-fingerprint) or ()
    description: tuple  # (en, pt-BR)


CHANNELS = {
    channel.name: channel
    for channel in (
        Channel(
            "guix",
            "https://codeberg.org/guix/guix.git",
            "master",
            "b9a35ee6b53438d53d66cbe3e82f26bb22a44b5b",
            (
                "9edb3f66fd807b096b48283debdcddccfea34bad",
                "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA",
            ),
            (
                "Guix: the GNU Guix base system and every free package.",
                "Guix: o sistema GNU Guix base e todos os pacotes livres.",
            ),
        ),
        Channel(
            "nonguix",
            "https://gitlab.com/nonguix/nonguix",
            "master",
            "bf39542ca537fde8839b209ac21d6f3254469b15",
            (
                "897c1a470da759236cc11798f4e0a5f7d4d59fbc",
                "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5",
            ),
            (
                "Nonguix: Linux with firmware blobs and proprietary drivers.",
                "Nonguix: Linux com blobs de firmware e drivers proprietários.",
            ),
        ),
        Channel(
            "sops-guix",
            "https://github.com/fishinthecalculator/sops-guix",
            "main",
            "c53e27e533836ea8595626ba6796dee5362f8c4a",
            (
                "0bbaf1fdd25266c7df790f65640aaa01e6d2dbc9",
                "8D10 60B9 6BB8 292E 829B 7249 AED4 1CC1 93B7 01E2",
            ),
            (
                "Sops-Guix: authenticated dependency of the Small Guix channel.",
                "Sops-Guix: dependência autenticada do canal Small Guix.",
            ),
        ),
        Channel(
            "gocix",
            "https://github.com/fishinthecalculator/gocix",
            "main",
            "5cbc7d0cb911dd27eb364d350ac5a1ef43308316",
            (
                "cdb78996334c4f63304ecce224e95bb96bfd4c7d",
                "8D10 60B9 6BB8 292E 829B 7249 AED4 1CC1 93B7 01E2",
            ),
            (
                "Gocix: authenticated dependency of the Small Guix channel.",
                "Gocix: dependência autenticada do canal Small Guix.",
            ),
        ),
        Channel(
            "small-guix",
            "https://codeberg.org/fishinthecalculator/small-guix.git",
            "main",
            "042722ed1c20f41e3b85e6eee022f19cc2d1646d",
            (
                "f260da13666cd41ae3202270784e61e062a3999c",
                "8D10 60B9 6BB8 292E 829B 7249 AED4 1CC1 93B7 01E2",
            ),
            (
                "Small Guix: the Mullvad VPN package.",
                "Small Guix: o pacote Mullvad VPN.",
            ),
        ),
        Channel(
            "guix-xlibre",
            "https://gitlab.vulnix.sh/spacecadet/guix-xlibre.git",
            "master",
            "09edbfa3c5c4eaafbbb1947445c219ac53c465a6",
            (),
            (
                "Guix-Xlibre: XLibre X server (pinned commit; no signed introduction).",
                "Guix-Xlibre: servidor X XLibre (commit fixo; sem introdução assinada).",
            ),
        ),
        Channel(
            "securityops",
            "https://git.securityops.com.br/cristiancmoises/securityops-channel.git",
            "main",
            "98df294f8e626cc16374a20785943c20eb1636ec",
            (
                "af46f5cce66179f3e53f87c86ca2538c8fc63f98",
                "0CFA 43B9 AA96 42EA AF2B E983 C4C6 61C9 ECFB 46E8",
            ),
            (
                "Security Ops: curated apps (kitty, Tor Browser, Torando service).",
                "Security Ops: apps curados (kitty, Tor Browser, serviço Torando).",
            ),
        ),
    )
}

# Channels users may opt into; `guix` is always installed.
OPTIONAL_NAMES = (
    "nonguix",
    "securityops",
    "small-guix",
    "sops-guix",
    "gocix",
    "guix-xlibre",
)

DEPENDENCIES = {"small-guix": ("sops-guix", "gocix")}
DESKTOP_DEPENDENCIES = {"xmonad-xlibre": ("guix-xlibre",)}


def normalize(channels, kernel="linux-libre", desktop="gnome", browsers=()):
    """Close dependencies and apply kernel/browser requirements, in stable order."""
    selected = {name for name in channels if name in OPTIONAL_NAMES}
    if kernel in {"linux", "securityops"}:
        selected.add("nonguix")
    if browsers:
        selected.add("securityops")
    selected.update(DESKTOP_DEPENDENCIES.get(desktop, ()))
    for name in list(selected):
        selected.update(DEPENDENCIES.get(name, ()))
    return tuple(name for name in OPTIONAL_NAMES if name in selected)


def render(channels, kernel="linux-libre", desktop="gnome", browsers=()):
    selected = ("guix",) + normalize(channels, kernel, desktop, browsers)
    entries = []
    for name in selected:
        channel = CHANNELS[name]
        entries.append(
            f" (channel\n"
            f"  (name '{name})\n"
            f'  (url "{channel.url}")\n'
            f'  (branch "{channel.branch}")\n'
            f'  (commit "{channel.commit}")\n'
        )
        if channel.introduction:
            entries.append(
                "  (introduction\n"
                "   (make-channel-introduction\n"
                f'    "{channel.introduction[0]}"\n'
                "    (openpgp-fingerprint\n"
                f'     "{channel.introduction[1]}")))\n'
            )
        entries.append(")\n")
    return (
        ";; Generated by guix-install: authenticated, commit-pinned channels.\n"
        "(list\n" + "".join(entries) + ")"
    )
