```bash
#!/usr/bin/env bash
#=============================================================
#                 GNU GUIX FULL OS INSTALLER 
#=============================================================
set -euo pipefail

banner(){ cat <<'B'
+-------------------------------------------------------------+
|                   GNU GUIX FULL OS INSTALL                   |
|                     [ In Code We Trust ]                     |
+-------------------------------------------------------------+
B
}
banner

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root"; exit 1
fi

# Optional proxies (set environment before running)
# export http_proxy="http://proxy:port"
# export https_proxy="http://proxy:port"

# Safety: require live environment unless overridden
ALLOW_NON_LIVE="${ALLOW_NON_LIVE:-}"
if [[ -z "$ALLOW_NON_LIVE" ]]; then
  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  if [[ "$ROOT_SRC" == /dev/* ]]; then
    echo "Refusing to run on a non-live system (root on $ROOT_SRC)."
    echo "Boot a live environment or set ALLOW_NON_LIVE=YES to override."
    exit 1
  fi
fi

# Detect package manager if available (best-effort for bootstrapping tools)
if command -v apt >/dev/null; then PKG="apt"
elif command -v dnf >/dev/null; then PKG="dnf"
elif command -v pacman >/dev/null; then PKG="pacman"
else PKG=""; fi

# Try to install common tools if package manager exists (best-effort)
if [[ -n "$PKG" ]]; then
  case "$PKG" in
    apt) apt update && apt install -y wget curl ca-certificates python3 libnss3-tools nscd uidmap util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz-utils btrfs-progs xfsprogs || true ;;
    dnf) dnf install -y wget curl ca-certificates python3 nss-tools nscd shadow-utils util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs || true ;;
    pacman) pacman -Sy --noconfirm wget curl ca-certificates python nss nscd shadow util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs || true ;;
  esac
fi

# Ensure parted exists for fallback
if ! command -v parted >/dev/null; then
  echo "Required tool 'parted' missing. Install it in the live environment and re-run."; exit 1
fi

# Helper: robust fetch with retries/fallbacks
fetch_with_fallback() {
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

# Guix install (installer script or binary bootstrap)
if ! command -v guix >/dev/null; then
  echo "[+] Installing Guix..."
  if fetch_with_fallback guix-install.sh \
       "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh" \
       "https://git.savannah.gnu.org/git/guix.git/plain/etc/guix-install.sh" \
       "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh?h=master"; then
    chmod +x guix-install.sh
    ./guix-install.sh
    rm -f guix-install.sh || true
  else
    echo "[!] Installer missing; attempting binary bootstrap..."
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64) BIN="guix-binary-1.4.0.x86_64-linux.tar.xz" ;;
      aarch64) BIN="guix-binary-1.4.0.aarch64-linux.tar.xz" ;;
      i686) BIN="guix-binary-1.4.0.i686-linux.tar.xz" ;;
      *) echo "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    fetch_with_fallback "$BIN" \
      "https://mirror0.nexcess.net/gnu/guix/$BIN" \
      "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN" \
      "https://ftp.gnu.org/gnu/guix/$BIN"
    mkdir -p /gnu/store /var/guix
    tar -C / -xJf "$BIN"
    rm -f "$BIN"
  fi

  export GUIX_PROFILE="/root/.config/guix/current"
  export PATH="$GUIX_PROFILE/bin:$PATH"
  # shellcheck disable=SC1090
  . "$GUIX_PROFILE/etc/profile"
fi

# Confirm destructive action and target selection
echo
echo "THIS SCRIPT WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -r -p "Target disk (e.g., /dev/sda or /dev/nvme0n1): " disk
[[ -b "$disk" ]] || { echo "Invalid disk: $disk"; exit 1; }

# derive disk_base for BIOS grub target
if [[ "$disk" =~ ^/dev/nvme ]]; then disk_base="$disk"; else disk_base="$(echo "$disk" | sed 's/[0-9]*$//')"; fi

# Detect firmware (UEFI vs BIOS)
if [[ -d /sys/firmware/efi ]]; then
  echo "[+] UEFI detected"; default_scheme=1
else
  echo "[+] BIOS detected"; default_scheme=3
fi

echo "Partition schemes:"
echo " 1) UEFI GPT: EFI + root"
echo " 2) UEFI GPT + LUKS: EFI + encrypted root"
echo " 3) BIOS MBR: bootable root"
read -r -p "Choice (1/2/3) [${default_scheme}]: " scheme; scheme="${scheme:-$default_scheme}"

echo "Filesystem options: 1=ext4 2=btrfs 3=xfs"
read -r -p "Root filesystem (1/2/3) [1]: " fs_choice; fs_choice="${fs_choice:-1}"
case "$fs_choice" in 1) fs_type="ext4";; 2) fs_type="btrfs";; 3) fs_type="xfs";; *) echo "Invalid"; exit 1;; esac

read -r -p "Create separate /home partition? (y/N): " sep_home; sep_home="${sep_home:-N}"
read -r -p "Create swap? (y/N): " mk_swap; mk_swap="${mk_swap:-N}"
swap_size=""; swap_encrypt="N"
if [[ "$mk_swap" =~ ^[yY]$ ]]; then
  read -r -p "Swap size (e.g., 4G): " swap_size
  read -r -p "Encrypt swap with LUKS? (y/N): " swap_encrypt
  swap_encrypt="${swap_encrypt:-N}"
fi

read -r -p "Type EXACTLY 'YES I WANT GUIX' to continue: " confirm
[[ "$confirm" = "YES I WANT GUIX" ]] || { echo "Aborted."; exit 1; }

# Sanity unmount check
if mount | grep -q "^${disk}"; then
  echo "One or more partitions on $disk are mounted. Unmount them and re-run."; exit 1
fi

# convert swap size to MiB
to_mib() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"
  else echo "$s"; fi
}
if [[ "$mk_swap" =~ ^[yY]$ ]]; then swap_mib=$(to_mib "$swap_size"); else swap_mib=0; fi

# disk size in MiB
total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
efi_size=512

# Partitioning: prefer sgdisk (gdisk) if available; otherwise use robust parted flow
if command -v sgdisk >/dev/null; then
  echo "[+] Using sgdisk (gdisk) for partitioning"
  sgdisk --zap-all "$disk"
  # helper to add partition via sgdisk
  add_gpt_part() {
    local start_mib="$1"; local size_mib="$2"; local type="$3"; local name="$4"
    if [[ "$size_mib" == "*" ]]; then
      sgdisk --new=0:"${start_mib}MiB":0 --typecode=0:"$type" --change-name=0:"$name" "$disk"
    else
      sgdisk --new=0:"${start_mib}MiB":"+${size_mib}MiB" --typecode=0:"$type" --change-name=0:"$name" "$disk"
    fi
  }

  if [[ "$scheme" == "1" ]]; then
    if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - efi_size - swap_mib ))
      root_mib=$(( usable / 2 )); home_mib=$(( usable - root_mib ))
      add_gpt_part 1 511 ef00 "EFI"
      add_gpt_part 512 "$root_mib" 8300 "ROOT"
      add_gpt_part $((512 + root_mib)) "$home_mib" 8300 "HOME"
      add_gpt_part $((512 + root_mib + home_mib)) "$swap_mib" 8200 "SWAP"
    elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
      root_mib=$(( total_mib - efi_size - swap_mib ))
      add_gpt_part 1 511 ef00 "EFI"
      add_gpt_part 512 "$root_mib" 8300 "ROOT"
      add_gpt_part $((512 + root_mib)) "$swap_mib" 8200 "SWAP"
    elif [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - efi_size ))
      root_mib=$(( usable / 2 )); home_mib=$(( usable - root_mib ))
      add_gpt_part 1 511 ef00 "EFI"
      add_gpt_part 512 "$root_mib" 8300 "ROOT"
      add_gpt_part $((512 + root_mib)) "$home_mib" 8300 "HOME"
    else
      root_mib=$(( total_mib - efi_size ))
      add_gpt_part 1 511 ef00 "EFI"
      add_gpt_part 512 "$root_mib" 8300 "ROOT"
    fi

  elif [[ "$scheme" == "2" ]]; then
    if [[ "$mk_swap" =~ ^[yY]$ ]]; then
      crypt_mib=$(( total_mib - efi_size - swap_mib ))
      add_gpt_part 1 511 ef00 "EFI"
      add_gpt_part 512 "$crypt_mib" 8300 "CRYPTROOT"
      add_gpt_part $((512 + crypt_mib)) "$swap_mib" 8200 "SWAP"
    else
      crypt_mib=$(( total_mib - efi_size ))
      add_gpt_part 1 511 ef00 "EFI"
      add_gpt_part 512 "$crypt_mib" 8300 "CRYPTROOT"
    fi

  else
    # BIOS MBR: use parted for msdos label
    echo "[+] BIOS scheme selected - using parted for msdos partitioning"
    parted --script "$disk" mklabel msdos
    if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - swap_mib )); root_mib=$(( usable / 2 )); home_mib=$(( usable - root_mib ))
      parted --script --align optimal "$disk" mkpart primary 1MiB "${root_mib}MiB"
      parted --script --align optimal "$disk" mkpart primary "${root_mib}MiB" "$((root_mib + home_mib))MiB"
      parted --script --align optimal "$disk" mkpart primary "$((root_mib + home_mib))MiB" 100%
    elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
      root_mib=$(( total_mib - swap_mib ))
      parted --script --align optimal "$disk" mkpart primary 1MiB "${root_mib}MiB"
      parted --script --align optimal "$disk" mkpart primary "${root_mib}MiB" 100%
    elif [[ "$sep_home" =~ ^[yY]$ ]]; then
      root_mib=$(( total_mib / 2 ))
      parted --script --align optimal "$disk" mkpart primary 1MiB "${root_mib}MiB"
      parted --script --align optimal "$disk" mkpart primary "${root_mib}MiB" 100%
    else
      parted --script --align optimal "$disk" mklabel msdos
      parted --script --align optimal "$disk" mkpart primary 1MiB 100%
      parted --script "$disk" set 1 boot on
    fi
  fi

  partprobe "$disk" || true
  udevadm settle --timeout=10 || true
  sleep 1

else
  echo "[+] sgdisk (gdisk) not found; using portable parted flow"
  parted --script "$disk" mklabel gpt
  parted --script --align optimal "$disk" mkpart primary 1MiB 512MiB
  parted --script "$disk" set 1 esp on

  if [[ "$scheme" == "1" ]]; then
    if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - efi_size - swap_mib ))
      root_mib=$(( usable / 2 )); root_end=$((512 + root_mib)); home_end=$((root_end + (usable - root_mib)))
      parted --script --align optimal "$disk" mkpart primary 512MiB "${root_end}MiB"
      parted --script --align optimal "$disk" mkpart primary "${root_end}MiB" "${home_end}MiB"
      parted --script --align optimal "$disk" mkpart primary "${home_end}MiB" 100%
    elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
      root_mib=$(( total_mib - efi_size - swap_mib )); root_end=$((512 + root_mib))
      parted --script --align optimal "$disk" mkpart primary 512MiB "${root_end}MiB"
      parted --script --align optimal "$disk" mkpart primary "${root_end}MiB" 100%
    elif [[ "$sep_home" =~ ^[yY]$ ]]; then
      root_mib=$(( (total_mib - efi_size) / 2 )); root_end=$((512 + root_mib))
      parted --script --align optimal "$disk" mkpart primary 512MiB "${root_end}MiB"
      parted --script --align optimal "$disk" mkpart primary "${root_end}MiB" 100%
    else
      parted --script --align optimal "$disk" mkpart primary 512MiB 100%
    fi

  elif [[ "$scheme" == "2" ]]; then
    if [[ "$mk_swap" =~ ^[yY]$ ]]; then
      crypt_mib=$(( total_mib - efi_size - swap_mib )); crypt_end=$((512 + crypt_mib))
      parted --script --align optimal "$disk" mkpart primary 512MiB "${crypt_end}MiB"
      parted --script --align optimal "$disk" mkpart primary "${crypt_end}MiB" 100%
    else
      parted --script --align optimal "$disk" mkpart primary 512MiB 100%
    fi

  else
    parted --script --align optimal "$disk" mklabel msdos
    parted --script --align optimal "$disk" mkpart primary 1MiB 100%
    parted --script "$disk" set 1 boot on
  fi

  partprobe "$disk" || true
  udevadm settle --timeout=10 || true
  sleep 1
fi

# Resolve partition device nodes (supports /dev/sdX1 and /dev/nvme0n1p1)
part_node() {
  local idx="$1"
  if [[ -b "${disk}${idx}" ]]; then echo "${disk}${idx}"
  elif [[ -b "${disk}p${idx}" ]]; then echo "${disk}p${idx}"
  else echo ""; fi
}
p1=$(part_node 1); p2=$(part_node 2); p3=$(part_node 3); p4=$(part_node 4)

efi=""; rootp=""; homep=""; swapp=""; cryptp=""; crypt_name="guixroot"; swap_crypt_name="guixswap"
if [[ "$scheme" == "1" ]]; then
  efi="$p1"; rootp="$p2"; [[ "$sep_home" =~ ^[yY]$ ]] && homep="$p3"
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    if [[ -n "$homep" ]]; then swapp="$p4"; else swapp="$p3"; fi
  fi
elif [[ "$scheme" == "2" ]]; then
  efi="$p1"; cryptp="$p2"; rootp="/dev/mapper/$crypt_name"
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then swapp="$p3"; fi
else
  rootp="$p1"; [[ "$sep_home" =~ ^[yY]$ ]] && homep="$p2"
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    if [[ -n "$homep" ]]; then swapp="$p3"; else swapp="$p2"; fi
  fi
fi

# Format filesystems and set up LUKS if requested
echo "[+] Formatting filesystems and configuring LUKS if requested..."
if [[ -n "$efi" && -b "$efi" ]]; then mkfs.vfat -F32 "$efi"; fi

if [[ "$scheme" == "2" ]]; then
  [[ -b "$cryptp" ]] || { echo "Expected LUKS partition $cryptp not found"; exit 1; }
  echo "[+] Creating LUKS container for root on $cryptp"
  cryptsetup luksFormat "$cryptp"
  cryptsetup open "$cryptp" "$crypt_name"
  if [[ "$fs_type" == "ext4" ]]; then mkfs.ext4 -F "/dev/mapper/$crypt_name"
  elif [[ "$fs_type" == "btrfs" ]]; then mkfs.btrfs -f "/dev/mapper/$crypt_name"
  else mkfs.xfs -f "/dev/mapper/$crypt_name"; fi
  rootp="/dev/mapper/$crypt_name"

  if [[ -n "$swapp" && -b "$swapp" ]]; then
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then
      cryptsetup luksFormat "$swapp"
      cryptsetup open "$swapp" "$swap_crypt_name"
      mkswap "/dev/mapper/$swap_crypt_name"
      swapp="/dev/mapper/$swap_crypt_name"
    else
      mkswap "$swapp"
    fi
  fi

else
  if [[ -n "$rootp" && -b "$rootp" ]]; then
    if [[ "$fs_type" == "ext4" ]]; then mkfs.ext4 -F "$rootp"
    elif [[ "$fs_type" == "btrfs" ]]; then mkfs.btrfs -f "$rootp"
    else mkfs.xfs -f "$rootp"; fi
  fi
  if [[ -n "$homep" && -b "$homep" ]]; then
    if [[ "$fs_type" == "ext4" ]]; then mkfs.ext4 -F "$homep"
    elif [[ "$fs_type" == "btrfs" ]]; then mkfs.btrfs -f "$homep"
    else mkfs.xfs -f "$homep"; fi
  fi
  if [[ -n "$swapp" && -b "$swapp" ]]; then
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then
      cryptsetup luksFormat "$swapp"
      cryptsetup open "$swapp" "$swap_crypt_name"
      mkswap "/dev/mapper/$swap_crypt_name"
      swapp="/dev/mapper/$swap_crypt_name"
    else
      mkswap "$swapp"
    fi
  fi
fi

# Mount root and other FS
mkdir -p /mnt
mount "$rootp" /mnt
if [[ -n "$efi" ]]; then mkdir -p /mnt/boot/efi; mount "$efi" /mnt/boot/efi; fi
if [[ -n "$homep" ]]; then mkdir -p /mnt/home; mount "$homep" /mnt/home; fi

# Collect system/user details
read -r -p "Hostname: " hostname
read -r -p "Timezone (e.g., America/Sao_Paulo): " timezone
read -r -p "Locale (e.g., en_US.UTF-8): " locale
read -r -p "Keyboard (e.g., br-abnt2): " keyboard
read -r -p "Username: " username
read -r -s -p "User password: " upass; echo
read -r -s -p "Root password: " rpass; echo

echo "Desktop: 1=i3 2=mate 3=xfce 4=sway 5=none"
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

# Determine UUIDs for non-LUKS devices
root_uuid=""; home_uuid=""; efi_uuid=""
if [[ "$scheme" != "2" ]]; then root_uuid="$(blkid -s UUID -o value "$rootp" || true)"; fi
[[ -n "$homep" ]] && home_uuid="$(blkid -s UUID -o value "$homep" || true)"
[[ -n "$efi" ]] && efi_uuid="$(blkid -s UUID -o value "$efi" || true)"

# Write config.scm preserving modules and package set; include device-mappings when LUKS root
cat > /mnt/etc/config.scm <<'EOF'
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
EOF

# Append dynamic parts of config.scm (use here-doc with variable interpolation)
cat >> /mnt/etc/config.scm <<EOF
(operating-system
  (host-name "${hostname}")
  (timezone "${timezone}")
  (locale "${locale}")
  (keyboard-layout (keyboard-layout "${keyboard}"))
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
                (targets '("${disk_base}"))))
EOF
fi

cat >> /mnt/etc/config.scm <<EOF
  (kernel linux)
  (initrd microcode-initrd)
  (firmware (list linux-firmware))
EOF

if [[ "$scheme" == "2" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
  (device-mappings
    (list (device-mapping
            (target "${crypt_name}")
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
        (device "/dev/mapper/${crypt_name}")
        (mount-point "/")
        (type "${fs_type}"))
EOF
else
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device (uuid "${root_uuid}"))
        (mount-point "/")
        (type "${fs_type}"))
EOF
fi

if [[ -n "$homep" && "$scheme" != "2" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device (uuid "${home_uuid}"))
        (mount-point "/home")
        (type "${fs_type}"))
EOF
fi

if [[ -n "$efi" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device (uuid "${efi_uuid}"))
        (mount-point "/boot/efi")
        (type "vfat"))
EOF
fi

cat >> /mnt/etc/config.scm <<'EOF'
      %base-file-systems))
EOF

# swap-devices
if [[ -n "$swapp" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
  (swap-devices
    (list (swap-device (target "${swapp}"))))
EOF
fi

cat >> /mnt/etc/config.scm <<EOF
  (users (cons* (user-account
                  (name "${username}")
                  (group "users")
                  (password "${huser}")
                  (supplementary-groups '("wheel" "netdev" "audio" "networking" "video")))
                (map (lambda (u) (if (string=? (user-account-name u) "root")
                                   (user-account (inherit u) (password "${hroot}")) u))
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
    (map specification->package '(${extra:-}))
    %base-packages))
EOF

# services
cat >> /mnt/etc/config.scm <<'EOF'
  (services
   (append
EOF

if [[ "${sway:-0}" -eq 1 ]]; then
  cat >> /mnt/etc/config.scm <<EOF
     (list (service greetd-service-type
                  (greetd-configuration
                    (terminal-vt "tty1")
                    (greeter-sessions
                      (list (greetd-session (name "sway") (command "sway"))))
                    (initial-session
                      (greetd-initial-session
                        (user "${username}")
                        (command "sway"))))))
     (modify-services %base-services (delete gdm-service-type)))))
EOF
else
  if [[ -n "${display_mgr:-}" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
     (list (service sddm-service-type
                  (sddm-configuration
                    (display-server "x11")
                    (auto-login-user "${username}")
                    (auto-login-session "${session}"))))
     (modify-services %desktop-services (delete gdm-service-type)))))
EOF
  else
    cat >> /mnt/etc/config.scm <<'EOF'
     %base-services
     (modify-services %desktop-services (delete gdm-service-type)))))
EOF
  fi
fi

# Write channels.scm with debdistutils first
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

# Start cow-store and run guix time-machine init
echo "[+] Starting cow-store..."
herd start cow-store /mnt || true

echo "[+] Running guix time-machine -- system init (this may take a long time)..."
guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt

echo "[+] Installation finished. Syncing and rebooting in 10 seconds..."
sync
umount -R /mnt || true
sleep 10
reboot

