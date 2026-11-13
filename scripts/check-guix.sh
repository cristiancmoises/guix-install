#!/usr/bin/env bash
# Evaluate generated Guix records without building or modifying any system.
set -euo pipefail
repo_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
cd "$repo_dir"
python3 - "$check_dir" <<'PY'
from pathlib import Path
import sys
from guix_installer import channels as channels_catalog
from guix_installer.core import Options, render_config

destination = Path(sys.argv[1])
uuid = '11111111-1111-1111-1111-111111111111'
configs = [
    Options(mode='system', disk='/dev/example', desktop='gnome'),
    Options(mode='system', disk='/dev/example', desktop='minimal'),
    Options(mode='system', disk='/dev/example', desktop='xfce',
            kernel='linux', kernel_version='7.3.4',
            terminals=('kitty', 'foot'), default_terminal='kitty',
            browsers=('librewolf', 'zen-browser'), default_browser='librewolf'),
    Options(mode='system', disk='/dev/example', desktop='sway',
            kernel='linux', kernel_version='7.3.4', terminals=('foot',),
            default_terminal='foot'),
    Options(mode='system', disk='/dev/example', desktop='river-xmonad',
            terminals=('alacritty',), default_terminal='alacritty'),
    Options(mode='system', disk='/dev/example', desktop='xmonad-xlibre',
            kernel='linux', kernel_version='7.3.4', terminals=('wezterm',),
            default_terminal='wezterm'),
    Options(mode='system', disk='/dev/example', desktop='kde',
            terminals=('kitty', 'wezterm'), default_terminal='kitty',
            browsers=('torbrowser', 'chromium'), default_browser='torbrowser'),
    Options(mode='system', disk='/dev/example', desktop='minimal',
            kernel='securityops', kernel_version='7.3.4',
            channels=('securityops', 'small-guix')),
    Options(mode='system', disk='/dev/example', desktop='gnome',
            browsers=('torbrowser', 'librewolf', 'chromium', 'zen-browser'),
            default_browser='zen-browser'),
]
for options in configs:
    terminal_part = '-'.join(options.terminals) or 'none'
    browser_part = '-'.join(options.browsers) or 'none'
    name = f'{options.kernel}-{options.desktop}-{terminal_part}-{browser_part}.scm'
    (destination / name).write_text(render_config(options, uuid, 'ABCD-1234'))
(destination / 'guix-only-channels.scm').write_text(channels_catalog.render((), 'linux-libre'))
(destination / 'all-channels.scm').write_text(
    channels_catalog.render(
        ('securityops', 'small-guix'), 'securityops',
        browsers=('torbrowser', 'zen-browser'),
    )
)
print(' '.join(sorted(path.name for path in destination.iterdir())))
PY

nonguix_path=$(
    find "$HOME/.cache/guix/checkouts" -maxdepth 3 -type d \
        -name packages -path '*/nongnu/*' 2>/dev/null | head -1
)
if [ -n "${nonguix_path:-}" ]; then
    nonguix_path=$(dirname "$(dirname "$nonguix_path")")
fi
securityops_path=$(
    find "$HOME/.cache/guix/checkouts" -maxdepth 4 -type f \
        -name tor.scm -path '*/securityops/packages/*' 2>/dev/null | head -1
)
if [ -n "${securityops_path:-}" ]; then
    securityops_path=$(dirname "$(dirname "$(dirname "$securityops_path")")")
fi

mapfile -t configs < <(find "$check_dir" -maxdepth 1 -name '*.scm' ! -name '*channels.scm' | sort)
mapfile -t base_configs < <(printf '%s\n' "${configs[@]}" | grep -vE '(river-xmonad|-torbrowser|-librewolf|-chromium|-zen-browser)\.scm$' || true)
if [ -n "${nonguix_path:-}" ] && [ -f /etc/securityops.defconfig ]; then
    if [ -n "${securityops_path:-}" ]; then
        GUIX_PACKAGE_PATH="$nonguix_path:$securityops_path" guix repl -q -- \
            "$repo_dir/tests/check-guix.scm" \
            "${configs[@]}" \
            "$check_dir/guix-only-channels.scm" "$check_dir/all-channels.scm"
    else
        echo "SKIP securityops package evaluation (no local checkout); evaluating the rest"
        GUIX_PACKAGE_PATH="$nonguix_path" guix repl -q -- \
            "$repo_dir/tests/check-guix.scm" \
            "${base_configs[@]}" \
            "$check_dir/guix-only-channels.scm" "$check_dir/all-channels.scm"
    fi
else
    echo "SKIP nonguix evaluation (no local checkout or defconfig); evaluating base only"
    base_config=$(find "$check_dir" -maxdepth 1 -name 'linux-libre-gnome-*.scm' | head -1)
    guix repl -q -- "$repo_dir/tests/check-guix.scm" \
        "$base_config" \
        "$check_dir/guix-only-channels.scm" "$check_dir/all-channels.scm"
fi
