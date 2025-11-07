#!/usr/bin/env bash
#=============================================================
#            GNU GUIX FULL OS INSTALLER 
#=============================================================
set -euo pipefail

banner(){ cat <<'B'
+-------------------------------------------------------------+
|                    GNU GUIX FULL OS INSTALL                  |
|                         In Code We Trust                     |
+-------------------------------------------------------------+
B
}
banner

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root"; exit 1
fi

# Optional proxies
# export http_proxy="http://proxy:port"
# export https_proxy="http://proxy:port"

# Safety: require live environment (override with ALLOW_NON_LIVE=YES)
ALLOW_NON_LIVE="${ALLOW_NON_LIVE:-}"
if [[ -z "$ALLOW_NON_LIVE" ]]; then
  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  if [[ "$ROOT_SRC" == /dev/* ]]; then
    echo "Refusing to run on a non-live system (root on $ROOT_SRC)."
    echo "Set ALLOW_NON_LIVE=YES to override." >&2
    exit 1
  fi
fi

# Detect package manager
PKG=""
if command -v apt >/dev/null 2>&1; then PKG="apt"
elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
elif command -v pacman >/dev/null 2>&1; then PKG="pacman"
fi

# Best-effort install of host tools
if [[ -n "$PKG" ]]; then
  case "$PKG" in
    apt)
      apt update
      apt install -y wget curl ca-certificates python3 util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz-utils btrfs-progs xfsprogs uidmap || true
      ;;
    dnf)
      dnf install -y wget curl ca-certificates python3 util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs shadow-utils || true
      ;;
    pacman)
      pacman -Sy --noconfirm wget curl ca-certificates python util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs uidmap || true
      ;;
  esac
fi

# Ensure required host commands exist
for cmd in parted mkfs.ext4 mkfs.xfs mkfs.btrfs mkfs.vfat cryptsetup blkid lsblk partprobe udevadm sgdisk; do
  if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
    echo "Required command '${cmd%% *}' missing. Install it and re-run." >&2
    exit 1
  fi
done

# Ensure uidmap helpers exist
if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
  echo "Installing uidmap/newuidmap/newgidmap (best-effort)..."
  if [[ "$PKG" == "apt" ]]; then apt install -y uidmap || true; fi
  if [[ "$PKG" == "dnf" ]]; then dnf install -y shadow-utils || true; fi
  if [[ "$PKG" == "pacman" ]]; then pacman -Sy --noconfirm uidmap || true; fi
fi

# Fetch helper
fetch_with_fallback(){
  local out="$1"; shift
  rm -f "$out" 2>/dev/null || true
  for u in "$@"; do
    echo "[+] Fetching: $u"
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 10 -o "$out" "$u"; then return 0; fi
    else
      if wget -q --tries=5 --waitretry=3 --timeout=10 -O "$out" "$u"; then return 0; fi
    fi
    echo "[!] Failed: $u"
  done
  return 1
}

# Bootstrap or ensure Guix CLI matches 1.4.0
ensure_guix_1_4_0(){
  if command -v guix >/dev/null 2>&1; then
    ver="$(guix --version 2>/dev/null || true)"
    if [[ "$ver" == *"1.4.0"* ]]; then
      echo "[+] Guix 1.4.0 already available."
      return 0
    fi
    echo "[!] Guix CLI present but not 1.4.0: $ver"
  fi

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) BIN="guix-binary-1.4.0.x86_64-linux.tar.xz" ;;
    aarch64) BIN="guix-binary-1.4.0.aarch64-linux.tar.xz" ;;
    i686) BIN="guix-binary-1.4.0.i686-linux.tar.xz" ;;
    *) BIN="" ;;
  esac

  if [[ -z "$BIN" ]]; then
    echo "No prebuilt guix binary for arch: $ARCH" >&2
    return 1
  fi

  # Try multiple mirrors
  if fetch_with_fallback "$BIN" \
       "https://ftp.gnu.org/gnu/guix/$BIN" \
       "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN" \
       "https://mirror0.nexcess.net/gnu/guix/$BIN"; then
    echo "[+] Extracting Guix binary $BIN (this will place files under /gnu/store if present)"
    mkdir -p /gnu /gnu/store /var/guix || true
    tar -xJf "$BIN" -C / || true
    rm -f "$BIN" || true
    # Source profile if available
    if [[ -f "/root/.config/guix/current/etc/profile" ]]; then
      export GUIX_PROFILE="/root/.config/guix/current"
      export PATH="$GUIX_PROFILE/bin:$PATH"
      # shellcheck disable=SC1090
      . "$GUIX_PROFILE/etc/profile" || true
    fi
    # verify guix version
    if command -v guix >/dev/null 2>&1 && guix --version | grep -q "1.4.0"; then
      echo "[+] Guix 1.4.0 installed/available."
      return 0
    else
      echo "[!] Guix binary extraction did not produce guix CLI in PATH."
      return 1
    fi
  else
    echo "[!] Could not fetch guix binary $BIN" >&2
    return 1
  fi
}

ensure_guix_1_4_0 || echo "[!] Warning: could not ensure Guix 1.4.0; continuing but guix time-machine may fail."

# -------------------- User prompts --------------------
echo
echo "THIS SCRIPT WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX (1.4.0 compatible)."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -r -p "Target disk (e.g., /dev/sda or /dev/vda or /dev/nvme0n1): " disk
[[ -b "$disk" ]] || { echo "Invalid disk: $disk"; exit 1; }

if [[ "$disk" =~ ^/dev/nvme ]]; then disk_base="$disk"; else disk_base="$(echo "$disk" | sed 's/[0-9]*$//')"; fi

if [[ -d /sys/firmware/efi ]]; then default_scheme=1; echo "[+] UEFI detected"; else default_scheme=3; echo "[+] BIOS detected"; fi

echo "Partition schemes:"
echo " 1) UEFI GPT: EFI + root"
echo " 2) UEFI GPT + LUKS: EFI + encrypted root"
echo " 3) BIOS MBR: bootable root"
echo " 4) BIOS MBR + LUKS: boot + encrypted root"
read -r -p "Choice (1/2/3/4) [${default_scheme}]: " scheme; scheme="${scheme:-$default_scheme}"

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

# -------------------- Sanity checks --------------------
mounted_on_disk(){
  local base="$(basename "$disk")"
  while read -r name mnt; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ ^"$base" ]]; then
      if [[ -n "$mnt" ]]; then return 0; fi
    fi
  done < <(lsblk -nr -o NAME,MOUNTPOINT)
  return 1
}
if mounted_on_disk; then
  echo "One or more partitions on $disk are mounted. Unmount them and re-run." >&2
  exit 1
fi

to_mib(){
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"
  else echo "$s"; fi
}
if [[ "$mk_swap" =~ ^[yY]$ ]]; then swap_mib=$(to_mib "$swap_size"); else swap_mib=0; fi

total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
efi_size=512
min_required_mib=$(( 2048 + efi_size ))
if (( total_mib < min_required_mib )); then
  echo "Disk too small (${total_mib} MiB). Need at least ${min_required_mib} MiB." >&2
  exit 1
fi

# -------------------- Partitioning using parted (robust) --------------------
if [[ "$scheme" == "3" || "$scheme" == "4" ]]; then
  parted --script "$disk" mklabel msdos
else
  parted --script "$disk" mklabel gpt
fi

if [[ "$scheme" -eq 1 || "$scheme" -eq 2 ]]; then
  parted --script --align optimal "$disk" mkpart primary 1MiB ${efi_size}MiB
  parted --script "$disk" set 1 esp on
  used_mib=$efi_size
else
  used_mib=1
fi

create_part_mib(){
  local size_mib="$1"
  local start_mib="$used_mib"
  local end_spec
  if [[ "$size_mib" == "rest" ]]; then
    end_spec="100%"
  else
    local end_mib=$(( start_mib + size_mib ))
    end_spec="${end_mib}MiB"
  fi
  parted --script --align optimal "$disk" mkpart primary "${start_mib}MiB" "${end_spec}"
  if [[ "$size_mib" == "rest" ]]; then
    used_mib=$total_mib
  else
    used_mib=$(( used_mib + size_mib ))
  fi
}

if [[ "$scheme" == "1" ]]; then
  remaining_mib=$(( total_mib - used_mib ))
  if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
    root_mib=$(( (remaining_mib - swap_mib) / 2 ))
    home_mib=$(( remaining_mib - swap_mib - root_mib ))
    create_part_mib "$root_mib"
    create_part_mib "$home_mib"
    create_part_mib "$swap_mib"
  elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
    root_mib=$(( remaining_mib - swap_mib ))
    create_part_mib "$root_mib"
    create_part_mib "$swap_mib"
  elif [[ "$sep_home" =~ ^[yY]$ ]]; then
    root_mib=$(( remaining_mib / 2 ))
    home_mib=$(( remaining_mib - root_mib ))
    create_part_mib "$root_mib"
    create_part_mib "$home_mib"
  else
    create_part_mib "rest"
  fi

elif [[ "$scheme" == "2" ]]; then
  remaining_mib=$(( total_mib - used_mib ))
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    crypt_mib=$(( remaining_mib - swap_mib ))
    create_part_mib "$crypt_mib"
    create_part_mib "$swap_mib"
  else
    create_part_mib "rest"
  fi

elif [[ "$scheme" == "3" ]]; then
  parted --script --align optimal "$disk" mkpart primary 1MiB 100%
elif [[ "$scheme" == "4" ]]; then
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    crypt_mib=$(( total_mib - swap_mib - 1 ))
    parted --script --align optimal "$disk" mkpart primary 1MiB ${crypt_mib}MiB
    parted --script --align optimal "$disk" mkpart primary ${crypt_mib}MiB 100%
  else
    parted --script --align optimal "$disk" mkpart primary 1MiB 100%
  fi
fi

partprobe "$disk" || true
udevadm settle --timeout=10 || true
sleep 1

# -------------------- Resolve partitions --------------------
part_node(){
  local idx="$1"
  if [[ -b "${disk}${idx}" ]]; then echo "${disk}${idx}"
  elif [[ -b "${disk}p${idx}" ]]; then echo "${disk}p${idx}"
  else echo ""; fi
}
parts=()
for idx in 1 2 3 4 5 6; do
  node=$(part_node "$idx")
  if [[ -n "$node" ]]; then parts+=("$node"); fi
done

efi=""
rootp=""; homep=""; swapp=""; cryptp=""
if [[ "$scheme" == "1" ]]; then
  efi="${parts[0]}"
  if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
    rootp="${parts[1]}"; homep="${parts[2]}"; swapp="${parts[3]}"
  elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
    rootp="${parts[1]}"; swapp="${parts[2]}"
  elif [[ "$sep_home" =~ ^[yY]$ ]]; then
    rootp="${parts[1]}"; homep="${parts[2]}"
  else
    rootp="${parts[1]}"
  fi

elif [[ "$scheme" == "2" ]]; then
  efi="${parts[0]}"
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    cryptp="${parts[1]}"; swapp="${parts[2]}"
  else
    cryptp="${parts[1]}"
  fi
  rootp="/dev/mapper/guixroot"

elif [[ "$scheme" == "3" ]]; then
  rootp="${parts[0]}"
elif [[ "$scheme" == "4" ]]; then
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    cryptp="${parts[0]}"; swapp="${parts[1]}"
  else
    cryptp="${parts[0]}"
  fi
  rootp="/dev/mapper/guixroot"
fi

if [[ -z "$rootp" ]]; then echo "Root partition not found; aborting." >&2; exit 1; fi

# -------------------- Format and LUKS --------------------
echo "[+] Formatting filesystems..."

if [[ -n "$efi" && -b "$efi" ]]; then
  mkfs.vfat -F32 "$efi"
fi

if [[ "$scheme" == "2" || "$scheme" == "4" ]]; then
  [[ -b "$cryptp" ]] || { echo "Expected LUKS partition $cryptp not found"; exit 1; }
  cryptsetup luksFormat "$cryptp"
  cryptsetup open "$cryptp" guixroot
  case "$fs_type" in
    ext4) mkfs.ext4 -F /dev/mapper/guixroot ;;
    btrfs) mkfs.btrfs -f /dev/mapper/guixroot ;;
    xfs) mkfs.xfs -f /dev/mapper/guixroot ;;
  esac
  rootp="/dev/mapper/guixroot"

  if [[ -n "$swapp" && -b "$swapp" ]]; then
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then
      cryptsetup luksFormat "$swapp"
      cryptsetup open "$swapp" guixswap
      mkswap /dev/mapper/guixswap
      swapp="/dev/mapper/guixswap"
    else
      mkswap "$swapp"
    fi
  fi

else
  if [[ -b "$rootp" ]]; then
    case "$fs_type" in
      ext4) mkfs.ext4 -F "$rootp" ;;
      btrfs) mkfs.btrfs -f "$rootp" ;;
      xfs) mkfs.xfs -f "$rootp" ;;
    esac
  fi
  if [[ -n "$homep" && -b "$homep" ]]; then
    case "$fs_type" in
      ext4) mkfs.ext4 -F "$homep" ;;
      btrfs) mkfs.btrfs -f "$homep" ;;
      xfs) mkfs.xfs -f "$homep" ;;
    esac
  fi
  if [[ -n "$swapp" && -b "$swapp" ]]; then
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then
      cryptsetup luksFormat "$swapp"
      cryptsetup open "$swapp" guixswap
      mkswap /dev/mapper/guixswap
      swapp="/dev/mapper/guixswap"
    else
      mkswap "$swapp"
    fi
  fi
fi

partprobe "$disk" || true
udevadm settle --timeout=10 || true
sleep 1

# -------------------- Mount target FS --------------------
mkdir -p /mnt
mount "$rootp" /mnt
if [[ -n "$efi" ]]; then mkdir -p /mnt/boot/efi; mount "$efi" /mnt/boot/efi; fi
if [[ -n "$homep" ]]; then mkdir -p /mnt/home; mount "$homep" /mnt/home; fi

# -------------------- Collect system/user details --------------------
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
  1) session="i3.desktop"; extra_pkgs="i3-wm i3status dmenu"; display_mgr="sddm"; sway=0 ;;
  2) session="mate.desktop"; extra_pkgs="mate"; display_mgr="sddm"; sway=0 ;;
  3) session="xfce.desktop"; extra_pkgs="xfce"; display_mgr="sddm"; sway=0 ;;
  4) session=""; extra_pkgs="sway wayland"; display_mgr="greetd"; sway=1 ;;
  5) session=""; extra_pkgs=""; display_mgr=""; sway=0 ;;
  *) echo "Invalid"; exit 1 ;;
esac

# Hash passwords (sha512)
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

# Get UUIDs
root_uuid=""; home_uuid=""; efi_uuid=""
if [[ -b "$rootp" ]]; then root_uuid="$(blkid -s UUID -o value "$rootp" || true)"; fi
[[ -n "$homep" && -b "$homep" ]] && home_uuid="$(blkid -s UUID -o value "$homep" || true)"
[[ -n "$efi" && -b "$efi" ]] && efi_uuid="$(blkid -s UUID -o value "$efi" || true)"

# -------------------- Write config.scm (preserve user's use-modules & packages) --------------------
mkdir -p /mnt/etc

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

if [[ "$scheme" == "2" || "$scheme" == "4" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
  (device-mappings
    (list (device-mapping
            (target "guixroot")
            (source "${cryptp}"))))
EOF
fi

cat >> /mnt/etc/config.scm <<EOF
  (file-systems
    (cons*
EOF

if [[ "$scheme" == "2" || "$scheme" == "4" ]]; then
  cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device "/dev/mapper/guixroot")
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

if [[ -n "$homep" && "$scheme" != "2" && "$scheme" != "4" ]]; then
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

if [[ -n "${swapp:-}" ]]; then
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
    (map specification->package '(${extra_pkgs}))
    %base-packages))
  (services
   %base-services))
EOF

# -------------------- channels.scm (preserve user's channels) --------------------
cat > /mnt/etc/channels.scm <<'EOF'
(list
(channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA"))))
  (channel
    (name 'nonguix)
    (url "https://gitlab.com/nonguix/nonguix")
    (introduction
      (make-channel-introduction
        "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
        (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5")))))
EOF

# -------------------- Run Guix init using matching 1.4.0 CLI if available --------------------
if command -v guix >/dev/null 2>&1; then
  # Force time-machine to use channels.scm but prefer binary substitutes
  echo "[+] Running guix time-machine -- system init (may take long)..."
  GUIX_SUBSTITUTE_URLS="https://hydra.gnu.org https://ci.guix.info" \
    guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt || {
      echo "[!] guix system init failed. Check guix-daemon logs and /tmp/guix-init.log" >&2
      exit 1
    }
else
  echo "[!] Guix CLI not available. Attempted bootstrap may have failed."
  echo "Please ensure guix 1.4.0 is installed before running the installer."
  exit 1
fi

sync
umount -R /mnt || true
echo "Installation finished. Rebooting in 10 seconds..."
sleep 10
reboot
