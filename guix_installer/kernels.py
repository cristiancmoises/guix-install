"""Kernel selection: always-fresh kernel.org sources with offline fallbacks.

The `linux` and `securityops` options reproduce the maintainer's in-use Guix
kernel recipe (nonguix `linux` with the source replaced by a vanilla
kernel.org tarball; the securityops kernel additionally replaces the
defconfig). Version resolution is cached; bundled hashes keep planning
offline once a version has been pinned.
"""

import functools
import json
import re
import urllib.request

DEFAULT_LATEST = "7.3.4"
RELEASES_URL = "https://www.kernel.org/releases.json"
SHA256SUMS_URL = "https://cdn.kernel.org/pub/linux/kernel/v{major}.x/sha256sums.asc"
SOURCE_URL = "https://cdn.kernel.org/pub/linux/kernel/v{major}.x/linux-{version}.tar.xz"

BUNDLED_SHA256 = {
    "7.3.4": "b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f",
    "7.3": "87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953",
    "7.2.6": "039aef84f2b0994aeda3f4fcfc3d02ec9d7a9bbb9020ea264c43f446c860f606",
}

SECURITYOPS_KERNEL_ARGUMENTS = (
    "mitigations=on",
    "spectre_v2=on",
    "spec_store_bypass_disable=on",
    "tsx=off",
    "slab_nomerge",
    "page_alloc.shuffle=1",
    "init_on_alloc=1",
    "randomize_kstack_offset=on",
    "lsm=landlock,yama,integrity,apparmor,bpf",
    "apparmor=1",
    "security=apparmor",
    "random.trust_cpu=off",
    "preempt=full",
    "transparent_hugepage=madvise",
    "numa_balancing=disable",
)

ZEN_RELEASES_URL = (
    "https://api.github.com/repos/zen-kernel/zen-kernel/releases?per_page=100"
)
ZEN_PATCH_URL = "https://github.com/zen-kernel/zen-kernel/releases/download/v{version}-zen{revision}/linux-v{version}-zen{revision}.patch.zst"
BUNDLED_ZEN_PATCHES = {
    "7.3.4": (2, "3296823f5ad0bc93308630b7574614cd687889c42f72fda27d0e534ee843626d"),
}
ZEN_KERNEL_ARGUMENTS = ()

VERSION_PATTERN = re.compile(r"^(?:latest|\d+\.\d+(?:\.\d+)?)$")


class KernelError(RuntimeError):
    """Kernel resolution or rendering failure with an actionable message."""


def fetch_json(url, timeout=15):
    with urllib.request.urlopen(url, timeout=timeout) as stream:
        return json.loads(stream.read().decode("utf-8"))


def latest_stable_version(timeout=15):
    """Resolve the newest stable version; never silently substitute an old pin."""
    try:
        releases = fetch_json(RELEASES_URL, timeout)["releases"]
        for release in releases:
            if release.get("moniker") == "stable" and not release.get("iseol"):
                version = str(release["version"])
                if VERSION_PATTERN.fullmatch(version):
                    return version
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        raise KernelError(
            "Cannot determine the latest stable Linux release; retry online or choose an explicit kernel version."
        ) from exc
    raise KernelError(
        "No current stable Linux release found; choose an explicit kernel version."
    )


def sha256_hex(version, timeout=15):
    """Bundled hash first, then the kernel.org checksum manifest."""
    if version in BUNDLED_SHA256:
        return BUNDLED_SHA256[version]
    if not VERSION_PATTERN.fullmatch(version) or version == "latest":
        raise KernelError(f"Invalid kernel version: {version!r}")
    major = version.split(".")[0]
    try:
        with urllib.request.urlopen(
            SHA256SUMS_URL.format(major=major), timeout=timeout
        ) as stream:
            manifest = stream.read().decode("utf-8")
    except OSError as exc:
        raise KernelError(
            f"Cannot reach kernel.org to pin {version}; use a bundled version "
            f"({', '.join(sorted(BUNDLED_SHA256))}) or retry online."
        ) from exc
    pattern = re.compile(
        r"^([0-9a-f]{64})  linux-" + re.escape(version) + r"\.tar\.xz$",
        re.MULTILINE,
    )
    match = pattern.search(manifest)
    if not match:
        raise KernelError(f"No kernel.org checksum for linux-{version}.tar.xz")
    return match.group(1)


def nix_base32(sha256_hex_digest):
    """Encode a 64-char SHA-256 hex digest in Nix base32 (no padding)."""
    alphabet = "0123456789abcdfghijklmnpqrsvwxyz"
    digest = bytes.fromhex(sha256_hex_digest)
    output = []
    for position in range((len(digest) * 8 + 4) // 5 - 1, -1, -1):
        bit = position * 5
        index = bit // 8
        shift = bit % 8
        value = digest[index] >> shift
        if index + 1 < len(digest):
            value |= digest[index + 1] << (8 - shift)
        output.append(alphabet[value & 0x1F])
    return "".join(output)


def source_origin(version, sha256_digest):
    major = version.split(".")[0]
    return (
        "(origin\n"
        f"              (method url-fetch)\n"
        f'              (uri "{SOURCE_URL.format(major=major, version=version)}")\n'
        f'              (sha256 (base32 "{nix_base32(sha256_digest)}")))\n'
    )


@functools.lru_cache(maxsize=16)
def zen_patch(version, timeout=15):
    """Return an exact upstream Zen revision and published asset digest."""
    if version in BUNDLED_ZEN_PATCHES:
        return BUNDLED_ZEN_PATCHES[version]
    if not VERSION_PATTERN.fullmatch(version) or version == "latest":
        raise KernelError(f"Invalid Zen kernel version: {version!r}")
    try:
        releases = fetch_json(ZEN_RELEASES_URL, timeout)
        candidates = []
        for release in releases:
            tag = re.fullmatch(
                r"v" + re.escape(version) + r"-zen([0-9]+)", release.get("tag_name", "")
            )
            if not tag or release.get("draft") or release.get("prerelease"):
                continue
            revision = int(tag.group(1))
            expected_name = f"linux-v{version}-zen{revision}.patch.zst"
            for asset in release.get("assets", []):
                digest = asset.get("digest", "") or ""
                if asset.get("name") == expected_name and re.fullmatch(
                    r"sha256:[0-9a-f]{64}", digest
                ):
                    candidates.append((revision, digest[7:]))
        if candidates:
            return max(candidates)
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        raise KernelError(
            f"Cannot resolve the official Zen patch for Linux {version}; retry online."
        ) from exc
    raise KernelError(
        f"No digest-pinned Zen patch is published for Linux {version}; choose a supported version."
    )


def zen_source_origin(version, sha256_digest):
    revision, digest = zen_patch(version)
    patch_url = ZEN_PATCH_URL.format(version=version, revision=revision)
    source = source_origin(version, sha256_digest).rstrip()
    return source[:-1] + (
        "\n              (modules '((guix build utils)))\n"
        "              (snippet\n"
        "               #~(begin\n"
        '                   (invoke #+(file-append zstd "/bin/zstd")\n'
        '                           "--decompress" "--force"\n'
        "                           #+(origin\n"
        "                               (method url-fetch)\n"
        f'                               (uri "{patch_url}")\n'
        f'                               (sha256 (base32 "{nix_base32(digest)}")))\n'
        '                           "-o" "guix-install-zen.patch")\n'
        '                   (invoke #+(file-append patch "/bin/patch")\n'
        '                           "--batch" "--forward" "-p1"\n'
        '                           "--input" "guix-install-zen.patch")\n'
        '                   (delete-file "guix-install-zen.patch"))))\n'
    )


@functools.lru_cache(maxsize=16)
def resolve(requested, timeout=15):
    """Return (version, sha256-hex) for a requested kernel version."""
    version = str(requested or "").strip() or "latest"
    version = latest_stable_version(timeout) if version == "latest" else version
    return version, sha256_hex(version, timeout)
