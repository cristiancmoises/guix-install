# Changelog

## 0.4.0 — 2026-11-13

- Add kernel choice: linux-libre (default), linux and securityops; the two
  blob kernels always build the newest stable kernel.org release (resolved at
  plan time, SHA-256-pinned in the generated configuration, 7.3.4 today).
- Reproduce the maintainer's in-use securityops kernel: nonguix base,
  vanilla source, `#:defconfig` from the bundled defconfig and hardened
  runtime `kernel-arguments`; `--kernel-version` pins an exact release.
- Add selectable authenticated channels with short EN/PT descriptions
  (nonguix, securityops, small-guix, sops-guix, gocix, guix-xlibre) with
  automatic dependency closure and dynamically generated channels.scm.
- Add desktops KDE Plasma, Sway, XMonad on XLibre and River + XMonad
  (Wayland) with a generated GDM session entry, XLibre X server override
  and pre-wired Sway/River key bindings.
- Add multi-select terminals (wezterm, kitty, foot, alacritty) and browsers
  (torbrowser, librewolf, chromium, zen-browser) with a configurable default
  in the GUI, wizard and CLI; browsers come from the authenticated
  securityops channel, which is added automatically.
- Add Windows migration tooling: raw disk writer via PowerShell/ctypes with
  volume lock and read-back verification, PyInstaller one-file build and
  WiX MSI, built by GitHub Actions on windows-latest.
- Fix restrictive initialization umask (077 to 022 with explicit private
  file permissions); keep partition/mount identity and cancellation fixes.
- Extend evaluation checks to all three kernels, every desktop and browser
  sets with local nonguix/securityops checkouts; update bilingual docs and
  screenshots.
- Preserve the existing VM/boot qualification limitation and authenticated
  channel pins.

## 0.3.0 — 2026-11-11

- Add attributed official GNU Guix SVG, transparent GUI/window icon, and derived ASCII CLI mark; bundle all assets offline.
- Fix acceptance of unknown disk read-only state; bind new partitions to kernel identity and size before formatting; verify mount ownership before access and cleanup.
- Bound inventory queries and use a lightweight read-only daemon handshake instead of enumerating dead store paths.
- Keep Tk responsive with background read-only queries and discard stale results after settings/theme/language changes.
- Verify bootstrap files with at most four parallel requests; handle transport timeout fallback without bypassing integrity failures.
- Add regression/native GUI checks, controlled HTTPS download benchmark, updated screenshots, packaging and bilingual documentation.
- Preserve the existing VM/boot qualification limitation and authenticated Guix/Nonguix compatibility pins.

## 0.2.0 — 2026-11-11

- Replace the legacy disk installer and `/mnt` rewrite path with a shared Python backend, terminal wizard and unprivileged native Tk GUI.
- Add package-manager and Guix System modes, read-only planning, prerequisite checks and explicit disk consent.
- Add root/live-media, mount, swap, holder and disk-identity checks, private command logs and non-recursive mount cleanup.
- Vendor the unchanged, SHA-256-pinned upstream installer; retain authenticated channel introductions and explicit system-channel commits.
- Default to black, white text, golden yellow and orange; offer a white/black light theme in GUI and CLI.
- Add English/PT-BR documentation, real screenshots, source bootstrap integrity checks, non-destructive tests and CI.
- No completed disk-installation or boot qualification is claimed for this release.
