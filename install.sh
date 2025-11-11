#!/bin/sh
# install.sh — Install Guix System using custom config.scm and channels.scm
set -euo pipefail

TARGET="/mnt/etc"
CONFIG_FILE="$TARGET/config.scm"
HOST_CHANNELS_URL="https://short.securityops.co/channels"
TMP_CHANNELS="/tmp/channels.scm"
TARGET_CHANNELS="$TARGET/channels.scm"

echo "[+] Starting Cow-Store..."
herd start cow-store /mnt
echo "[+] Downloading channels.scm..."
wget -q "$HOST_CHANNELS_URL" -O "$TMP_CHANNELS" || { echo "ERROR: failed to download channels.scm"; exit 1; }


echo "[+] Copying channels.scm into target system..."
cp -a "$TMP_CHANNELS" "$TARGET_CHANNELS"
cp -a "$TMP_CHANNELS" "/root/.config/guix/channels.scm"

echo "[+] Ensuring channels file is writable for guix time-machine..."
chmod +w "$TARGET_CHANNELS" || true

echo "[+] Fixing stray \")\" after (gnu) occurrences in config.scm..."
# Replace common accidental "(gnu))" with "(gnu)"
sed -i 's/(gnu))/ (gnu)/g; s/(gnu))$/ (gnu)/g' "$CONFIG_FILE" || true

echo "[+] Inserting nongnu lines under (use-modules (gnu) or (gnu) if missing..."

# Lines to insert (exact text)
INSERT_LINE1="  (nongnu packages linux)"
INSERT_LINE2="  (nongnu system linux-initrd))"

# Helper: test whether the lines already exist
if grep -qF "$INSERT_LINE1" "$CONFIG_FILE" || grep -qF "$INSERT_LINE2" "$CONFIG_FILE"; then
  echo "    Nongnu lines already present in $CONFIG_FILE; skipping insertion."
else
  # Try to insert after a line that contains "(use-modules (gnu"
  if grep -q "(use-modules (gnu" "$CONFIG_FILE"; then
    sed -i "/(use-modules (gnu/a\\
$INSERT_LINE1\\
$INSERT_LINE2" "$CONFIG_FILE"
    echo "    Inserted under line matching (use-modules (gnu"
  # If not found, try to insert after a line that is just "(gnu)"
  elif grep -q "^(gnu)$" "$CONFIG_FILE"; then
    sed -i "/^(gnu)$/a\\
$INSERT_LINE1\\
$INSERT_LINE2" "$CONFIG_FILE"
    echo "    Inserted under a bare (gnu) line"
  else
    # As a fallback, insert after the first (use-modules line (any)
    if grep -q "(use-modules" "$CONFIG_FILE"; then
      sed -i "0,/(use-modules/{/use-modules/ a\\
$INSERT_LINE1\\
$INSERT_LINE2
}" "$CONFIG_FILE"
      echo "    Inserted after the first (use-modules line as fallback"
    else
      # If no use-modules found, prepend near top after first line
      awk -v l1="$INSERT_LINE1" -v l2="$INSERT_LINE2" 'NR==1{print; print l1; print l2; next} {print}' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
      echo "    No (use-modules) found; prepended nongnu lines after first line"
    fi
  fi
fi

echo "[+] Ensuring kernel, firmware and initrd are present under (operating-system)..."
if grep -q "(operating-system" "$CONFIG_FILE" && ! grep -q "(kernel linux)" "$CONFIG_FILE"; then
  sed -i "/(operating-system/ a\\
  (kernel linux)\\
  (firmware (list linux-firmware))\\
  (initrd microcode-initrd)" "$CONFIG_FILE" || true
  echo "    Inserted kernel/firmware/initrd"
else
  echo "    Kernel entry already present or (operating-system) not found; skipped"
fi

echo "[+] Final config.scm (first 80 lines):"
sed -n '1,80p' "$CONFIG_FILE" || true

echo "[+] Running guix time-machine to initialize system..."
guix time-machine -C "$TARGET_CHANNELS" -- system init "$CONFIG_FILE" /mnt || {
  echo "ERROR: guix time-machine / system init failed"
  exit 2
}

echo "[✅] Installation complete. You can now reboot into your new Guix System."
