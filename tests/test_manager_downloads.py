"""Offline subprocess acceptance for release mirror and signature policy."""

import os
import re
import shutil
import subprocess
import tempfile
import unittest

from guix_installer import core


class ManagerDownloadTests(unittest.TestCase):
    def shell(self, function_name, body):
        script = (core.ROOT / "vendor/guix-install.sh").read_text()
        function = re.search(rf"(?ms)^{function_name}\(\)\n\{{.*?^\}}\n", script)
        self.assertIsNotNone(function)
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        with tempfile.TemporaryDirectory() as temporary:
            return subprocess.run(
                [
                    bash,
                    "--noprofile",
                    "--norc",
                    "-c",
                    "set -euo pipefail\n"
                    "_debug() { :; }; _msg_info() { :; }; _msg_pass() { :; }; "
                    '_msg_warn() { :; }; die() { echo "$*" >&2; exit 1; }\n'
                    + function.group(0)
                    + body,
                ],
                cwd=temporary,
                env={"PATH": os.environ["PATH"], "LC_ALL": "C"},
                text=True,
                capture_output=True,
                check=False,
                timeout=5,
            )

    def test_index_transport_failure_uses_mirror_and_matching_architecture(self):
        result = self.shell(
            "guix_get_bin_list",
            r"""
GNU_URL=https://ftp.gnu.org/gnu/guix
ARCH_OS=x86_64-linux
wget() {
  [[ "$*" == *'--timeout=15'* && "$*" == *'--tries=1'* ]] || return 99
  [[ "$*" == *mirrors.kernel.org* ]] || return 4
  printf '%s\n' 'guix-binary-1.5.0.x86_64-linux.tar.xz' 'guix-binary-9.9.9.aarch64-linux.tar.xz'
}
guix_get_bin_list "$GNU_URL"
[[ "$BIN_VER" == guix-binary-1.5.0.x86_64-linux ]]
[[ "$GNU_URL" == https://mirrors.kernel.org/gnu/guix ]]
""",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_successful_empty_indexes_are_refused(self):
        result = self.shell(
            "guix_get_bin_list",
            r"""
ARCH_OS=x86_64-linux
wget() { printf '<html>No matching releases</html>'; }
guix_get_bin_list https://ftp.gnu.org/gnu/guix
""",
        )
        self.assertNotEqual(result.returncode, 0)

    def test_archive_transport_failure_retries_complete_pair_on_mirror(self):
        result = self.shell(
            "guix_get_bin",
            r"""
wget() {
  [[ "$*" != --help ]] || { printf '%s\n' '--show-progress'; return; }
  local out='' directory='' value
  local urls=()
  while (( $# )); do
    case "$1" in
      -O) shift; out="$1" ;;
      -P) shift; directory="$1" ;;
      https://*) urls+=("$1") ;;
    esac
    shift
  done
  for value in "${urls[@]}"; do
    local target="${out:-$directory/${value##*/}}"
    [[ "$value" == https://mirrors.kernel.org/* ]] || { printf partial > "$target"; return 4; }
    printf '%s' "$value" > "$target"
  done
}
guix_verify_release() {
  [[ "$(cat "$1")" == https://mirrors.kernel.org/* ]]
  [[ "$(cat "$2")" == https://mirrors.kernel.org/* ]]
}
guix_get_bin https://ftp.gnu.org/gnu/guix guix-binary-1.5.0.x86_64-linux "$PWD"
""",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_signature_never_retries_another_mirror(self):
        result = self.shell(
            "guix_get_bin",
            r"""
wget() {
  [[ "$*" != --help ]] || { printf '%s\n' '--show-progress'; return; }
  printf '%s\n' "$*" >> calls
  while (( $# )); do
    if [[ "$1" == -O ]]; then shift; printf payload > "$1"; fi
    shift
  done
}
guix_verify_release() { return 1; }
trap '! grep -q mirrors.kernel.org calls || exit 99' EXIT
guix_get_bin https://ftp.gnu.org/gnu/guix guix-binary-1.5.0.x86_64-linux "$PWD"
""",
        )
        self.assertEqual(result.returncode, 1, result.stderr)
