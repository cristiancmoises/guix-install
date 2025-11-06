#!/usr/bin/env bash
#=============================================================
#                        GNU GUIX FULL OS INSTALLER
#                            Powered By Aliens
#=============================================================
set -euo pipefail

banner() {
  echo "+-------------------------------------------------------------+"
  echo "|                    GNU GUIX FULL OS INSTALL                  |"
  echo "|                       [ In Code We Trust ]                   |"
  echo "+-------------------------------------------------------------+"
}
banner

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

# Optional proxies (export before running or uncomment and set)
# export http_proxy="http://proxy:port"
# export https_proxy="http://proxy:port"

# Detect live mode unless user overrides.
ALLOW_NON_LIVE="${ALLOW_NON_LIVE:-}"
if [[ -z "${ALLOW_NON_LIVE}" ]]; then
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

# Install dependencies (partitioning, filesystems, LUKS, certs, compression)
case "$PKG" in
  apt)
    apt update
    apt install -y wget curl ca-certificates python3 libnss3-tools nscd uidmap \
      parted e2fsprogs dosfstools cryptsetup xz-utils btrfs-progs xfsprogs
    systemctl enable --now nscd || true
    ;;
  dnf)
    dnf install -y wget curl ca-certificates python3 nss-tools nscd shadow-utils \
      parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs
    systemctl enable --now nscd || true
    ;;
  pacman)
    pacman -Sy --noconfirm wget curl ca-certificates python nss nscd shadow \
      parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs
    systemctl enable --now nscd || true
    ;;
esac

# Helper: robust fetch with retries and fallbacks
fetch_with_fallback() {
  # $1: output file, $2..: urls
  local out="$1"; shift
  rm -f "$out"
  for u in "$@"; do
    echo "[+] Fetching: $u"
    if command -v curl >/dev/null; then
      if curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 10 -o "$out" "$u"; then return 0; fi
    else
      if wget -q --tries=5 --waitretry=3 --timeout=10 -O "$out" "$u"; then return 0; fi
    fi
    echo "[!] Failed: $u"
  done
  return 1
}

# Fetch Guix installer (with fallbacks) or binary bootstrap
if ! command -v guix >/dev/null; then
  echo "[+] Installing Guix prerequisites..."
  if ! fetch_with_fallback guix-install.sh \
    "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh" \
    "https://git.savannah.gnu.org/git/guix.git/plain/etc/guix-install.sh" \
    "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh?h=master"
  then
    echo "[!] Installer script unavailable; attempting binary bootstrap..."
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64) BIN="guix-binary-1.4.0.x86_64-linux.tar.xz" ;;
      aarch64) BIN="guix-binary-1.4.0.aarch64-linux.tar.xz" ;;
      i686) BIN="guix-binary-1.4.0.i686-linux.tar.xz" ;;
      *) echo "Unsupported arch for binary bootstrap: $ARCH"; exit 1 ;;
    esac
    fetch_with_fallback "$BIN" \
      "https://mirror0.nexcess.net/gnu/guix/$BIN" \
      "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN" \
      "https://ftp.gnu.org/gnu/guix/$BIN"
    mkdir -p /gnu/store /var/guix
    tar -C / -xJf "$BIN"
    rm -f "$BIN"
    echo "[+] Binary bootstrap complete."
  else
    chmod +x guix-install.sh
    ./guix-install.sh
    rm -f guix-install.sh || true
  fi

  export GUIX_PROFILE="/root/.config/guix/current"
  export PATH="$GUIX_PROFILE/bin:$PATH"
  # shellcheck disable=SC1090
  . "$GUIX_PROFILE/etc/profile"
fi

# Confirm intent
echo
echo "THIS WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX AS YOUR OS."
echo "Choose disk carefully (e.g., /dev/sda or /dev/nvme0n1)."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -r -p "Target disk (e.g., /dev/sda or /dev/nvme0n1): " disk
[[ -b "$disk" ]] || { echo "Invalid disk: $disk"; exit 1; }

# Base device for BIOS GRUB target
disk_base="$disk"
case "$disk" in
  /dev/nvme*[0-9]) : ;; # full disk like /dev/nvme0n1
  /dev/*[0-9]) disk_base="$(echo "$disk" | sed 's/[0-9]*$//')" ;;
  *) disk_base="$disk" ;;
esac

# Auto-detect firmware: UEFI if /sys/firmware/efi exists
if [[ -d /sys/firmware/efi ]]; then
  default_scheme=1
  echo "[+] UEFI detected. Defaulting to: 1) UEFI GPT"
else
  default_scheme=3
  echo "[+] BIOS detected. Defaulting to: 3) BIOS MBR"
fi

echo
echo "Partition schemes:"
echo "  1) UEFI GPT: EFI + root (ext4/btrfs/xfs)"
echo "  2) UEFI GPT + LUKS: EFI + encrypted root (ext4/btrfs/xfs)"
echo "  3) BIOS MBR: bootable root (ext4/btrfs/xfs)"
read -r -p "Choice (1/2/3) [default ${default_scheme}]: " scheme
scheme="${scheme:-$default_scheme}"

# Filesystem choice
echo "Filesystem options: 1=ext4 2=btrfs 3=xfs"
read -r -p "Root filesystem (1/2/3) [default 1]: " fs_choice
fs_choice="${fs_choice:-1}"
case "$fs_choice" in
  1) fs_type="ext4" ; mkfs_cmd="mkfs.ext4 -F" ;;
  2) fs_type="btrfs" ; mkfs_cmd="mkfs.btrfs -f" ;;
  3) fs_type="xfs" ; mkfs_cmd="mkfs.xfs -f" ;;
  *) echo "Invalid filesystem choice"; exit 1 ;;
esac

# Separate /home
read -r -p "Create separate /home partition? (y/N): " sep_home
sep_home="${sep_home:-N}"

# Swap options
read -r -p "Create swap? (y/N): " mk_swap
mk_swap="${mk_swap:-N}"
swap_size=""
swap_encrypt="N"
if [[ "$mk_swap" =~ ^[yY]$ ]]; then
  read -r -p "Swap size (e.g., 4G, 8192M): " swap_size
  read -r -p "Encrypt swap with LUKS? (y/N): " swap_encrypt
  swap_encrypt="${swap_encrypt:-N}"
fi

read -r -p "Type EXACTLY 'YES I WANT GUIX' to continue: " confirm
[[ "$confirm" = "YES I WANT GUIX" ]] || { echo "Aborted."; exit 1; }

# Wipe and partition
echo "[+] Wiping signatures on ${disk}..."
swapoff -a || true
wipefs -af "$disk"

efi=""
rootp=""
cryptp=""
crypt_name="guixroot"
homep=""
swapp=""
swap_cryptp=""
swap_crypt_name="guixswap"

case "$scheme" in
  1)
    # UEFI, plain root
    if [[ "$sep_home" =~ ^[yY]$ ]]; then
      if [[ "$mk_swap" =~ ^[yY]$ ]]; then
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart root "$fs_type" 512MiB -"${swap_size}" \
          mkpart home "$fs_type" -"${swap_size}" 100% \
          mkpart swap linux-swap -"${swap_size}" 100%
        efi="${disk}1"; rootp="${disk}2"; homep="${disk}3"; swapp="${disk}4"
      else
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart root "$fs_type" 512MiB 50% \
          mkpart home "$fs_type" 50% 100%
        efi="${disk}1"; rootp="${disk}2"; homep="${disk}3"
      fi
    else
      if [[ "$mk_swap" =~ ^[yY]$ ]]; then
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart root "$fs_type" 512MiB -"${swap_size}" \
          mkpart swap linux-swap -"${swap_size}" 100%
        efi="${disk}1"; rootp="${disk}2"; swapp="${disk}3"
      else
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart root "$fs_type" 512MiB 100%
        efi="${disk}1"; rootp="${disk}2"
      fi
    fi
    mkfs.vfat -F32 "$efi"
    $mkfs_cmd "$rootp"
    [[ -n "$homep" ]] && $mkfs_cmd "$homep"
    [[ -n "$swapp" ]] && mkswap "$swapp"
    ;;
  2)
    # UEFI + LUKS root
    if [[ "$sep_home" =~ ^[yY]$ ]]; then
      if [[ "$mk_swap" =~ ^[yY]$ ]]; then
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart cryptroot 512MiB -"${swap_size}" \
          mkpart swap linux-swap -"${swap_size}" 100%
        efi="${disk}1"; cryptp="${disk}2"; swapp="${disk}3"
      else
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart cryptroot 512MiB 100%
        efi="${disk}1"; cryptp="${disk}2"
      fi
    else
      if [[ "$mk_swap" =~ ^[yY]$ ]]; then
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart cryptroot 512MiB -"${swap_size}" \
          mkpart swap linux-swap -"${swap_size}" 100%
        efi="${disk}1"; cryptp="${disk}2"; swapp="${disk}3"
      else
        parted --script "$disk" mklabel gpt \
          mkpart ESP fat32 1MiB 512MiB \
          set 1 esp on \
          mkpart cryptroot 512MiB 100%
        efi="${disk}1"; cryptp="${disk}2"
      fi
    fi
    mkfs.vfat -F32 "$efi"
    echo "[+] Setting up LUKS for root (you’ll be prompted for a passphrase)..."
    cryptsetup luksFormat "$cryptp"
    cryptsetup open "$cryptp" "$crypt_name"
    rootp="/dev/mapper/$crypt_name"
    $mkfs_cmd "$rootp"
    if [[ -n "$swapp" ]]; then
      if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then
        echo "[+] Setting up LUKS for swap..."
        cryptsetup luksFormat "$swapp"
        cryptsetup open "$swapp" "$swap_crypt_name"
        mkswap "/dev/mapper/$swap_crypt_name"
        swap_cryptp="/dev/mapper/$swap_crypt_name"
      else
        mkswap "$swapp"
      fi
    fi
    ;;
  3)
    # BIOS MBR
    if [[ "$sep_home" =~ ^[yY]$ ]]; then
      if [[ "$mk_swap" =~ ^[yY]$ ]]; then
        parted --script "$disk" mklabel msdos \
          mkpart primary "$fs_type" 1MiB -"${swap_size}" \
          set 1 boot on \
          mkpart primary "$fs_type" -"${swap_size}" 100% \
          mkpart primary linux-swap -"${swap_size}" 100%
        rootp="${disk}1"; homep="${disk}2"; swapp="${disk}3"
      else
        parted --script "$disk" mklabel msdos \
          mkpart primary "$fs_type" 1MiB 50% \
          set 1 boot on \
          mkpart primary "$fs_type" 50% 100%
        rootp="${disk}1"; homep="${disk}2"
      fi
    else
      if [[ "$mk_swap" =~ ^[yY]$ ]]; then
        parted --script "$disk" mklabel msdos \
          mkpart primary "$fs_type" 1MiB -"${swap_size}" \
          set 1 boot on \
          mkpart primary linux-swap -"${swap_size}" 100%
        rootp="${disk}1"; swapp="${disk}2"
      else
        parted --script "$disk" mklabel msdos \
          mkpart primary "$fs_type" 1MiB 100% \
          set 1 boot on
        rootp="${disk}1"
      fi
    fi
    $mkfs_cmd "$rootp"
    [[ -n "$homep" ]] && $mkfs_cmd "$homep"
    [[ -n "$swapp" ]] && mkswap "$swapp"
    ;;
  *)
    echo "Invalid scheme"; exit 1
    ;;
esac

# Mount target
mkdir -p /mnt
mount "$rootp" /mnt
if [[ -n "$efi" ]]; then
  mkdir -p /mnt/boot/efi
  mount "$efi" /mnt/boot/efi
fi
if [[ -n "$homep" ]]; then
  mkdir -p /mnt/home
  mount "$homep" /mnt/home
fi

# Collect system info
read -r -p "Hostname: " hostname
read -r -p "Timezone (e.g., America/Sao_Paulo): " timezone
read -r -p "Locale (e.g., en_US.UTF-8): " locale
read -r -p "Keyboard (e.g., br-abnt2): " keyboard
read -r -p "Username: " username
# Silent password prompts (Bash supports -s)
read -r -s -p "User password: " upass; echo
read -r -s -p "Root password: " rpass; echo

echo "Desktop: 1=i3 2=mate 3=xfce 4=sway (Wayland) 5=none (text)"
read -r -p "Choice (1/2/3/4/5): " desk_choice
case "$desk_choice" in
  1) session="i3.desktop"; extra="i3-wm i3status dmenu"; display_mgr="sddm"; sway=0 ;;
  2) session="mate.desktop"; extra="mate"; display_mgr="sddm"; sway=0 ;;
  3) session="xfce.desktop"; extra="xfce"; display_mgr="sddm"; sway=0 ;;
  4) session=""; extra="sway wayland"; display_mgr="greetd"; sway=1 ;;
  5) session=""; extra=""; display_mgr=""; sway=0 ;;
  *) echo "Invalid"; exit 1 ;;
esac

# Hash passwords
huser="$(python3 - <<PY
import crypt
print(crypt.crypt("${upass}", crypt.mksalt(crypt.METHOD_SHA512)))
PY
)"
hroot="$(python3 - <<PY
import crypt
print(crypt.crypt("${rpass}", crypt.mksalt(crypt.METHOD_SHA512)))
PY
)"

# Determine UUIDs for plain devices (root and home only if not LUKS-root)
root_uuid=""
home_uuid=""
efi_uuid=""
[[ -n "$efi" ]] && efi_uuid="$(blkid -s UUID -o value "$efi")"
if [[ "$scheme" = "2" ]]; then
  :
else
  root_uuid="$(blkid -s UUID -o value "$rootp")"
  [[ -n "$homep" ]] && home_uuid="$(blkid -s UUID -o value "$homep")"
fi

# Build config.scm (preserving original modules and package set; add LUKS mapping and swap devices)
cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu)
             (gnu packages admin) (gnu packages base) (gnu packages commencement)
             (gnu packages disk) (gnu packages file-systems) (gnu packages fonts)
             (gnu packages gl) (gnu packages gnupg) (gnu packages image-viewers)
             (gnu packages linux) (gnu packages llvm) (gnu packages package-management)
             (gnu packages pulseaudio) (gnu packages python-xyz) (gnu packages terminals)
             (gnu packages tls) (gnu packages tor) (gnu packages version-control)
             (gnu packages video) (gnu packages vpn) (gnu packages xdisorg)
             (gnu packages xorg) (gnu services desktop) (gnu services xorg)
             (nongnu packages linux) (nongnu system linux-initrd))

(operating-system
  (host-name "$hostname")
  (timezone "$timezone")
  (locale "$locale")
  (keyboard-layout (keyboard-layout "$keyboard"))
  $(if [[ -n "$efi" ]]; then
cat <<EFI
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets '("/boot/efi"))))
EFI
else
cat <<BIOS
  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("$disk_base"))))
BIOS
fi)
  (kernel linux)
  (initrd microcode-initrd)
  (firmware (list linux-firmware))
  $(if [[ "$scheme" = "2" ]]; then
cat <<MAPPINGS
  (device-mappings
    (list (device-mapping
            (target "$crypt_name")
            (source "$cryptp"))))
MAPPINGS
fi)
  (file-systems
    (cons*
      $(if [[ "$scheme" = "2" ]]; then
cat <<LUKSFS
      (file-system
        (device "/dev/mapper/$crypt_name")
        (mount-point "/")
        (type "$fs_type"))
LUKSFS
else
cat <<PLAINFS
      (file-system
        (device (uuid "$root_uuid"))
        (mount-point "/")
        (type "$fs_type"))
PLAINFS
fi)
      $(if [[ -n "$homep" ]] && [[ "$scheme" != "2" ]]; then
cat <<HOMEFS
      (file-system
        (device (uuid "$home_uuid"))
        (mount-point "/home")
        (type "$fs_type"))
HOMEFS
fi)
      $(if [[ -n "$efi" ]]; then
cat <<EFIFS
      (file-system
        (device (uuid "$efi_uuid"))
        (mount-point "/boot/efi")
        (type "vfat"))
EFIFS
fi)
      %base-file-systems))
  $(if [[ -n "$swapp" ]] || [[ -n "$swap_cryptp" ]]; then
cat <<SWAP
  (swap-devices
    (list $(if [[ -n "$swap_cryptp" ]]; then
echo "(swap-device (target \"/dev/mapper/$swap_crypt_name\"))"
elif [[ -n "$swapp" ]]; then
echo "(swap-device (target \"$swapp\"))"
fi)))
SWAP
fi)
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
    (list icecat torbrowser libreoffice mpv feh
          acpi-call-linux-module util-linux v4l2loopback-linux-module
          mesa mesa-headers llvm-for-mesa libva libva-utils linux-firmware
          xterm xorg-xdpyinfo xorg-xset xorg-xwininfo xorg-xprop
          xpra xorg-xkill xorg-setxkbmap xorg-xmodmap xdg-utils xorg-xrandr
          lf mergerfs parted ntfs-3g exfat-utils exfatprogs fuse-exfat
          dosfstools bcachefs-tools smartmontools e2fsprogs xfsprogs
          emacs gcc gcc-toolchain linux-libre-headers git git-lfs
          python python-pip cmake meson binutils strace edk2-tools
          kitty alacritty fish zoxide pfetch
          sysstat nftables clamav gnupg libfido2 firejail privoxy
          openvpn tor torsocks nmap tcpdump openssl keepassxc
          htop btop glances inxi lm-sensors net-tools fping netdiscover
          whois macchanger procps coreutils grep sed nix
          alsa-lib alsa-utils pulseaudio pipewire wireplumber
          font-iosevka-term font-iosevka-term-slab font-iosevka-slab
          font-iosevka-etoile font-iosevka-curly font-iosevka-curly-slab
          font-iosevka-aile font-iosevka-ss01 font-iosevka-ss02 font-iosevka-ss03
          font-iosevka-ss04 font-iosevka-ss05 font-iosevka-ss06 font-iosevka-ss07
          font-iosevka-ss08 font-iosevka-ss09 font-iosevka-ss10 font-iosevka-ss11
          font-iosevka-ss12 font-iosevka-ss13 font-iosevka-ss14 font-iosevka-ss15
          font-iosevka-ss16 font-iosevka-ss17 font-iosevka-ss18
          font-sarasa-gothic font-aporetic font-adwaita)
    (map specification->package '($extra))
    %base-packages))
  (services
   (append
     (list
       $(if [[ "$sway" -eq 1 ]]; then
cat <<GREETD
       (service greetd-service-type
         (greetd-configuration
           (terminal-vt "tty1")
           (greeter-sessions
             (list (greetd-session (name "sway") (command "sway"))))
           (initial-session
             (greetd-initial-session
               (user "$username")
               (command "sway")))))
GREETD
elif [[ -n "$display_mgr" ]]; then
cat <<SDDM
       (service sddm-service-type
         (sddm-configuration
           (display-server "x11")
           (auto-login-user "$username")
           (auto-login-session "$session")))
SDDM
fi))
     (modify-services $(if [[ "$sway" -eq 1 ]]; then echo "%base-services"; else echo "%desktop-services"; fi)
       (delete gdm-service-type)))))
EOF

# Channels: guix + nonguix (correct introduction, no duplicates)
cat > /mnt/etc/channels.scm <<'EOF'
(list
 (channel
    (name 'debdistutils)
    (url "https://gitlab.com/debdistutils/guix/mirror.git")
    (branch "master"))
  (channel
    (name 'nonguix)
    (url "https://gitlab.com/nonguix/nonguix")
    (introduction
      (make-channel-introduction
        "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
        (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5")))))
EOF

# Initialize store and install
echo "[+] Starting cow-store..."
herd start cow-store /mnt || true

echo "[+] Running guix time-machine -- system init (this may take a while)..."
guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt

echo "[+] Installation complete. Unmounting and rebooting in 10 seconds..."
sync
umount -R /mnt || true
sleep 10
reboot
