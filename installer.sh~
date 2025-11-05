#!/bin/sh
#=============================================================\

#             ALWAYS TRUST ALIEN TECHNOLOGY!                  \
 
#=============================================================

set -e

echo "+-------------------------------------------------------------+"
echo "|          GNU GUIX INSTALLATION FROM ANY GNU+LINUX           |"
echo "|                   [ In Code We Trust ]                      |"
echo "+-------------------------------------------------------------+"

[ "$(id -u)" -ne 0 ] && { echo "Run as root"; exit 1; }
\

# Detect package manager\

if command -v apt >/dev/null; then PKG="apt"; elif command -v dnf >/dev/null; then PKG="dnf"; elif command -v pacman >/dev/null; then PKG="pacman"; else echo "Unsupported distro"; exit 1; fi
\

# Install dependencies\

case "$PKG" in
  apt)
    apt update
    apt install -y software-properties-common
    add-apt-repository -y universe || true
    apt update
    apt install -y wget curl python3 libnss3-tools nscd
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
\

# Install Guix if missing\

if ! command -v guix >/dev/null; then
  echo "[+] Installing Guix..."
  wget -q https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh\
  chmod +x guix-install.sh
  ./guix-install.sh || true
  rm guix-install.sh
  guix pull
  . /root/.config/guix/current/etc/profile
fi
\

# Disk\

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
\

# User input\

read -p "Hostname: " hostname
read -p "Timezone: " timezone
read -p "Locale: " locale
read -p "Keyboard: " keyboard
read -p "Username: " username
read -s -p "User pass: " upass; echo
read -s -p "Root pass: " rpass; echo

echo "Desktop: 1=i3 2=mate 3=xfce"
read -p "Choice (1/2/3): " desk_choice
case "$desk_choice" in
  1) session="i3.desktop" ; extra="i3-wm i3status dmenu" ;;
  2) session="mate.desktop" ; extra="mate" ;;
  3) session="xfce.desktop" ; extra="xfce" ;;
  *) echo "Invalid"; exit 1 ;;
esac
\

# Hash passwords\

huser=$(python3 -c "import crypt; print(crypt.crypt('$upass', crypt.mksalt(crypt.METHOD_SHA512)))")
hroot=$(python3 -c "import crypt; print(crypt.crypt('$rpass', crypt.mksalt(crypt.METHOD_SHA512)))")
\

# UUIDs\

root_uuid=(blkid−sUUID−ovalue"(blkid−sUUID−ovalue"{disk}2")
efi_uuid=(blkid−sUUID−ovalue"(blkid−sUUID−ovalue"{disk}1")
\

# config.scm\

cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (gnu packages admin) (gnu packages commencement) (gnu packages package-management) (gnu packages python-xyz) (gnu packages pulseaudio) (gnu packages antivirus) (gnu packages terminals) (gnu packages rust-apps) (gnu packages shells) (gnu packages cmake) (gnu packages build-tools) (gnu packages base) (gnu packages version-control) (gnu packages pythoon) (gnu packages python-build) (gnu packages tor-browsers) (gnu packages linux) (gnu packages video) (gnu packages security-token) (gnu packages file-systems)  (gnu packages llvm) (gnu packages gl) (gnu packages networking) (gnu packages fonts) (gnu packages gnuzilla) (gnu packages tor) (gnu packages tls) (gnu packages password-utils) (gnu packages firmware) (gnu packages) (gnu packages disk) (gnu packages gnupg) (nongnu packages linux) (gnu packages image-viewers) (gnu packages libreoffice) (nongnu system linux-initrd)(gnu services xorg) (gnu services desktop) (gnu packages vpn) (gnu packages freedesktop))

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
                  (supplementary-groups '("wheel" "netdev" "audio" "networking" "video")))
                (map (lambda (u) (if (string=? (user-account-name u) "root")
                                   (user-account (inherit u) (password "$hroot")) u))
                     %base-user-accounts)))
  (packages
 (append
  ;; ===========================
  ;; Browser & Apps
  ;; ===========================
  (list
   icecat
   torbrowser
   libreoffice
   mpv
   feh
   )
  ;; ===========================
  ;; Drivers and Firmware
  ;; ===========================
  (list
   acpi-call-linux-module
   util-linux
   v4l2loopback-linux-module
   mesa
   mesa-headers
   llvm-for-mesa
   libva
   libva-utils
   linux-firmware
   )

  ;; ===========================
  ;; X Utilities (Essential)
  ;; ===========================
  (list
   xterm
   xdpyinfo
   xset
   xwininfo
   xprop
   xpra
   xkill
   setxkbmap
   xmodmap
   xdg-utils
   xrandr
   )

  ;; ===========================
  ;; File and Disk Management
  ;; ===========================
  ( list
   lf
   mergerfs
   parted
   ntfs-3g
   exfat-utils
   exfatprogs
   fuse-exfat
   dosfstools
   bcachefs-tools
   smartmontools
   e2fsprogs
   dosfstools
   xfsprogs
   )

  ;; ===========================
  ;; Development / Build Essentials
  ;; ===========================
  (list
   emacs
   gcc
   gcc-toolchain
   linux-libre-headers
   git
   git-lfs
   python
   python-pip
   cmake
   meson
   binutils
   strace
   edk2-tools
   kitty
   alacritty
   fish
   zoxide
   pfetch
   )

  ;; ===========================
  ;; Security / VPN / Cryptography
  ;; ===========================
  (list
   sysstat
   nftables
   clamav
   gnupg
   libfido2
   firejail
   privoxy
   openvpn
   tor
   torsocks
   nmap
   tcpdump
   openssl
   keepassxc
   )

  ;; ===========================
  ;; System Monitoring and Utilities
  ;; ===========================
  (list
   htop
   btop
   glances
   inxi
   lm-sensors
   net-tools
   fping
   netdiscover
   whois
   macchanger
   procps
   coreutils
   grep
   sed
   nix
   )

  ;; ===========================
  ;; Audio (System-Level)
  ;; ===========================
  (list
   alsa-lib
   alsa-utils
   pulseaudio
   pipewire
   wireplumber
   )

  ;; =========================
  ;; Fonts
  ;; =========================
  (list
   font-iosevka-term
   font-iosevka-term-slab
   font-iosevka-slab
   font-iosevka-etoile
   font-iosevka-curly
   font-iosevka-curly-slab
   font-iosevka-aile
   font-iosevka-ss01
   font-iosevka-ss02
   font-iosevka-ss03
   font-iosevka-ss04
   font-iosevka-ss05
   font-iosevka-ss06
   font-iosevka-ss07
   font-iosevka-ss08
   font-iosevka-ss09
   font-iosevka-ss10
   font-iosevka-ss11
   font-iosevka-ss12
   font-iosevka-ss13
   font-iosevka-ss14
   font-iosevka-ss15
   font-iosevka-ss16
   font-iosevka-ss17
   font-iosevka-ss18
   font-sarasa-gothic
   font-aporetic
   font-adwaita
)
  ;; ===========================
  ;; Base packages 
  ;; ===========================
  %base-packages))

;; System Services
;; This section configures essential system services for connectivity, security,
;; input methods, virtualization, and desktop integration.
   (append (list (service sddm-service-type
                          (sddm-configuration
                            (display-server "x11")
                            (auto-login-user "$username")
                            (auto-login-session "$session"))))
           (modify-services %desktop-services
             (delete gdm-service-type)))))
EOF
\

# channels.scm\

wget -qO /mnt/etc/channels.scm https://short.securityops.co/channels\
chmod +w /mnt/etc/channels.scm
sed -i '/(name '"'"'nonguix)/a\ (commit "43699ceddb6f5f7aa60a646daa44a75e269a3856")' /mnt/etc/channels.scm
\

# Install\

herd start cow-store /mnt
guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt

echo "[+] Done. Rebooting..."
reboot
