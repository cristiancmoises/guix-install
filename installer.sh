#!/usr/bin/env bash
#=============================================================
#                     GNU GUIX FULL OS INSTALLER 
#                           Powered By Aliens
#=============================================================
set -euo pipefail

banner(){ cat <<'B'
+-------------------------------------------------------------+
|                    GNU GUIX FULL OS INSTALL                  |
|                       [ In Code We Trust ]                   |
+-------------------------------------------------------------+
B
}
banner

if [[ "$(id -u)" -ne 0 ]]; then echo "Run as root"; exit 1; fi

# Optional proxy env (set before running if required)
# export http_proxy="http://proxy:port"
# export https_proxy="http://proxy:port"

# Safety: prefer live environment
ALLOW_NON_LIVE="${ALLOW_NON_LIVE:-}"
if [[ -z "$ALLOW_NON_LIVE" ]]; then
  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  if [[ "$ROOT_SRC" == /dev/* ]]; then
    echo "Refusing to run on a non-live system (root on $ROOT_SRC)."
    echo "Boot a live environment or set ALLOW_NON_LIVE=YES to override."
    exit 1
  fi
fi

# Bootstrap package manager detection and best-effort install of tools
if command -v apt >/dev/null; then PKG="apt"
elif command -v dnf >/dev/null; then PKG="dnf"
elif command -v pacman >/dev/null; then PKG="pacman"
else PKG=""; fi

if [[ -n "$PKG" ]]; then
  case "$PKG" in
    apt) apt update && apt install -y wget curl ca-certificates python3 libnss3-tools nscd uidmap util-linux sfdisk parted e2fsprogs dosfstools cryptsetup xz-utils btrfs-progs xfsprogs || true ;;
    dnf) dnf install -y wget curl ca-certificates python3 nss-tools nscd shadow-utils util-linux sfdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs || true ;;
    pacman) pacman -Sy --noconfirm wget curl ca-certificates python nss nscd shadow util-linux sfdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs || true ;;
  esac
fi

# Ensure parted exists
if ! command -v parted >/dev/null; then
  echo "parted is required but missing. Install parted or run on a live image with it present."; exit 1
fi

HAS_SFDISK=0
if command -v sfdisk >/dev/null; then HAS_SFDISK=1; fi

# Robust fetch helper
fetch_with_fallback(){
  out="$1"; shift
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
  fi

  export GUIX_PROFILE="/root/.config/guix/current"
  export PATH="$GUIX_PROFILE/bin:$PATH"
  # shellcheck disable=SC1090
  . "$GUIX_PROFILE/etc/profile"
fi

# Target disk and layout choices
echo
echo "THIS WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX AS YOUR OS."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -r -p "Target disk (e.g., /dev/sda or /dev/nvme0n1): " disk
[[ -b "$disk" ]] || { echo "Invalid disk: $disk"; exit 1; }

# disk_base for BIOS boot target
if [[ "$disk" =~ ^/dev/nvme ]]; then disk_base="$disk"; else disk_base="$(echo "$disk" | sed 's/[0-9]*$//')"; fi

# firmware detection
if [[ -d /sys/firmware/efi ]]; then default_scheme=1; echo "[+] UEFI detected"; else default_scheme=3; echo "[+] BIOS detected"; fi
echo "Partition schemes: 1=UEFI GPT  2=UEFI GPT + LUKS  3=BIOS MBR"
read -r -p "Choice (1/2/3) [${default_scheme}]: " scheme; scheme="${scheme:-$default_scheme}"

echo "Filesystem options: 1=ext4 2=btrfs 3=xfs"
read -r -p "Root filesystem (1/2/3) [1]: " fs_choice; fs_choice="${fs_choice:-1}"
case "$fs_choice" in 1) fs_type="ext4" ;; 2) fs_type="btrfs" ;; 3) fs_type="xfs" ;; *) echo "Invalid"; exit 1;; esac

read -r -p "Create separate /home partition? (y/N): " sep_home; sep_home="${sep_home:-N}"
read -r -p "Create swap? (y/N): " mk_swap; mk_swap="${mk_swap:-N}"
swap_size=""; swap_encrypt="N"
if [[ "$mk_swap" =~ ^[yY]$ ]]; then read -r -p "Swap size (e.g., 4G): " swap_size; read -r -p "Encrypt swap? (y/N): " swap_encrypt; fi

read -r -p "Type EXACTLY 'YES I WANT GUIX' to continue: " confirm
[[ "$confirm" = "YES I WANT GUIX" ]] || { echo "Aborted."; exit 1; }

# sanity: no mounted partitions on target disk
if mount | grep -q "^${disk}"; then
  echo "One or more partitions on $disk are mounted. Unmount them and re-run the script."; exit 1
fi

# Partitioning: build part table (MiB arithmetic)
to_mib(){
  s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"
  else echo "$s"; fi
}
if [[ "$mk_swap" =~ ^[yY]$ ]]; then swap_mib=$(to_mib "$swap_size"); else swap_mib=0; fi
total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
efi_size=512

# create sfdisk table in /tmp/part.table
tmp_table=$(mktemp)
trap 'rm -f "$tmp_table"' EXIT

if command -v sfdisk >/dev/null; then
  echo "[+] Using sfdisk (will require explicit typed confirmation to force)."
  if [[ "$scheme" == "1" ]]; then
    if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - efi_size - swap_mib )); root_mib=$(( usable / 2 )); home_mib=$(( usable - root_mib ))
      cat > "$tmp_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=${efi_size}, type=ef00, name=EFI
partition2 : start=512, size=${root_mib}, type=8300, name=ROOT
partition3 : start=$((512 + root_mib)), size=${home_mib}, type=8300, name=HOME
partition4 : start=$((512 + root_mib + home_mib)), size=${swap_mib}, type=8200, name=SWAP
EOF
    elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
      root_mib=$(( total_mib - efi_size - swap_mib ))
      cat > "$tmp_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=${efi_size}, type=ef00, name=EFI
partition2 : start=512, size=${root_mib}, type=8300, name=ROOT
partition3 : start=$((512 + root_mib)), size=${swap_mib}, type=8200, name=SWAP
EOF
    elif [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - efi_size )); root_mib=$(( usable / 2 )); home_mib=$(( usable - root_mib ))
      cat > "$tmp_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=${efi_size}, type=ef00, name=EFI
partition2 : start=512, size=${root_mib}, type=8300, name=ROOT
partition3 : start=$((512 + root_mib)), size=${home_mib}, type=8300, name=HOME
EOF
    else
      root_mib=$(( total_mib - efi_size ))
      cat > "$tmp_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=${efi_size}, type=ef00, name=EFI
partition2 : start=512, size=${root_mib}, type=8300, name=ROOT
EOF
    fi
  elif [[ "$scheme" == "2" ]]; then
    if [[ "$mk_swap" =~ ^[yY]$ ]]; then
      crypt_mib=$(( total_mib - efi_size - swap_mib ))
      cat > "$tmp_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=${efi_size}, type=ef00, name=EFI
partition2 : start=512, size=${crypt_mib}, type=8300, name=CRYPTROOT
partition3 : start=$((512 + crypt_mib)), size=${swap_mib}, type=8200, name=SWAP
EOF
    else
      crypt_mib=$(( total_mib - efi_size ))
      cat > "$tmp_table" <<EOF
label: gpt
unit: MiB
first-lba: 1
partition1 : start=1, size=${efi_size}, type=ef00, name=EFI
partition2 : start=512, size=${crypt_mib}, type=8300, name=CRYPTROOT
EOF
    fi
  else
    # BIOS MBR/dos
    if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - swap_mib )); root_mib=$(( usable / 2 )); home_mib=$(( usable - root_mib ))
      cat > "$tmp_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${root_mib}, type=83, bootable
partition2 : start=$((1 + root_mib)), size=${home_mib}, type=83
partition3 : start=$((1 + root_mib + home_mib)), size=${swap_mib}, type=82
EOF
    elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
      root_mib=$(( total_mib - swap_mib ))
      cat > "$tmp_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${root_mib}, type=83, bootable
partition2 : start=$((1 + root_mib)), size=${swap_mib}, type=82
EOF
    elif [[ "$sep_home" =~ ^[yY]$ ]]; then
      root_mib=$(( total_mib / 2 )); home_mib=$(( total_mib - root_mib ))
      cat > "$tmp_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${root_mib}, type=83, bootable
partition2 : start=$((1 + root_mib)), size=${home_mib}, type=83
EOF
    else
      cat > "$tmp_table" <<EOF
label: dos
unit: MiB
first-lba: 1
partition1 : start=1, size=${total_mib}, type=83, bootable
EOF
    fi
  fi

  # Show the table and ask the user to confirm force usage
  echo
  echo "Proposed partition table:"
  sed -n '1,200p' "$tmp_table"
  echo
  echo "sfdisk will overwrite $disk irreversibly."
  read -r -p "Type 'YES I UNDERSTAND' to allow the script to run sfdisk --force: " ok
  [[ "$ok" = "YES I UNDERSTAND" ]] || { echo "Aborted."; exit 1; }

  # apply with --force and --no-reread, then sync kernel partition table
  sfdisk --wipe always --force --no-reread "$disk" < "$tmp_table"
  partprobe "$disk" || true
  udevadm settle --timeout=10 || true
  sleep 1

else
  echo "[+] sfdisk not found: using portable parted fallback (no forcing)."
  parted --script "$disk" mklabel gpt
  parted --script --align optimal "$disk" mkpart primary 1MiB 512MiB
  parted --script "$disk" set 1 esp on

  if [[ "$scheme" == "1" ]]; then
    if [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
      usable=$(( total_mib - efi_size - swap_mib )); root_mib=$(( usable / 2 )); home_mib=$(( usable - root_mib ))
      root_end=$((512 + root_mib)); home_end=$((512 + root_mib + home_mib))
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

# Find partition node names
part_node(){
  idx="$1"
  if [[ -b "${disk}${idx}" ]]; then echo "${disk}${idx}"
  elif [[ -b "${disk}p${idx}" ]]; then echo "${disk}p${idx}"
  else echo ""; fi
}
p1=$(part_node 1); p2=$(part_node 2); p3=$(part_node 3); p4=$(part_node 4)

efi=""; rootp=""; homep=""; swapp=""; cryptp=""
if [[ "$scheme" == "1" ]]; then
  efi="$p1"; rootp="$p2"; [[ "$sep_home" =~ ^[yY]$ ]] && homep="$p3"
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then if [[ -n "$homep" ]]; then swapp="$p4"; else swapp="$p3"; fi; fi
elif [[ "$scheme" == "2" ]]; then
  efi="$p1"; cryptp="$p2"; if [[ "$mk_swap" =~ ^[yY]$ ]]; then swapp="$p3"; fi
elif [[ "$scheme" == "3" ]]; then
  rootp="$p1"; [[ "$sep_home" =~ ^[yY]$ ]] && homep="$p2"; if [[ "$mk_swap" =~ ^[yY]$ ]]; then if [[ -n "$homep" ]]; then swapp="$p3"; else swapp="$p2"; fi; fi
fi

# Format and LUKS
echo "[+] Formatting filesystems and configuring LUKS if requested..."
if [[ -n "$efi" && -b "$efi" ]]; then mkfs.vfat -F32 "$efi"; fi

if [[ "$scheme" == "2" ]]; then
  if [[ -z "$cryptp" || ! -b "$cryptp" ]]; then echo "Crypt partition not found"; exit 1; fi
  cryptsetup luksFormat "$cryptp"
  cryptsetup open "$cryptp" guixroot
  if [[ "$fs_type" == "ext4" ]]; then mkfs.ext4 -F /dev/mapper/guixroot
  elif [[ "$fs_type" == "btrfs" ]]; then mkfs.btrfs -f /dev/mapper/guixroot
  else mkfs.xfs -f /dev/mapper/guixroot; fi
  rootp="/dev/mapper/guixroot"
  if [[ -n "$swapp" && -b "$swapp" ]]; then
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then cryptsetup luksFormat "$swapp"; cryptsetup open "$swapp" guixswap; mkswap /dev/mapper/guixswap; swapp="/dev/mapper/guixswap"; else mkswap "$swapp"; fi
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
    if [[ "$swap_encrypt" =~ ^[yY]$ ]]; then cryptsetup luksFormat "$swapp"; cryptsetup open "$swapp" guixswap; mkswap /dev/mapper/guixswap; swapp="/dev/mapper/guixswap"; else mkswap "$swapp"; fi
  fi
fi

# Mount
mkdir -p /mnt
mount "$rootp" /mnt
if [[ -n "$efi" ]]; then mkdir -p /mnt/boot/efi; mount "$efi" /mnt/boot/efi; fi
if [[ -n "$homep" ]]; then mkdir -p /mnt/home; mount "$homep" /mnt/home; fi

# Collect user info
read -r -p "Hostname: " hostname
read -r -p "Timezone (e.g., America/Sao_Paulo): " timezone
read -r -p "Locale (e.g., en_US.UTF-8): " locale
read -r -p "Keyboard (e.g., br-abnt2): " keyboard
read -r -p "Username: " username
read -r -s -p "User password: " upass; echo
read -r -s -p "Root password: " rpass; echo

echo "Desktop choices: 1=i3 2=mate 3=xfce 4=sway 5=none"
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

# Resolve UUIDs
root_uuid=""; home_uuid=""; efi_uuid=""
if [[ "$scheme" == "2" ]]; then root_uuid=""; else root_uuid="$(blkid -s UUID -o value "$rootp" || true)"; fi
[[ -n "$homep" ]] && home_uuid="$(blkid -s UUID -o value "$homep" || true)"
[[ -n "$efi" ]] && efi_uuid="$(blkid -s UUID -o value "$efi" || true)"

# Write full config.scm (preserving your modules and package list)
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

if [[ "$scheme" == "2" ]]; then
cat >> /mnt/etc/config.scm <<EOF
      (file-system
        (device "/dev/mapper/guixroot")
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
  (users
    (cons* (user-account
              (name "'"$username"'")
              (group "users")
              (password "'"$huser"'")
              (supplementary-groups '("wheel" "netdev" "audio" "networking" "video")))
           (map (lambda (u)
                  (if (string=? (user-account-name u) "root")
                      (user-account (inherit u) (password "'"$hroot"'")) u))
                %base-user-accounts)))
  (packages
    (append
      (list vim htop git nmap openssh tcpdump font-dejavu
            icecat torbrowser libreoffice mpv feh
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
      %base-packages)))
EOF

# Services block (SDDM or greetd depending on sway)
cat >> /mnt/etc/config.scm <<EOF
  (services
    (modify-services
EOF

if [[ "$sway" -eq 1 ]]; then
cat >> /mnt/etc/config.scm <<EOF
      (append (list (service greetd-service-type
                             (greetd-configuration
                               (terminal-vt "tty1")
                               (greeter-sessions
                                 (list (greetd-session (name "sway") (command "sway"))))
                               (initial-session
                                 (greetd-initial-session
                                   (user "$username")
                                   (command "sway"))))))
              %base-services)))
EOF
else
  if [[ -n "${display_mgr:-}" ]]; then
cat >> /mnt/etc/config.scm <<EOF
      (append (list (service sddm-service-type
                             (sddm-configuration
                               (display-server "x11")
                               (auto-login-user "$username")
                               (auto-login-session "$session"))))
              %desktop-services)))
EOF
  else
cat >> /mnt/etc/config.scm <<'EOF'
      %base-services)))
EOF
  fi
fi

# Channels: debdistutils first, then guix, then nonguix
cat > /mnt/etc/channels.scm <<'EOF'
(list
  (channel
    (name 'debdistutils)
    (url "https://gitlab.com/debdistutils/guix/mirror.git")
    (branch "master"))
  (channel
    (name 'guix)
    (url "https://git.savannah.gnu.org/git/guix.git"))
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

echo "[+] Installation complete. Syncing and rebooting in 10 seconds..."
sync
umount -R /mnt || true
sleep 10
reboot
