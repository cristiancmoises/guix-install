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
from guix_installer.core import Options, render_config
for desktop in ['gnome', 'xfce', 'minimal']:
    config = render_config(Options(mode='system', disk='/dev/example', desktop=desktop),
                           '11111111-1111-1111-1111-111111111111', 'ABCD-1234')
    (Path(sys.argv[1]) / f'{desktop}.scm').write_text(config)
PY
guix repl -q -- "$repo_dir/tests/check-guix.scm" \
    "$check_dir/gnome.scm" "$check_dir/xfce.scm" "$check_dir/minimal.scm" \
    "$repo_dir/channel.scm" "$repo_dir/channels.scm"
