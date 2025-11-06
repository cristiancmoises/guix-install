#!/usr/bin/env bash
#=============================================================
#                     GNU GUIX FULL OS INSTALLER 
#                         Powered By Aliens
#=============================================================
set -euo pipefail

banner() {
  cat <<'B'
+-------------------------------------------------------------+
|                    GNU GUIX FULL OS INSTALL                  |
|                       [ In Code We Trust ]                   |
+-------------------------------------------------------------+
B
}
banner

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

# Optional proxies (export before running or uncomment and set)
# export http_proxy="http://proxy:port"
# export https_proxy="http://proxy:port"

# Live-check (safe default)
ALLOW_NON_LIVE="${ALLOW_NON_LIVE:-}"
if [[ -z "$ALLOW_NON_LIVE" ]]; then
  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  if [[ "$ROOT_SRC" == /dev/* ]]; then
    echo "Refusing to run on a non-live system (root on $ROOT_SRC)."
    echo "Boot a live environment or set ALLOW_NON_LIVE=YES if you know what you’re doing."
    exit 1
  else
    echo "[+] Live environment detected (root: ${ROOT_SRC:-unknown})."
  fi
else
  echo "[!] Override enabled: ALLOW_NON_LIVE=$ALLOW_NON_LIVE. Proceeding on a running system."
fi

# Detect package manager for bootstrap deps
if command -v apt >/dev/null; then PKG="apt"
elif command -v dnf >/dev/null; then PKG="dnf"
elif command -v pacman >/dev/null; then PKG="pacman"
else echo "Unsupported distro for dependency bootstrap"; exit 1; fi

# Install bootstrap dependencies
case "$PKG" in
  apt)
    apt update
    apt install -y wget curl ca-certificates python3 libnss3-tools nscd uidmap \
      sfdisk util-linux parted e2fsprogs dosfstools cryptsetup xz-utils btrfs-progs xfsprogs
    systemctl enable --now nscd || true
    ;;
  dnf)
    dnf install -y wget curl ca-certificates python3 nss-tools nscd shadow-utils \
      sfdisk util-linux parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs
    systemctl enable --now nscd || true
    ;;
  pacman)
    pacman -Sy --noconfirm wget curl ca-certificates python nss nscd shadow \
      sfdisk util-linux parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs
    systemctl enable --now nscd || true
    ;;
esac

# Robust fetch helper
fetch_with_fallback() {
  local out="$1"; shift
  rm -f "$out"
  for u in "$@"; do
    echo "[+] Fetching: $u"
    if command -v curl >/dev/null; then
      if curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 10 -o "$out" "$u"; then
        return 0
      fi
    else
      if wget -q --tries=5 --waitretry=3 --timeout=10 -O "$out" "$u"; then
        return 0
      fi
    fi
    echo "[!] Failed: $u"
  done
  return 1
}

# Install Guix (installer script or binary bootstrap)
if ! command -v guix >/dev/null; then
  echo "[+] Installing Guix prerequisites..."
  if fetch_with_fallback guix-install.sh \
       "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh" \
       "https://git.savannah.gnu.org/git/guix.git/plain/etc/guix-install.sh" \
       "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh?h=master"; then
    chmod +x guix-install.sh
    ./guix-install.sh
    rm -f guix-install.sh || true
  else
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
  fi

  export GUIX_PROFILE="/root/.config/guix/current"
  export PATH="$GUIX_PROFILE/bin:$PATH"
  # shellcheck disable=SC1090
  . "$GUIX_PROFILE/etc/profile"
fi

# Summary prompt and target disk
echo
echo "THIS WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX AS YOUR OS."
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -r -p "Target disk (e.g., /dev/sda or /dev/nvme0n1): " disk
if [[ ! -b "$disk" ]]; then
  echo "Invalid disk: $disk"; exit 1
fi

# derive disk_base for grub bios install
disk_base="$disk"
if [[ "$disk" =~ ^/dev/nvme ]]; then
  disk_base="$disk"
else
  disk_base="$(echo "$disk" | sed 's/[0-9]*$//')"
fi

# Detect firmware
if [[ -d /sys/firmware/efi ]]; then
  default_scheme=1
  echo "[+] UEFI detected. Default: 1) UEFI GPT"
else
  default_scheme=3
  echo "[+] BIOS detected. Default: 3) BIOS MBR"
fi

echo
echo "Partition schemes:"
echo "  1) UEFI GPT: EFI + root (FS choice)"
echo "  2) UEFI GPT + LUKS: EFI + encrypted root"
echo "  3) BIOS MBR: bootable root"
read -r -p "Choice (1/2/3) [default ${default_scheme}]: " scheme
scheme="${scheme:-$default_scheme}"

# Filesystem selection
echo "Filesystem options: 1=ext4 2=btrfs 3=xfs"
read -r -p "Root filesystem (1/2/3) [default 1]: " fs_choice
fs_choice="${fs_choice:-1}"
case "$fs_choice" in
  1) fs_type="ext4" ; mkfs_cmd="mkfs.ext4 -F" ;;
  2) fs_type="btrfs" ; mkfs_cmd="mkfs.btrfs -f" ;;
  3) fs_type="xfs" ; mkfs_cmd="mkfs.xfs -f" ;;
  *) echo "Invalid filesystem choice"; exit 1 ;;
esac

read -r -p "Create separate /home partition? (y/N): " sep_home
sep_home="${sep_home:-N}"

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

# Partition planning using sfdisk
echo "[+] Preparing partition table with sfdisk..."

# helper to convert suffix sizes to MiB for sfdisk when necessary
to_mib() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)G$|^([0-9]+)g$ ]]; then
    local n="${BASH_REMATCH[1]:-${BASH_REMATCH[2]}}"
    echo $((n * 1024))
  elif [[ "$s" =~ ^([0-9]+)M$|^([0-9]+)m$ ]]; then
    local n="${BASH_REMATCH[1]:-${BASH_REMATCH[2]}}"
    echo "$n"
  else
    echo "$s"
  fi
}

# Build sfdisk table content depending on scheme
sfdisk_table="$(mktemp)"
trap 'rm -f "$sfdisk_table"' EXIT

if [[ "$scheme" == "1" ]]; then
  # UEFI GPT, optionally home and swap
  if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
    swap_mib=$(to_mib "$swap_size")
    cat >"$sfdisk_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=511, type=ef00, name=EFI
partition2 : start=512, size=*, type=8300, name=ROOT
partition3 : start=*, size=${swap_mib}, type=8200, name=SWAP
EOF
    # We'll create root then shrink it into two parts by using sfdisk flexible '*' behavior:
    # To avoid complexity we instead allocate root as size=(total - swap - 512), but sfdisk '*' shorthand isn't reliable everywhere.
    # Instead compute disk size in MiB and subtract.
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( total_mib - 512 - swap_mib ))
    if [[ $root_size -le 0 ]]; then echo "Disk too small for requested layout"; exit 1; fi
    cat >"$sfdisk_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=511, type=ef00, name=EFI
partition2 : start=512, size=${root_size}, type=8300, name=ROOT
partition3 : start=$((512 + root_size)), size=${swap_mib}, type=8200, name=SWAP
EOF
  elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
    swap_mib=$(to_mib "$swap_size")
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( total_mib - 512 - swap_mib ))
    cat >"$sfdisk_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=511, type=ef00, name=EFI
partition2 : start=512, size=${root_size}, type=8300, name=ROOT
partition3 : start=$((512 + root_size)), size=${swap_mib}, type=8200, name=SWAP
EOF
  elif [[ "$sep_home" =~ ^[yY]$ ]]; then
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( (total_mib - 512) / 2 ))
    home_size=$(( total_mib - 512 - root_size ))
    cat >"$sfdisk_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=511, type=ef00, name=EFI
partition2 : start=512, size=${root_size}, type=8300, name=ROOT
partition3 : start=$((512 + root_size)), size=${home_size}, type=8300, name=HOME
EOF
  else
    # EFI + single root
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( total_mib - 512 ))
    cat >"$sfdisk_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=511, type=ef00, name=EFI
partition2 : start=512, size=${root_size}, type=8300, name=ROOT
EOF
  fi

elif [[ "$scheme" == "2" ]]; then
  # UEFI + LUKS root (swap optional, separate home not implemented as separate crypt in this script)
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    swap_mib=$(to_mib "$swap_size")
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    crypt_size=$(( total_mib - 512 - swap_mib ))
    cat >"$sfdisk_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=511, type=ef00, name=EFI
partition2 : start=512, size=${crypt_size}, type=8300, name=CRYPTROOT
partition3 : start=$((512 + crypt_size)), size=${swap_mib}, type=8200, name=SWAP
EOF
  else
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    crypt_size=$(( total_mib - 512 ))
    cat >"$sfdisk_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=511, type=ef00, name=EFI
partition2 : start=512, size=${crypt_size}, type=8300, name=CRYPTROOT
EOF
  fi

elif [[ "$scheme" == "3" ]]; then
  # BIOS MBR
  if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
    swap_mib=$(to_mib "$swap_size")
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( (total_mib - swap_mib) / 2 ))
    home_size=$(( total_mib - swap_mib - root_size ))
    cat >"$sfdisk_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${root_size}, type=83, bootable
partition2 : start=$((1 + root_size)), size=${home_size}, type=83
partition3 : start=$((1 + root_size + home_size)), size=${swap_mib}, type=82
EOF
  elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
    swap_mib=$(to_mib "$swap_size")
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( total_mib - swap_mib ))
    cat >"$sfdisk_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${root_size}, type=83, bootable
partition2 : start=$((1 + root_size)), size=${swap_mib}, type=82
EOF
  elif [[ "$sep_home" =~ ^[yY]$ ]]; then
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( (total_mib) / 2 ))
    home_size=$(( total_mib - root_size ))
    cat >"$sfdisk_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${root_size}, type=83, bootable
partition2 : start=$((1 + root_size)), size=${home_size}, type=83
EOF
  else
    total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
    root_size=$(( total_mib ))
    cat >"$sfdisk_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${root_size}, type=83, bootable
EOF
  fi
else
  echo "Invalid scheme"; exit 1
fi

# Apply partition table
echo "[+] Writing partition table to $disk (sfdisk)"
sfdisk --wipe always "$disk" < "$sfdisk_table"
# Let kernel refresh partitions
partprobe "$disk" || true
udevadm settle --timeout=10 || true
sleep 1

# Find partition device names reliably
# On /dev/sda style -> /dev/sda1 etc. On nvme -> /dev/nvme0n1p1
list_parts() {
  lsblk -ln -o NAME,TYPE "$disk" | awk '$2=="part"{print $1}'
}
parts=( $(list_parts) )
if [[ ${#parts[@]} -eq 0 ]]; then
  echo "No partitions detected; aborting"; exit 1
fi

# Map partitions by name order based on sfdisk layout
# For GPT (scheme 1/2), partition numbering starts at 1
p1="${disk}1"  # EFI or first partition
p2="${disk}2"  # root or crypt
p3="${disk}3"  # swap or home (if present)
p4="${disk}4"  # optional

efi=""
rootp=""
homep=""
swapp=""
cryptp=""
crypt_name="guixroot"
swap_crypt_name="guixswap"

# Assign by existence
if [[ -b "${p1}" ]]; then
  # keep p1 as first
  :
fi
# For nvme devices partition naming uses 'p' before number
if [[ ! -b "$p1" ]]; then
  # try nvme style
  p1="${disk}p1"
  p2="${disk}p2"
  p3="${disk}p3"
  p4="${disk}p4"
fi

# Determine which partitions were created by checking type/size
# We'll detect EFI by vfat signature, swap by type, else assume order
# Simple assignment based on selected scheme:
if [[ "$scheme" == "1" ]]; then
  efi="$p1"
  rootp="$p2"
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then swapp="$p3"; fi
  if [[ "$sep_home" =~ ^[yY]$ ]] && [[ -n "$p3" ]] && [[ -z "$swapp" ]]; then homep="$p3"; fi
elif [[ "$scheme" == "2" ]]; then
  efi="$p1"
  cryptp="$p2"
  rootp="/dev/mapper/$crypt_name"
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then swapp="$p3"; fi
elif [[ "$scheme" == "3" ]]; then
  rootp="$p1"
  if [[ "$sep_home" =~ ^[yY]$ ]]; then homep="$p2"; fi
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then swapp="$p3"; fi
fi

# Format filesystems and handle LUKS / swap
echo "[+] Formatting filesystems..."

if [[ -n "$efi" && -b "$efi" ]]; then
  mkfs.vfat -F32 "$efi"
fi

if [[ "$scheme" == "2" ]]; then
  # LUKS root partition is cryptp
  if [[ -z "$cryptp" || ! -b "$cryptp" ]]; then
    echo "Expected crypt partition $cryptp not found"; exit 1
  fi
  echo "[+] Creating LUKS container for root ($cryptp)"
  cryptsetup luksFormat "$cryptp"
  cryptsetup open "$cryptp" "$crypt_name"
  # create filesystem on mapper
  if [[ "$fs_type" == "ext4" ]]; then
    mkfs.ext4 -F "/dev/mapper/$crypt_name"
  elif [[ "$fs_type" == "btrfs" ]]; then
    mkfs.btrfs -f "/dev/mapper/$crypt_name"
  else
    mkfs.xfs -f "/dev/mapper/$crypt_name"
  fi
  rootp="/dev/mapper/$crypt_name"
  # swap handling
  if [[ -n "$swapp" && -b "$swapp" ]]; then
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then
      cryptsetup luksFormat "$swapp"
      cryptsetup open "$swapp" "$swap_crypt_name"
      mkswap "/dev/mapper/$swap_crypt_name"
      swap_cryptp="/dev/mapper/$swap_crypt_name"
    else
      mkswap "$swapp"
    fi
  fi
else
  # plain root formatting
  if [[ -b "$rootp" ]]; then
    if [[ "$fs_type" == "ext4" ]]; then
      mkfs.ext4 -F "$rootp"
    elif [[ "$fs_type" == "btrfs" ]]; then
      mkfs.btrfs -f "$rootp"
    else
      mkfs.xfs -f "$rootp"
    fi
  fi
  if [[ -n "$homep" && -b "$homep" ]]; then
    if [[ "$fs_type" == "ext4" ]]; then
      mkfs.ext4 -F "$homep"
    elif [[ "$fs_type" == "btrfs" ]]; then
      mkfs.btrfs -f "$homep"
    else
      mkfs.xfs -f "$homep"
    fi
  fi
  if [[ -n "$swapp" && -b "$swapp" ]]; then
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then
      cryptsetup luksFormat "$swapp"
      cryptsetup open "$swapp" "$swap_crypt_name"
      mkswap "/dev/mapper/$swap_crypt_name"
      swap_cryptp="/dev/mapper/$swap_crypt_name"
    else
      mkswap "$swapp"
    fi
  fi
fi

# Mount target tree
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

# User input for system config
read -r -p "Hostname: " hostname
read -r -p "Timezone (e.g., America/Sao_Paulo): " timezone
read -r -p "Locale (e.g., en_US.UTF-8): " locale
read -r -p "Keyboard (e.g., br-abnt2): " keyboard
read -r -p "Username: " username
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

# Determine UUIDs
root_uuid=""
home_uuid=""
efi_uuid=""
if [[ "$scheme" == "2" ]]; then
  root_uuid=""  # root is on mapper
else
  root_uuid="$(blkid -s UUID -o value "$rootp" || true)"
  [[ -n "$homep" ]] && home_uuid="$(blkid -s UUID -o value "$homep" || true)"
fi
[[ -n "$efi" ]] && efi_uuid="$(blkid -s UUID -o value "$efi" || true)"

# Prepare config.scm preserving your original modules/packages and adding mappings
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
EOF

if [[ -n "$efi" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets '("/boot/efi"))))
EOF
else
  cat >> /mnt/etc/config.scm <<EOF
  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("$disk_base"))))
EOF
fi

cat >> /mnt/etc/config.scm <<EOF
  (kernel linux)
  (initrd microcode-initrd)
  (firmware (list linux-firmware))
EOF

if [[ "$scheme" == "2" ]]; then
  # declare device mapping for LUKS root
  cat >> /mnt/etc/config.scm <<EOF
  (device-mappings
    (list (device-mapping
            (target "$crypt_name")
            (source "${cryptp}"))))
EOF
fi

cat >> /mnt/etc/config.scm <<EOF
  (file-systems
    (cons*
EOF

if [[ "$scheme" == "2" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device "/dev/mapper/$crypt_name")
        (mount-point "/")
        (type "$fs_type"))
EOF
else
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device (uuid "$root_uuid"))
        (mount-point "/")
        (type "$fs_type"))
EOF
fi

if [[ -n "$homep" && "$scheme" != "2" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device (uuid "$home_uuid"))
        (mount-point "/home")
        (type "$fs_type"))
EOF
fi

if [[ -n "$efi" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device (uuid "$efi_uuid"))
        (mount-point "/boot/efi")
        (type "vfat"))
EOF
fi

cat >> /mnt/etc/config.scm <<'EOF'
      %base-file-systems))
EOF

# swap-devices if any
if [[ -n "$swapp" || -n "$swap_cryptp" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
  (swap-devices
    (list
EOF
  if [[ -n "$swap_cryptp" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
      (swap-device (target "/dev/mapper/$swap_crypt_name"))
EOF
  elif [[ -n "$swapp" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
      (swap-device (target "$swapp"))
EOF
  fi
  cat >> /mnt/etc/config.scm <<'EOF'
    ))
EOF
fi

cat >> /mnt/etc/config.scm <<EOF
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
EOF

if [[ "$sway" -eq 1 ]]; then
  cat >> /mnt/etc/config.scm <<EOF
     (list
       (service greetd-service-type
         (greetd-configuration
           (terminal-vt "tty1")
           (greeter-sessions
             (list (greetd-session (name "sway") (command "sway"))))
           (initial-session
             (greetd-initial-session
               (user "$username")
               (command "sway"))))))
EOF
  cat >> /mnt/etc/config.scm <<'EOF'
     (modify-services %base-services (delete gdm-service-type)))))
EOF
else
  if [[ -n "$display_mgr" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
     (list
       (service sddm-service-type
         (sddm-configuration
           (display-server "x11")
           (auto-login-user "$username")
           (auto-login-session "$session"))))
     (modify-services %desktop-services (delete gdm-service-type)))))
EOF
  else
    cat >> /mnt/etc/config.scm <<'EOF'
     %base-services
     (modify-services %desktop-services (delete gdm-service-type)))))
EOF
  fi
fi

# Channels file
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

# Start cow-store and run guix system init (time-machine with channels)
echo "[+] Starting cow-store..."
herd start cow-store /mnt || true

echo "[+] Running guix time-machine -- system init (this may take a while)..."
guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt

echo "[+] Installation complete. Unmounting and rebooting in 10 seconds..."
sync
umount -R /mnt || true
sleep 10
reboot
