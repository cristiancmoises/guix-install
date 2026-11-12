# Changelog

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
