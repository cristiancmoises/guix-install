#!/bin/sh
# install.sh — Install Guix System using custom config.scm and channels.scm
set -e

TARGET="/mnt"
CONFIG_FILE="$TARGET/etc/config.scm"
HOST_CHANNELS_URL="https://short.securityops.co/channels"
TMP_CHANNELS="/tmp/channels.scm"

echo "[+] Checking prerequisites..."
command -v wget >/dev/null 2>&1 || { echo "ERROR: wget not found"; exit 1; }

echo "[+] Downloading channels.scm..."
wget -q "$HOST_CHANNELS_URL" -O "$TMP_CHANNELS" || { echo "ERROR: failed to download channels.scm"; exit 1; }

echo "[+] Preparing Guix directories in target system..."
mkdir -p "$TARGET/etc/guix"
mkdir -p "$TARGET/root/.config/guix"

echo "[+] Copying channels.scm into target system..."
cp "$TMP_CHANNELS" "$TARGET/etc/guix/channels.scm"
cp "$TMP_CHANNELS" "$TARGET/root/.config/guix/channels.scm"

echo "[+] Fixing ownership and permissions..."
chown -R 0:0 "$TARGET/etc/guix" "$TARGET/root/.config/guix"
chmod 644 "$TARGET/etc/guix/channels.scm"
chmod 644 "$TARGET/root/.config/guix/channels.scm"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: $CONFIG_FILE not found. Make sure config.scm was generated and mounted at $TARGET/etc."
  exit 1
fi

# 4️⃣ Fix (gnu)) -> (gnu) in config.scm
echo "[+] Fixing (gnu)) -> (gnu) in config.scm..."
sed -i 's/(gnu))/\(gnu\)/g' "$CONFIG_FILE"

# 5️⃣ Insert nongnu packages/system directly under (use-modules (gnu)
echo "[+] Inserting nongnu packages/system under (use-modules (gnu))..."
sed -i "/(use-modules (gnu)/a\\
  (nongnu packages linux)\\
  (nongnu system linux-initrd)" "$CONFIG_FILE"

# 6️⃣ Insert kernel, firmware, initrd directly under (operating-system)
echo "[+] Inserting kernel, firmware, initrd under (operating-system)..."
sed -i "/(operating-system/ a\\
  (kernel linux)\\
  (firmware (list linux-firmware))\\
  (initrd microcode-initrd)" "$CONFIG_FILE"

echo "[+] Copying resolv.conf for network access inside target..."
cp /etc/resolv.conf "$TARGET/etc/resolv.conf"

# Create script to run inside target
RUN_SCRIPT="$TARGET/tmp/.run-guix-init.sh"
cat > "$RUN_SCRIPT" <<'EOF'
#!/bin/sh
set -e
CHANNELS="/etc/guix/channels.scm"
CONFIG="/etc/config.scm"

echo "[+] Running guix pull with channels..."
guix pull --channels="$CHANNELS" || { echo "ERROR: guix pull failed"; exit 1; }

echo "[+] Running guix system init..."
guix system init "$CONFIG" / || { echo "ERROR: guix system init failed"; exit 2; }

echo "[+] Guix System initialized successfully."
EOF

chmod 700 "$RUN_SCRIPT"
chown 0:0 "$RUN_SCRIPT"

# Run inside target using systemd-nspawn or chroot
if command -v systemd-nspawn >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  echo "[+] Using systemd-nspawn to enter target..."
  systemd-nspawn -D "$TARGET" /bin/sh -c "/tmp/.run-guix-init.sh"
else
  echo "[+] Using chroot fallback (requires root)..."
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: chroot requires root privileges."
    exit 3
  fi

  mount --bind /dev "$TARGET/dev"
  mount --bind /proc "$TARGET/proc"
  mount --bind /sys "$TARGET/sys"
  mount --bind /run "$TARGET/run"

  chroot "$TARGET" /bin/sh -c "/tmp/.run-guix-init.sh"

  umount "$TARGET/run"
  umount "$TARGET/sys"
  umount "$TARGET/proc"
  umount "$TARGET/dev"
fi

echo "[+] Cleaning up temporary files..."
rm -f "$TMP_CHANNELS" "$RUN_SCRIPT"

echo "[✅] Installation complete. You can now reboot into your new Guix System."
