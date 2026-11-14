"""Commit-pinned channel catalogue with short EN/PT descriptions.

Pins and introductions reproduce the maintainer's authenticated
`channels.guix` (securityops-iso), the same graph the Security Ops OS live
image boots with. `guix` is always present and first; everything else is
opt-in with automatic dependency closure. XLibre now ships inside the
securityops channel, so the separate guix-xlibre channel is retired.
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
            "https://git.securityops.com.br/cristiancmoises/guix.git",
            "master",
            "505ade83fc62b438c558653dd57f7fb3b197cc8f",
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
            "https://git.securityops.com.br/cristiancmoises/nonguix.git",
            "master",
            "c241d19ff840dc75556f722b231760d119b6adea",
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
            "https://git.securityops.com.br/cristiancmoises/sops-guix.git",
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
            "https://git.securityops.com.br/cristiancmoises/gocix.git",
            "main",
            "d4beb39153608a68d2278085847cee585ca851b5",
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
            "https://git.securityops.com.br/cristiancmoises/small-guix.git",
            "main",
            "26cc25719837c8c914079d0df82aafb0e4c66b78",
            (
                "59de79f673669b798f650754b629404418464784",
                "0CFA 43B9 AA96 42EA AF2B E983 C4C6 61C9 ECFB 46E8",
            ),
            (
                "Small Guix: the Mullvad VPN package.",
                "Small Guix: o pacote Mullvad VPN.",
            ),
        ),
        Channel(
            "radix",
            "https://git.securityops.com.br/cristiancmoises/radix.git",
            "main",
            "d12acbe81ae3a5ff9ad8b705a13a5d1613384df4",
            (
                "f9130e11e35d2c147c6764ef85542dc58dc09c4f",
                "F164 709E 5FC7 B32B AEC7 9F37 1F2E 76AC E3F5 31C8",
            ),
            (
                "Radix: declarative system and home management built on Guix.",
                "Radix: gerenciamento declarativo de sistema e home sobre Guix.",
            ),
        ),
        Channel(
            "rosenthal",
            "https://git.securityops.com.br/cristiancmoises/rosenthal.git",
            "trunk",
            "bfe0d7379d399c7886e7c991d0c4bd01a3dfb015",
            (
                "7677db76330121a901604dfbad19077893865f35",
                "13E7 6CD6 E649 C28C 3385 4DF5 5E5A A665 6149 17F7",
            ),
            (
                "Rosenthal: hardware-first configuration layered over Radix.",
                "Rosenthal: configuração orientada a hardware sobre Radix.",
            ),
        ),
        Channel(
            "securityops",
            "https://git.securityops.com.br/cristiancmoises/securityops-channel.git",
            "main",
            "017b9e3aa09bbafca341dfba7c91ca96211e8020",
            (
                "fb3223f3afdc14bab294c78d88e545eda2b146d9",
                "0CFA 43B9 AA96 42EA AF2B E983 C4C6 61C9 ECFB 46E8",
            ),
            (
                "Security Ops: curated apps, XLibre server, Torando service.",
                "Security Ops: apps curados, servidor XLibre, serviço Torando.",
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
    "radix",
    "rosenthal",
)

DEPENDENCIES = {"small-guix": ("sops-guix", "gocix")}
DESKTOP_DEPENDENCIES = {"xmonad-xlibre": ("securityops",)}


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
