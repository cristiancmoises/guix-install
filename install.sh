#!/bin/bash
set -e

# 1️⃣ Start the herd service
echo "[+] Starting herd for cow-store..."
herd start cow-store /mnt

# 2️⃣ Download channels.scm
echo "[+] Downloading channels.scm..."
wget https://short.securityops.co/channels -O /mnt/etc/channels.scm
wget https://short.securityops.co/channels -O /etc/channels.scm

# 3️⃣ Make channels.scm writable
chmod +w /mnt/etc/channels.scm

# 4️⃣ Insert modules/packages/system entries into config.scm
CONFIG_FILE="/mnt/etc/config.scm"
echo "[+] Modifying config.scm..."

# Insert (use-modules (gnu)) if not present
grep -q "(use-modules (gnu))" "$CONFIG_FILE" || \
    sed -i "1i(use-modules (gnu)" "$CONFIG_FILE"

# Insert under (nongnu packages linux)
sed -i "/(nongnu packages linux)/a\    ;; added line" "$CONFIG_FILE"

# Insert under (nongnu system linux-initrd)
sed -i "/(nongnu system linux-initrd))/a\    ;; added line" "$CONFIG_FILE"

# Insert kernel, firmware, initrd inside operating-system
sed -i "/(operating-system/ {
    :a
    N
    /)/!ba
    s/\((operating-system[^\)]*\)\)/\1\n  (kernel linux)\n  (firmware (list linux-firmware))\n  (initrd microcode-initrd)/" "$CONFIG_FILE"
}

# 5️⃣ Run guix time-machine system init
echo "[+] Running guix time-machine..."
guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt

echo "[+] Done!"
