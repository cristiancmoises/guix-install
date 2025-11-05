#!/bin/sh
#=============================================================
#          GNU GUIX - THE DISTRO HOPPING KILLER!
#=============================================================

set -e

echo "+-------------------------------------------------------------+"
echo "|            GNU GUIX INSTALLATION FROM ANY GNU+LINUX         |"
echo "|                    [ In Code We Trust ]                     |"
echo "+-------------------------------------------------------------+"

[ "$(id -u)" -ne 0 ] && { echo "Run as root"; exit 1; }

# Detect package manager
if command -v apt >/dev/null; then PKG="apt"; elif command -v dnf >/dev/null; then PKG="dnf"; elif command -v pacman >/dev/null; then PKG="pacman"; else echo "Unsupported distro"; exit 1; fi

# Install dependencies
case "$PKG" in
  apt)
    add-apt-repository -y universe || true
    apt update
    apt install -y wget curl python3 nss-certs nscd
    ;;
  dnf)
    dnf install -y wget curl python3 nss-tools nscd
    systemctl enable --now nscd
    ;;
  pacman)
    pacman -Sy --noconfirm wget curl python nss nscd
    systemctl enable --now nscd
    ;;
esac

# Install Guix if missing
if ! command -v guix >/dev/null; then
  echo "[+] Installing Guix..."
  wget -q https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh
  chmod +x guix-install.sh
  ./guix-install.sh || true
  rm guix-install.sh
  guix pull
  . /root/.config/guix/current/etc/profile
fi

# Disk
lsblk
read -p "Target disk (e.g. /dev/sda): " disk
read -p "ERASE $disk? (y/n): " c; [ "$c" != "y" ] && exit 1

parted -s "$disk" mklabel gpt
parted -s "$disk" mkpart ESP fat32 1MiB 512MiB
parted -s "$disk" set 1 esp on
parted -s "$disk" mkpart root ext4 512MiB 100%
sync
mkfs.vfat -F32 "${disk}1"
mkfs.ext4 -F "${disk}2"

mount "${disk}2" /mnt
mkdir -p /mnt/boot/efi
mount "${disk}1" /mnt/boot/efi

# User input
read -p "Hostname: " hostname
read -p "Timezone: " timezone
read -p "Locale: " locale
read -p "Keyboard: " keyboard
read -p "Username: " username
read -s -p "User pass: " upass; echo
read -s -p "Root pass: " rpass; echo
read -p "Extra packages: " pkgs

echo "Desktop: 1=i3 2=mate 3=xfce"
read -p "Choice (1/2/3): " desk_choice
case "$desk_choice" in
  1) session="i3.desktop" ; extra="i3-wm i3status dmenu" ;;
  2) session="mate.desktop" ; extra="mate" ;;
  3) session="xfce.desktop" ; extra="xfce" ;;
  *) echo "Invalid"; exit 1 ;;
esac

# Hash passwords
huser=$(python3 -c "import crypt; print(crypt.crypt('$upass', crypt.mksalt(crypt.METHOD_SHA512)))")
hroot=$(python3 -c "import crypt; print(crypt.crypt('$rpass', crypt.mksalt(crypt.METHOD_SHA512)))")

# UUIDs
root_uuid=$(blkid -s UUID -o value "${disk}2")
efi_uuid=$(blkid -s UUID -o value "${disk}1")

# config.scm
cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (nongnu packages linux) (nongnu system linux-initrd)
             (gnu services xorg) (gnu services desktop))

(operating-system
  (host-name "$hostname")
  (timezone "$timezone")
  (locale "$locale")
  (keyboard-layout (keyboard-layout "$keyboard"))
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets '("/boot/efi"))))
  (kernel linux)
  (initrd microcode-initrd)
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
                  (password "$huser")
                  (supplementary-groups '("wheel" "netdev" "networking" "audio" "video")))
                (map (lambda (u) (if (string=? (user-account-name u) "root")
                                   (user-account (inherit u) (password "$hroot")) u))
                     %base-user-accounts)))
  (packages (append (map specification->package '($extra $pkgs)) %base-packages))
  (services
   (append (list (service sddm-service-type
                          (sddm-configuration
                            (display-server "x11")
                            (auto-login-user "$username")
                            (auto-login-session "$session"))))
           (modify-services %desktop-services
             (delete gdm-service-type)))))
EOF

# channels.scm
wget -qO /mnt/etc/channels.scm https://short.securityops.co/channels
chmod +w /mnt/etc/channels.scm
sed -i '/(name '"'"'nonguix)/a\    (commit "43699ceddb6f5f7aa60a646daa44a75e269a3856")' /mnt/etc/channels.scm

# Install
herd start cow-store /mnt
guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt

echo "[+] Done. Rebooting..."
reboot
