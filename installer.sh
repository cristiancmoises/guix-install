#!/usr/bin/env bash
#=============================================================
#            GNU GUIX FULL OS INSTALLER (parted-first, fixed)
#       Preserves user's modules, packages and channels lists
#       Robust partitioning via parted, reliable mount checks,
#       LUKS support, and Guix bootstrap (best-effort).
#=============================================================
set -euo pipefail

banner(){ cat <<'B'
+-------------------------------------------------------------+
|                    GNU GUIX FULL OS INSTALL                  |
|                                                              |
+-------------------------------------------------------------+
B
}
banner

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root"; exit 1
fi

# Optional proxies (export before running if needed)
# export http_proxy="http://proxy:port"
# export https_proxy="http://proxy:port"

ALLOW_NON_LIVE="${ALLOW_NON_LIVE:-}"
if [[ -z "$ALLOW_NON_LIVE" ]]; then
  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  if [[ "$ROOT_SRC" == /dev/* ]]; then
    echo "Refusing to run on a non-live system (root on $ROOT_SRC)."
    echo "Boot a live environment or set ALLOW_NON_LIVE=YES to override."
    exit 1
  fi
fi

# detect package manager (best-effort)
PKG=""
if command -v apt >/dev/null 2>&1; then PKG="apt"
elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
elif command -v pacman >/dev/null 2>&1; then PKG="pacman"
fi

# ensure tools (best-effort)
if [[ -n "$PKG" ]]; then
  case "$PKG" in
    apt) apt update && apt install -y parted e2fsprogs xfsprogs btrfs-progs dosfstools udiskie util-linux cryptsetup uidmap curl wget ca-certificates gdisk || true ;;
    dnf) dnf install -y parted e2fsprogs xfsprogs btrfs-progs dosfstools util-linux cryptsetup shadow-utils curl wget ca-certificates gdisk || true ;;
    pacman) pacman -Sy --noconfirm parted e2fsprogs xfsprogs btrfs-progs dosfstools util-linux cryptsetup uidmap curl wget ca-certificates gdisk || true ;;
  esac
fi

# ensure required commands
for cmd in parted mkfs.ext4 mkfs.xfs mkfs.btrfs mkfs.vfat cryptsetup blkid lsblk partprobe udevadm sgdisk; do
  if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
    echo "Required command '${cmd%% *}' missing. Install it and re-run." >&2
    exit 1
  fi
done

# fetch helper
fetch_with_fallback(){ local out="$1"; shift; rm -f "$out" 2>/dev/null || true; for u in "$@"; do if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 10 -o "$out" "$u" && return 0; else wget -q --tries=5 --waitretry=3 --timeout=10 -O "$out" "$u" && return 0; fi; done; return 1; }

# attempt guix CLI availability (best-effort)
if ! command -v guix >/dev/null 2>&1; then
  if fetch_with_fallback guix-install.sh \
       "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh" \
       "https://git.savannah.gnu.org/git/guix.git/plain/etc/guix-install.sh"; then
    chmod +x guix-install.sh
    ./guix-install.sh || true
    rm -f guix-install.sh || true
  fi
  if [[ -f /root/.config/guix/current/etc/profile ]]; then
    export GUIX_PROFILE=/root/.config/guix/current
    export PATH="$GUIX_PROFILE/bin:$PATH"
    # shellcheck disable=SC1090
    . "$GUIX_PROFILE/etc/profile" || true
  fi
fi

# -------------------- User prompts --------------------
echo
echo "THIS SCRIPT WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -r -p "Target disk (e.g., /dev/sda or /dev/vda or /dev/nvme0n1): " disk
[[ -b "$disk" ]] || { echo "Invalid disk: $disk"; exit 1; }

# derive disk_base for grub target if needed
if [[ "$disk" =~ ^/dev/nvme ]]; then disk_base="$disk"; else disk_base="$(echo "$disk" | sed 's/[0-9]*$//')"; fi

# detect firmware
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
# Use gpt for UEFI schemes and msdos for BIOS MBR schemes
if [[ "$scheme" == "3" || "$scheme" == "4" ]]; then
  parted --script "$disk" mklabel msdos
else
  parted --script "$disk" mklabel gpt
fi

# create EFI for GPT schemes
if [[ "$scheme" -eq 1 || "$scheme" -eq 2 ]]; then
  parted --script --align optimal "$disk" mkpart primary 1MiB ${efi_size}MiB
  parted --script "$disk" set 1 esp on
  used_mib=$efi_size
else
  used_mib=1
fi

# helper to create partition by size in MiB or "rest"
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

# Allocate partitions according to chosen scheme
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
  # msdos label with encrypted root + swap partition(s)
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

# -------------------- Resolve partition nodes --------------------
part_node(){
  local idx="$1"
  if [[ -b "${disk}${idx}" ]]; then echo "${disk}${idx}"
  elif [[ -b "${disk}p${idx}" ]]; then echo "${disk}p${idx}"
  else echo ""; fi
}
p1=$(part_node 1); p2=$(part_node 2); p3=$(part_node 3); p4=$(part_node 4); p5=$(part_node 5)

# collect created partitions in order
parts=()
for idx in 1 2 3 4 5 6; do
  node=$(part_node "$idx")
  if [[ -n "$node" ]]; then parts+=("$node"); fi
done

# map roles
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

# sanity check
if [[ -z "$rootp" ]]; then echo "Root partition not found; aborting." >&2; exit 1; fi

# -------------------- Format filesystems and handle LUKS --------------------
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
    btrfs) mkfs.btrss=$(command -v mkfs.btrfs 2>/dev/null || true); if [[ -n "$mkfs.btrss" ]]; then mkfs.btrfs -f /dev/mapper/guixroot; else mkfs.ext4 -F /dev/mapper/guixroot; fi ;;
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

# Get UUIDs
root_uuid=""; home_uuid=""; efi_uuid=""
if [[ -b "$rootp" ]]; then root_uuid="$(blkid -s UUID -o value "$rootp" || true)"; fi
[[ -n "$homep" && -b "$homep" ]] && home_uuid="$(blkid -s UUID -o value "$homep" || true)"
[[ -n "$efi" && -b "$efi" ]] && efi_uuid="$(blkid -s UUID -o value "$efi" || true)"

# -------------------- Write config.scm preserving user's modules and package list --------------------
mkdir -p /mnt/etc

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
EOF

if [[ "${sway:-0}" -eq 1 ]]; then
cat >> /mnt/etc/config.scm <<EOF
  (services
   (append
     (list (service greetd-service-type
                   (greetd-configuration
                     (terminal-vt "tty1")
                     (greeter-sessions
                       (list (greetd-session (name "sway") (command "sway"))))
                     (initial-session
                       (greetd-initial-session
                         (user "${username}")
                         (command "sway"))))))
     (modify-services %base-services (delete gdm-service-type))))
EOF
else
  if [[ -n "${display_mgr:-}" ]]; then
cat >> /mnt/etc/config.scm <<EOF
  (services
   (append
     (list (service sddm-service-type
                   (sddm-configuration
                     (display-server "x11")
                     (auto-login-user "${username}")
                     (auto-login-session "${session}"))))
     (modify-services %desktop-services (delete gdm-service-type))))
EOF
  else
cat >> /mnt/etc/config.scm <<'EOF'
  (services
   %base-services)
EOF
  fi
fi

cat >> /mnt/etc/config.scm <<'EOF'
)
EOF

# -------------------- channels.scm (preserve user's channels) --------------------
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

# -------------------- Guix init --------------------
if command -v herd >/dev/null 2>&1; then
  herd start cow-store /mnt || true
fi

if command -v guix >/dev/null 2>&1; then
  echo "[+] Running guix time-machine -- system init (may take long)..."
  guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt
else
  echo "Guix CLI not found; please ensure guix is installed in the live environment, then run:"
  echo "  guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt"
  exit 1
fi

sync
umount -R /mnt || true
echo "Installation finished. Rebooting in 10 seconds..."
sleep 10
reboot
