#!/bin/sh
# Build a relocatable tarball of the installer for any GNU/Linux
# distribution: extract, add bin/ to PATH, run `guix-install`.
set -eu

repo_root="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
name="guix-install"
version="$(sed -n 's/^__version__ = "\([^"]*\)"$/\1/p' \
  "$repo_root/guix_installer/__init__.py")"
rel="$name-$version-linux-x86_64"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/$rel/bin" "$staging/$rel/lib/guix-install" \
  "$staging/$rel/share/applications" "$staging/$rel/share/pixmaps"

cp -r "$repo_root/guix_installer" "$repo_root/run.py" "$repo_root/vendor" \
  "$repo_root/assets" "$staging/$rel/lib/guix-install/"
find "$staging/$rel/lib/guix-install" -type d -name '__pycache__' -prune -exec rm -r {} +
cp "$repo_root/packaging/linux/guix-install.desktop" \
  "$staging/$rel/share/applications/"
cp "$repo_root/assets/guix-logo.png" "$staging/$rel/share/pixmaps/"

cat > "$staging/$rel/bin/guix-install" <<'EOF'
#!/bin/sh
# Relocatable entrypoint; the bundled runtime sits next to this script.
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
exec python3 "$ROOT/lib/guix-install/run.py" "$@"
EOF
chmod 755 "$staging/$rel/bin/guix-install"

out="${1:-$repo_root/dist/$rel.tar.gz}"
mkdir -p "$(dirname "$out")"
tar -C "$staging" -czf "$out" "$rel"
echo "$out"
