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
    "lsm=landlock,yama,apparmor",
    "apparmor=1",
    "security=apparmor",
    "random.trust_cpu=off",
    "preempt=full",
    "transparent_hugepage=madvise",
    "numa_balancing=disable",
)

VERSION_PATTERN = re.compile(r"^(?:latest|\d+\.\d+(?:\.\d+)?)$")


class KernelError(RuntimeError):
    """Kernel resolution or rendering failure with an actionable message."""


def fetch_json(url, timeout=15):
    with urllib.request.urlopen(url, timeout=timeout) as stream:
        return json.loads(stream.read().decode("utf-8"))


def latest_stable_version(timeout=15):
    """Resolve the newest non-EOL stable kernel.org version, offline-safe."""
    try:
        releases = fetch_json(RELEASES_URL, timeout)["releases"]
        for release in releases:
            if release.get("moniker") == "stable" and not release.get("iseol"):
                version = str(release["version"])
                if VERSION_PATTERN.fullmatch(version):
                    return version
    except (OSError, ValueError, KeyError):
        pass
    return DEFAULT_LATEST


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
def resolve(requested, timeout=15):
    """Return (version, sha256-hex) for a requested kernel version."""
    version = str(requested or "").strip() or "latest"
    version = latest_stable_version(timeout) if version == "latest" else version
    return version, sha256_hex(version, timeout)
