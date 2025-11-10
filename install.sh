#!/bin/sh
# install.sh — Install Guix System using custom config.scm and channels.scm
set -euo pipefail

TARGET="/mnt"
CONFIG_FILE="$TARGET/etc/config.scm"
HOST_CHANNELS_URL="https://short.securityops.co/channels"
TMP_CHANNELS="/tmp/channels.scm"
TARGET_CHANNELS="$TARGET/etc/guix/channels.scm"

echo "[+] Checking prerequisites..."
for cmd in wget sed guix; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done

echo "[+] Verifying target config file exists..."
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: $CONFIG_FILE not found. Make sure config.scm was generated and mounted at $TARGET/etc."
  exit 1
fi

echo "[+] Downloading channels.scm..."
wget -q "$HOST_CHANNELS_URL" -O "$TMP_CHANNELS" || { echo "ERROR: failed to download channels.scm"; exit 1; }

echo "[+] Preparing Guix directories in target system..."
mkdir -p "$TARGET/etc/guix"
mkdir -p "$TARGET/root/.config/guix"

echo "[+] Backing up existing channels.scm (if present)..."
if [ -f "$TARGET_CHANNELS" ]; then
  cp -a "$TARGET_CHANNELS" "${TARGET_CHANNELS}.$(date -u +%Y%m%dT%H%M%SZ).bak"
  echo "    backed up existing $TARGET_CHANNELS"
fi

echo "[+] Copying channels.scm into target system..."
cp -a "$TMP_CHANNELS" "$TARGET_CHANNELS"
cp -a "$TMP_CHANNELS" "$TARGET/root/.config/guix/channels.scm"

echo "[+] Fixing ownership and permissions..."
chown -R 0:0 "$TARGET/etc/guix" "$TARGET/root/.config/guix"
chmod 644 "$TARGET_CHANNELS" "$TARGET/root/.config/guix/channels.scm"

echo "[+] Ensuring channels file is writable for guix time-machine..."
chmod +w "$TARGET_CHANNELS" || true

echo "[+] Copying resolv.conf for network access inside target..."
if [ -f /etc/resolv.conf ]; then
  cp -a /etc/resolv.conf "$TARGET/etc/resolv.conf"
fi

echo "[+] Backing up and preparing config.scm edits..."
cp -a "$CONFIG_FILE" "${CONFIG_FILE}.$(date -u +%Y%m%dT%H%M%SZ).bak"

echo "[+] Fixing stray \")\" after (gnu) occurrences in config.scm..."
sed -i 's/(gnu))/ (gnu)/g; s/(gnu))$/ (gnu)/g' "$CONFIG_FILE" || true

echo "[+] Inserting nongnu modules under (use-modules (gnu ...) if missing..."
if grep -q "(use-modules (gnu" "$CONFIG_FILE" && ! grep -q "nongnu packages linux" "$CONFIG_FILE"; then
  sed -i "/(use-modules (gnu/a\\
  (nongnu packages linux)\\
  (nongnu system linux-initrd)" "$CONFIG_FILE"
fi

echo "[+] Ensuring kernel, firmware and initrd are present under (operating-system)..."
if grep -q "(operating-system" "$CONFIG_FILE" && ! grep -q "(kernel linux)" "$CONFIG_FILE"; then
  sed -i "/(operating-system/ a\\
  (kernel linux)\\
  (firmware (list linux-firmware))\\
  (initrd microcode-initrd)" "$CONFIG_FILE"
fi

echo "[+] Final config.scm (first 40 lines):"
sed -n '1,40p' "$CONFIG_FILE" || true

echo "[+] Running guix time-machine to initialize system..."
guix time-machine -C "$TARGET_CHANNELS" -- system init "$CONFIG_FILE" "$TARGET" || {
  echo "ERROR: guix time-machine / system init failed"
  exit 2
}

echo "[+] Cleaning up temporary files..."
rm -f "$TMP_CHANNELS"

echo "[✅] SUCESS!!! Welcome to the GNU GUIX Universe :) "
