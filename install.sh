#!/bin/sh
set -e

CONFIG_FILE="/mnt/etc/config.scm"

# 1️⃣ Start the herd service
echo "[+] Starting herd for cow-store..."
herd start cow-store /mnt

# 2️⃣ Download channels.scm
echo "[+] Downloading channels.scm..."
wget https://short.securityops.co/channels -O /mnt/etc/channels.scm
wget https://short.securityops.co/channels -O /etc/channels.scm

# 3️⃣ Make channels.scm writable
chmod +w /mnt/etc/channels.scm

# 4️⃣ Fix (gnu)) -> (gnu) in config.scm
echo "[+] Fixing (gnu)) -> (gnu) in config.scm..."
sed -i 's/(gnu))/\(gnu\)/g' "$CONFIG_FILE"

# 5️⃣ Insert lines above (gnu)
echo "[+] Inserting nongnu packages/system above (gnu)..."
sed -i "/(gnu)/i\\
(nongnu packages linux)\\
(nongnu system linux-initrd))" "$CONFIG_FILE"

# 6️⃣ Insert kernel, firmware, initrd inside operating-system
sed -i "/(operating-system/{
:a
N
/)/!ba
s/\((operating-system[^\)]*)\)/\1\n  (kernel linux)\n  (firmware (list linux-firmware))\n  (initrd microcode-initrd)/
}" "$CONFIG_FILE"

# 7️⃣ Run guix time-machine system init
echo "[+] Running guix time-machine..."
guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt

echo "[+] Done!"
