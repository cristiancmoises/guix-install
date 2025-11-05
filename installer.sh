#!/bin/sh
#=============================================================
#            GNU GUIX - THE DISTRO HOPING KILLER!
#=============================================================

echo "+-------------------------------------------------------------+"
echo "|       GNU GUIX INSTALLATION FROM ANY GNU+LINUX             |"
echo "|                [ In Code We Trust ]                        |"
echo "+-------------------------------------------------------------+"
echo ""
Check if root

if [ "$(id -u)" -ne 0 ]; then
echo "Please run as root"
exit 1
fi
Install Guix package manager if not installed

if ! command -v guix >/dev/null 2>&1; then
echo "[+] Installing Guix package manager..."
wget https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh
chmod +x guix-install.sh
./guix-install.sh
rm guix-install.sh
guix pull
. /root/.config/guix/current/etc/profile
fi
Prompt for partitions

echo "[+] List available disks:"
lsblk
read -p "Target disk (e.g. /dev/sda): " disk
read -p "This will erase $disk. Continue? (y/n): " confirm
if [ "$confirm" != "y" ]; then exit 1; fi
Create partitions

echo "[+] Partitioning $disk..."
parted -s "$disk" mklabel gpt
parted -s "$disk" mkpart ESP fat32 1MiB 512MiB
parted -s "$disk" set 1 esp on
parted -s "$disk" mkpart root ext4 512MiB 100%
Format partitions

mkfs.vfat -F32 "${disk}1"
mkfs.ext4 -F "${disk}2"
Mount partitions

mount "${disk}2" /mnt
mkdir -p /mnt/boot/efi
mount "${disk}1" /mnt/boot/efi
Prompt for system config

read -p "Hostname: " hostname
read -p "Timezone (e.g. America/New_York): " timezone
read -p "Locale (e.g. en_US.utf8): " locale
read -p "Keyboard layout (e.g. us): " keyboard
read -p "Username: " username
read -s -p "User password: " user_pass
echo
read -s -p "Root password: " root_pass
echo
read -p "Additional packages (space separated): " extra_packages
Hash passwords (using python for portability)

hashed_user=$(python3 -c "import crypt; print(crypt.crypt('$user_pass', crypt.mksalt(crypt.METHOD_SHA512)))")
hashed_root=$(python3 -c "import crypt; print(crypt.crypt('$root_pass', crypt.mksalt(crypt.METHOD_SHA512)))")
Get UUIDs

root_uuid=(blkid−sUUID−ovalue"(blkid−sUUID−ovalue"{disk}2")
efi_uuid=(blkid−sUUID−ovalue"(blkid−sUUID−ovalue"{disk}1")
Generate config.scm

CONFIG_FILE="/mnt/etc/config.scm"
mkdir -p /mnt/etc
cat <<EOF > "$CONFIG_FILE"
(use-modules (gnu) (nongnu packages linux) (nongnu system linux-initrd))

(operating-system
(host-name "$hostname")
(timezone "$timezone")
(locale "$locale")
(keyboard-layout (keyboard-layout "$keyboard"))
(bootloader (bootloader-configuration
(bootloader grub-efi-bootloader)
(targets '("/boot/efi"))
(keyboard-layout (keyboard-layout "$keyboard"))))
(kernel linux)
(firmware (list linux-firmware))
(file-systems (cons* (file-system
(device (uuid "$root_uuid"))
(mount-point "/")
(type "ext4"))
(file-system
(device (uuid "$efi_uuid" 'fat32))
(mount-point "/boot/efi")
(type "vfat"))
%base-file-systems))
(users (cons* (user-account
(name "$username")
(group "users")
(password "$hashed_user")
(supplementary-groups '("wheel" "netdev" "audio" "video")))
(map (lambda (u)
(if (string= (user-account-name u) "root")
(user-account (inherit u) (password "$hashed_root"))
u))
%base-user-accounts)))
(packages (append (map specification->package (list $extra_packages))
%base-packages))
(services %desktop-services))
EOF
Channels

CHANNELS_URL="https://short.securityops.co/channels"
CHANNELS_FILE="/mnt/etc/channels.scm"
Download channels.scm

echo "[+] Downloading channels.scm..."
wget -q "$CHANNELS_URL" -O "$CHANNELS_FILE"
Fix by adding commit to nonguix

chmod +w "$CHANNELS_FILE"
sed -i '/(name \x27nonguix)/a\    (commit "43699ceddb6f5f7aa60a646daa44a75e269a3856")' "$CHANNELS_FILE"
Start cow-store

echo "[+] Starting cow-store /mnt..."
herd start cow-store /mnt
Initialize system

echo "[+] Initializing Guix system..."
guix time-machine -C "$CHANNELS_FILE" -- system init "$CONFIG_FILE" /mnt
Reboot

echo "[+] Installation complete. Rebooting..."
reboot
