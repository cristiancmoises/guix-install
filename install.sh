#!/usr/bin/env bash
# Compatibility entrypoint. Replaces the old /mnt rewrite script.
set -euo pipefail
installer_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
printf '%s\n' 'Use installer.sh for the GUI, wizard, or a read-only plan. Legacy /mnt rewrites were removed.' >&2
exec "$installer_dir/installer.sh" "$@"
