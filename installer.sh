#!/bin/sh
#=============================================================
#                        GNU GUIX FULL OS INSTALLER
#                            Powered By Aliens
#=============================================================
set -eu

banner() {
  echo "+-------------------------------------------------------------+"
  echo "|                    GNU GUIX FULL OS INSTALL                  |"
  echo "|                       [ In Code We Trust ]                   |"
  echo "+-------------------------------------------------------------+"
}
banner

[ "$(id -u)" -ne 0 ] && { echo "Run as root"; exit 1; }

# Detect live mode unless user overrides.
ALLOW_NON_LIVE="${ALLOW_NON_LIVE:-}"
if [ -z "${ALLOW_NON_LIVE}" ]; then
  # Heuristic: refuse if root is a writable block device mounted from local disk.
  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  case "${ROOT_SRC}" in
    /dev/*)
      echo "Refusing to run on a non-live system (root on ${ROOT_SRC})."
      echo "Boot a live environment or set ALLOW_NON_LIVE=YES if you know what you’re doing."
      exit 1
      ;;
    *)
      echo "[+] Live environment detected (root: ${ROOT_SRC})."
      ;;
  esac
else
  echo "[!] Override enabled: ALLOW_NON_LIVE=${ALLOW_NON_LIVE}. Proceeding on a running system."
fi

# Detect package manager
if command -v apt >/dev/null; then PKG="apt"
elif command -v dnf >/dev/null; then PKG="dnf"
elif command -v pacman >/dev/null; then PKG="pacman"
else echo "Unsupported distro for dependency bootstrap"; exit 1; fi

# Install dependencies
case "$PKG" in
  apt)
    apt update
    apt install -y wget curl python3 libnss3-tools nscd uidmap parted e2fsprogs dosfstools cryptsetup
    systemctl enable --now nscd || true
    ;;
  dnf)
    dnf install -y wget curl python3 nss-tools nscd shadow-utils parted e2fsprogs dosfstools cryptsetup
    systemctl enable --now nscd || true
    ;;
  pacman)
    pacman -Sy --noconfirm wget curl python nss nscd shadow parted e2fsprogs dosfstools cryptsetup
    systemctl enable --now nscd || true
    ;;
esac

# Fetch Guix installer
if ! command -v guix >/dev/null; then
  echo "[+] Installing Guix prerequisites..."
  wget -q https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh
  chmod +x guix-install.sh
  ./guix-install.sh
  export GUIX_PROFILE="/root/.config/guix/current"
  export PATH="$GUIX_PROFILE/bin:$PATH"
  . "$GUIX_PROFILE/etc/profile"
  rm -f guix-install.sh
fi

# Confirm intent
echo
echo "THIS WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX AS YOUR OS."
echo "Choose disk carefully (e.g., /dev/sda or /dev/nvme0n1)."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -p "Target disk (e.g., /dev/sda): " disk
[ -b "$disk" ] || { echo "Invalid disk: $disk"; exit 1; }

echo
echo "Partition schemes:"
echo "  1) UEFI GPT: EFI + root (ext4)"
echo "  2) UEFI GPT + LUKS: EFI + LUKS(root)"
echo "  3) BIOS MBR: bootable root (ext4)"
read -p "Choice (1/2/3): " scheme

read -p "Type EXACTLY 'YES I WANT GUIX' to continue: " confirm
[ "$confirm" = "YES I WANT GUIX" ] || { echo "Aborted."; exit 1; }

# Wipe and partition
echo "[+] Wiping signatures..."
swapoff -a || true
wipefs -af "$disk"

case "$scheme" in
  1)
    parted --script "$disk" mklabel gpt \
      mkpart ESP fat32 1MiB 512MiB \
      set 1 esp on \
      mkpart root ext4 512MiB 100%
    efi="${disk}1"; rootp="${disk}2"
    mkfs.vfat -F32 "$efi"
    mkfs.ext4 -F "$rootp"
    ;;
  2)
    parted --script "$disk" mklabel gpt \
      mkpart ESP fat32 1MiB 512MiB \
      set 1 esp on \
      mkpart cryptroot 512MiB 100%
    efi="${disk}1"; cryptp="${disk}2"
    mkfs.vfat -F32 "$efi"
    echo "[+] Setting up LUKS (you’ll be prompted for a passphrase)..."
    cryptsetup luksFormat "$cryptp"
    cryptsetup open "$cryptp" guixroot
    mkfs.ext4 -F /dev/mapper/guixroot
    rootp="/dev/mapper/guixroot"
    ;;
  3)
    parted --script "$disk" mklabel msdos \
      mkpart primary ext4 1MiB 100% \
      set 1 boot on
    rootp="${disk}1"
    mkfs.ext4 -F "$rootp"
    efi=""
    ;;
  *)
    echo "Invalid scheme"; exit 1
    ;;
esac

# Mount target
mkdir -p /mnt
mount "$rootp" /mnt
if [ -n "${efi:-}" ]; then
  mkdir -p /mnt/boot/efi
  mount "$efi" /mnt/boot/efi
fi

# Collect system info
read -p "Hostname: " hostname
read -p "Timezone (e.g., America/Sao_Paulo): " timezone
read -p "Locale (e.g., en_US.utf8): " locale
read -p "Keyboard (e.g., br-abnt2): " keyboard
read -p "Username: " username
read -s -p "User password: " upass; echo
read -s -p "Root password: " rpass; echo

echo "Desktop: 1=i3 2=mate 3=xfce 4=none (text)"
read -p "Choice (1/2/3/4): " desk_choice
case "$desk_choice" in
  1) session="i3.desktop"; extra_desktop="i3-wm i3status dmenu"; display_mgr="sddm";;
  2) session="mate.desktop"; extra_desktop="mate"; display_mgr="sddm";;
  3) session="xfce.desktop"; extra_desktop="xfce"; display_mgr="sddm";;
  4) session=""; extra_desktop=""; display_mgr="";;
  *) echo "Invalid"; exit 1 ;;
esac

# Hash passwords
huser=$(python3 - <<PY
import crypt,sys
print(crypt.crypt("${upass}", crypt.mksalt(crypt.METHOD_SHA512)))
PY
)
hroot=$(python3 - <<PY
import crypt,sys
print(crypt.crypt("${rpass}", crypt.mksalt(crypt.METHOD_SHA512)))
PY
)

# Determine UUIDs
root_uuid=$(blkid -s UUID -o value "$rootp")
efi_uuid=""
[ -n "${efi:-}" ] && efi_uuid=$(blkid -s UUID -o value "$efi")

# Prepare config.scm
cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (gnu services)
             (gnu services desktop) (gnu services xorg)
             (gnu packages) (nongnu packages linux) (nongnu system linux-initrd))

(operating-system
  (host-name "$hostname")
  (timezone "$timezone")
  (locale "$locale")
  (keyboard-layout (keyboard-layout "$keyboard"))
  $(if [ -n "${efi:-}" ]; then
cat <<'EFI'
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets '("/boot/efi"))))
EFI
else
cat <<'BIOS'
  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("/dev/sda"))))
BIOS
fi)
  (kernel linux)
  (initrd microcode-initrd)
  (firmware (list linux-firmware))
  (file-systems
    (cons*
      (file-system
        (device (uuid "$root_uuid"))
        (mount-point "/")
        (type "ext4"))
      $(if [ -n "${efi:-}" ]; then
cat <<EFIFS
      (file-system
        (device (uuid "$efi_uuid"))
        (mount-point "/boot/efi")
        (type "vfat"))
EFIFS
fi)
      %base-file-systems))
  (users
    (cons* (user-account
              (name "$username")
              (group "users")
              (password "$huser")
              (supplementary-groups '("wheel" "netdev" "audio" "video")))
           (map (lambda (u)
                  (if (string=? (user-account-name u) "root")
                      (user-account (inherit u) (password "$hroot")) u))
                %base-user-accounts)))
  (packages
    (append
      (list
        ;; essentials
        vim htop git
        ;; networking tools
        nmap openssh tcpdump
        ;; fonts
        font-dejavu
      )
      $(if [ -n "$extra_desktop" ]; then
echo "(map specification->package '($extra_desktop))"
else
echo "'()"
fi)
      %base-packages))
  (services
    (modify-services
      $(if [ -n "$display_mgr" ]; then
echo "(append (list (service sddm-service-type
                          (sddm-configuration
                            (display-server \"x11\")
                            (auto-login-user \"$username\")
                            (auto-login-session \"$session\"))))
        %desktop-services)"
else
echo "%base-services"
fi))))
EOF

# Optional channels (commented out by default)
cat > /mnt/etc/channels.scm <<'EOF'
(list (channel
        (name 'guix)
        (url "https://git.savannah.gnu.org/git/guix.git")))
EOF

# Initialize store and install
echo "[+] Starting cow-store..."
herd start cow-store /mnt || true

echo "[+] Running guix system init (this may take a while)..."
guix system init /mnt/etc/config.scm /mnt

echo "[+] Installation complete. Unmounting and rebooting in 10 seconds..."
sync
umount -R /mnt || true
sleep 10
reboot
