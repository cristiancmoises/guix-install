#!/usr/bin/env bash
# Shared GUI / CLI entrypoint; no host modifications occur in this launcher.
set -euo pipefail
installer_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' 'Python 3.10+ is required. Install it with your distribution package manager.' >&2
    exit 1
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
    printf '%s\n' 'Python 3.10+ is required.' >&2
    exit 1
}
if [ "$#" -eq 0 ]; then
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && python3 -c 'import tkinter' 2>/dev/null; then
        set -- gui
    else
        set -- wizard
    fi
fi
exec python3 "$installer_dir/run.py" "$@"
