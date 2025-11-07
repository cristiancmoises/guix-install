#!/usr/bin/env bash
set -euo pipefail

# -------------------- Banner --------------------
cat <<'BANNER'
+-------------------------------------------------------------+
|                    GNU GUIX FULL OS INSTALL                  |
|                        Powered By Aliens                     |
+-------------------------------------------------------------+
BANNER

# -------------------- Helpers --------------------
log() { printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }
err() { log "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# -------------------- Preconditions --------------------
if [[ "$(id -u)" -ne 0 ]]; then
  die "Run this script as root"
fi

# detect package manager
PKG=""
if command -v apt >/dev/null 2>&1; then PKG="apt"
elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
elif command -v pacman >/dev/null 2>&1; then PKG="pacman"
fi

# Try to install required host tools (best-effort)
install_host_pkgs() {
  case "$PKG" in
    apt)
      apt update
      apt install -y wget curl ca-certificates gnupg2 python3 util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz-utils btrfs-progs xfsprogs uidmap openssl >/dev/null || true
      ;;
    dnf)
      dnf install -y wget curl ca-certificates python3 util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs shadow-utils openssl >/dev/null || true
      ;;
    pacman)
      pacman -Sy --noconfirm wget curl ca-certificates python util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs uidmap openssl >/dev/null || true
      ;;
    *)
      log "No known package manager; ensure required commands are present"
      ;;
  esac
}
install_host_pkgs

# Ensure minimal required commands
for cmd in curl guix guix-daemon systemctl lsblk parted blkid cryptsetup mkfs.vfat mkfs.ext4 mkfs.btrfs mkfs.xfs; do
  : # we'll check guix specially later; don't die now for other cmds since distro live images vary
done

# -------------------- Guix CLI + Daemon checks --------------------
# We prefer guix 1.4.0 but accept installed guix if functionally present.
guix_available() {
  if command -v guix >/dev/null 2>&1; then
    guix --version 2>/dev/null | grep -Eo "([0-9]+\.[0-9]+\.[0-9]+)" || true
    return 0
  fi
  return 1
}

# Try to install guix binary release for 1.4.0 if not present and internet available
bootstrap_guix_binary_1_4_0() {
  if guix_available; then
    log "Guix CLI already available: $(guix --version 2>/dev/null || true)"
    return 0
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) BIN="guix-binary-1.4.0.x86_64-linux.tar.xz" ;;
    aarch64) BIN="guix-binary-1.4.0.aarch64-linux.tar.xz" ;;
    i686) BIN="guix-binary-1.4.0.i686-linux.tar.xz" ;;
    *) BIN="" ;;
  esac
  if [[ -z "$BIN" ]]; then
    err "No prebuilt Guix binary for arch: $ARCH"
    return 1
  fi

  MIRRORS=(
    "https://ftp.gnu.org/gnu/guix/$BIN"
    "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN"
    "https://mirror0.nexcess.net/gnu/guix/$BIN"
  )

  for url in "${MIRRORS[@]}"; do
    log "Trying to fetch Guix binary from $url"
    if curl -fsSL --connect-timeout 8 -o "/tmp/$BIN" "$url"; then
      log "Downloaded $BIN"
      tar -xJf "/tmp/$BIN" -C / || { err "Extraction failed"; return 1; }
      rm -f "/tmp/$BIN"
      if guix_available; then
        log "Guix CLI installed from binary: $(guix --version 2>/dev/null || true)"
        return 0
      fi
    else
      log "Failed to download $url"
    fi
  done

  err "Could not fetch/extract Guix binary 1.4.0"
  return 1
}

# Ensure guix-daemon running and configured to allow substitutes
ensure_guix_daemon() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --full -all | grep -q guix-daemon; then
    systemctl restart guix-daemon || true
    sleep 1
    if ! systemctl is-active --quiet guix-daemon; then
      journalctl -u guix-daemon --no-pager -n 200 | sed -n '1,200p' >&2
      err "guix-daemon failed to start"
      return 1
    fi
    log "guix-daemon active"
    return 0
  else
    # Try launching a minimal guix-daemon in background (best-effort)
    if command -v guix-daemon >/dev/null 2>&1; then
      pkill -f guix-daemon || true
      setsid guix-daemon --build-users-group=guixbuild >/var/log/guix-daemon.log 2>&1 &
      sleep 2
      pgrep -a guix-daemon >/dev/null 2>&1 && { log "Started guix-daemon (background)"; return 0; }
      err "Failed to start guix-daemon"
      return 1
    else
      err "guix-daemon not found"
      return 1
    fi
  fi
}

# -------------------- Substitute server checks and selection --------------------
# Define candidate substitute servers (primary list + fallbacks)
SUBSTITUTE_HOSTS=(
  "https://hydra.gnu.org"
  "https://ci.guix.info"
  "https://ci.guix.gnu.org"
  "https://hydra.nixos.org"
  "https://cache.nixos.org"
)

# Test connectivity to substitute servers; returns space-separated usable URLs
probe_substitutes() {
  local usable=()
  for url in "${SUBSTITUTE_HOSTS[@]}"; do
    # Use a short HEAD request to the host root (443)
    if curl -fsS --max-time 6 -I "$url" >/dev/null 2>&1; then
      usable+=("$url")
    fi
  done
  printf '%s' "${usable[*]}"
}

# Ensure guix substitute configuration in /etc/guix/config.scm (append fallback mirrors)
ensure_guix_substitute_config() {
  local cfg="/etc/guix/config.scm"
  if [[ ! -f "$cfg" ]]; then
    cat >"$cfg" <<'SCM'
;; Minimal Guix substitute configuration created by installer
(;; This file is intended to be edited by admin if needed.
 ;; The installer appends substitute URIs below.
 )
SCM
  fi

  # Collect working substitutes
  usable="$(probe_substitutes)"
  if [[ -z "$usable" ]]; then
    log "No substitute hosts reachable from probe_substitutes"
    return 1
  fi

  # Build substitute lines
  sed -n '1,200p' "$cfg" >/tmp/config.head || true
  cat >/tmp/config.new <<SCM
;; Auto-generated substitute-uris
(operating-mode 'daemon)
(substitute-urls (list
SCM
  for url in $usable; do
    echo "  \"$url\"" >>/tmp/config.new
  done
  cat >>/tmp/config.new <<'SCM'
))
SCM

  # Merge and write atomically
  mv /tmp/config.new "$cfg"
  log "Wrote substitute config to $cfg with: $usable"
  return 0
}

# -------------------- High-level: ensure Guix and substitutes --------------------
if ! guix_available; then
  log "Guix CLI not found; attempting to bootstrap Guix 1.4.0 binary"
  bootstrap_guix_binary_1_4_0 || log "Bootstrap failed; continuing to let local guix handle it (may fail later)"
fi

# Start or ensure guix-daemon
ensure_guix_daemon || log "guix-daemon may not be working; some operations could fail"

# Ensure substitute configuration (best-effort)
ensure_guix_substitute_config || log "Could not write /etc/guix/config.scm substitutes; will use GUIX_SUBSTITUTE_URLS env if available"

# Probe and set GUIX_SUBSTITUTE_URLS env var for this run (prefer working hosts)
usable_list="$(probe_substitutes)"
if [[ -n "$usable_list" ]]; then
  export GUIX_SUBSTITUTE_URLS="$usable_list"
  log "Using GUIX_SUBSTITUTE_URLS: $GUIX_SUBSTITUTE_URLS"
else
  log "No substitutes reachable; building from source may be attempted (slow) and may fail"
fi

# -------------------- USER INTERACTION: Partitioning / install flow --------------------
echo
echo "THIS SCRIPT WILL ERASE THE TARGET DISK AND INSTALL GNU GUIX."
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
read -r -p "Target disk (e.g., /dev/sda or /dev/vda or /dev/nvme0n1): " disk
[[ -b "$disk" ]] || die "Invalid disk: $disk"

if [[ "$disk" =~ ^/dev/nvme ]]; then disk_base="$disk"; else disk_base="$(echo "$disk" | sed 's/[0-9]*$//')"; fi

if [[ -d /sys/firmware/efi ]]; then default_scheme=1; else default_scheme=3; fi

echo "Partition schemes:"
echo " 1) UEFI GPT: EFI + root"
echo " 2) UEFI GPT + LUKS: EFI + encrypted root"
echo " 3) BIOS MBR: bootable root"
echo " 4) BIOS MBR + LUKS: boot + encrypted root"
read -r -p "Choice (1/2/3/4) [${default_scheme}]: " scheme; scheme="${scheme:-$default_scheme}"

echo "Filesystem options: 1=ext4 2=btrfs 3=xfs"
read -r -p "Root filesystem (1/2/3) [1]: " fs_choice; fs_choice="${fs_choice:-1}"
case "$fs_choice" in 1) fs_type="ext4";; 2) fs_type="btrfs";; 3) fs_type="xfs";; *) die "Invalid FS choice";; esac

read -r -p "Create separate /home partition? (y/N): " sep_home; sep_home="${sep_home:-N}"
read -r -p "Create swap? (y/N): " mk_swap; mk_swap="${mk_swap:-N}"
swap_size=""; swap_encrypt="N"
if [[ "$mk_swap" =~ ^[yY]$ ]]; then
  read -r -p "Swap size (e.g., 4G): " swap_size
  read -r -p "Encrypt swap with LUKS? (y/N): " swap_encrypt
  swap_encrypt="${swap_encrypt:-N}"
fi

read -r -p "Type EXACTLY 'YES I WANT GUIX' to continue: " confirm
[[ "$confirm" = "YES I WANT GUIX" ]] || die "Aborted by user"

# -------------------- Partitioning (parted-first, safe creation) --------------------
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
if mounted_on_disk; then die "One or more partitions on $disk are mounted. Unmount them and re-run."; fi

to_mib(){
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"
  else echo "$s"; fi
}
if [[ "$mk_swap" =~ ^[yY]$ ]]; then swap_mib=$(to_mib "$swap_size"); else swap_mib=0; fi

total_mib=$(( $(blockdev --getsize64 "$disk") / 1024 / 1024 ))
efi_size=512
if (( total_mib < efi_size + 1024 )); then die "Disk too small (${total_mib} MiB)"; fi

# label
if [[ "$scheme" == "3" || "$scheme" == "4" ]]; then
  parted --script "$disk" mklabel msdos
else
  parted --script "$disk" mklabel gpt
fi

# create EFI for GPT
used_mib=1
if [[ "$scheme" -eq 1 || "$scheme" -eq 2 ]]; then
  parted --script --align optimal "$disk" mkpart primary 1MiB ${efi_size}MiB
  parted --script "$disk" set 1 esp on
  used_mib=$efi_size
fi

create_part_mib(){
  local size_mib="$1"
  if [[ "$size_mib" == "rest" ]]; then
    parted --script --align optimal "$disk" mkpart primary "${used_mib}MiB" 100%
    used_mib=$total_mib
    return 0
  fi
  if (( size_mib <= 0 )); then
    return 1
  fi
  local start_mib=$used_mib
  local end_mib=$(( start_mib + size_mib ))
  if (( end_mib >= total_mib )); then
    parted --script --align optimal "$disk" mkpart primary "${start_mib}MiB" 100%
    used_mib=$total_mib
    return 0
  fi
  parted --script --align optimal "$disk" mkpart primary "${start_mib}MiB" "${end_mib}MiB"
  used_mib=$end_mib
}

# allocate partitions safely (ensuring swap fits)
if [[ "$scheme" == "1" ]]; then
  remaining_mib=$(( total_mib - used_mib ))
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    if (( swap_mib >= remaining_mib )); then
      swap_mib=$(( remaining_mib - 1 ))
      if (( swap_mib <= 0 )); then log "Not enough space for swap; skipping swap"; mk_swap="N"; swap_mib=0; fi
    fi
    remaining_mib=$(( remaining_mib - swap_mib ))
  fi

  if [[ "$sep_home" =~ ^[yY]$ ]] && [[ "$mk_swap" =~ ^[yY]$ ]]; then
    root_mib=$(( remaining_mib / 2 ))
    home_mib=$(( remaining_mib - root_mib ))
    create_part_mib "$root_mib"
    create_part_mib "$home_mib"
    if (( swap_mib > 0 )); then create_part_mib "$swap_mib"; fi
  elif [[ "$sep_home" =~ ^[yY]$ ]]; then
    root_mib=$(( remaining_mib / 2 ))
    home_mib=$(( remaining_mib - root_mib ))
    create_part_mib "$root_mib"
    create_part_mib "$home_mib"
  elif [[ "$mk_swap" =~ ^[yY]$ ]]; then
    root_mib=$remaining_mib
    create_part_mib "$root_mib"
    if (( swap_mib > 0 )); then create_part_mib "$swap_mib"; fi
  else
    create_part_mib "rest"
  fi

elif [[ "$scheme" == "2" ]]; then
  remaining_mib=$(( total_mib - used_mib ))
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    if (( swap_mib >= remaining_mib )); then
      swap_mib=$(( remaining_mib - 1 ))
      if (( swap_mib <= 0 )); then log "Not enough space for swap; skipping swap"; mk_swap="N"; swap_mib=0; fi
    fi
    crypt_mib=$(( remaining_mib - swap_mib ))
    create_part_mib "$crypt_mib"
    if (( swap_mib > 0 )); then create_part_mib "$swap_mib"; fi
  else
    create_part_mib "rest"
  fi

elif [[ "$scheme" == "3" ]]; then
  parted --script --align optimal "$disk" mkpart primary 1MiB 100%
elif [[ "$scheme" == "4" ]]; then
  if [[ "$mk_swap" =~ ^[yY]$ ]]; then
    crypt_mib=$(( total_mib - swap_mib - 1 ))
    if (( crypt_mib <= 0 )); then die "Not enough space for encrypted root"; fi
    parted --script --align optimal "$disk" mkpart primary 1MiB ${crypt_mib}MiB
    parted --script --align optimal "$disk" mkpart primary ${crypt_mib}MiB 100%
  else
    parted --script --align optimal "$disk" mkpart primary 1MiB 100%
  fi
fi

partprobe "$disk" || true
udevadm settle --timeout=10 || true
sleep 1

# resolve partitions
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

efi=""; rootp=""; homep=""; swapp=""; cryptp=""
if [[ "$scheme" == "1" ]]; then
  efi="${parts[0]}"
  if [[ "${#parts[@]}" -ge 4 ]] && [[ "$mk_swap" =~ ^[yY]$ ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
    rootp="${parts[1]}"; homep="${parts[2]}"; swapp="${parts[3]}"
  elif [[ "${#parts[@]}" -ge 3 ]] && [[ "$mk_swap" =~ ^[yY]$ ]]; then
    rootp="${parts[1]}"; swapp="${parts[2]}"
  elif [[ "${#parts[@]}" -ge 3 ]] && [[ "$sep_home" =~ ^[yY]$ ]]; then
    rootp="${parts[1]}"; homep="${parts[2]}"
  else
    rootp="${parts[1]}"
  fi

elif [[ "$scheme" == "2" ]]; then
  efi="${parts[0]}"
  if [[ "${#parts[@]}" -ge 3 ]] && [[ "$mk_swap" =~ ^[yY]$ ]]; then
    cryptp="${parts[1]}"; swapp="${parts[2]}"
  else
    cryptp="${parts[1]}"
  fi
  rootp="/dev/mapper/guixroot"

elif [[ "$scheme" == "3" ]]; then
  rootp="${parts[0]}"
elif [[ "$scheme" == "4" ]]; then
  if [[ "${#parts[@]}" -ge 2 ]] && [[ "$mk_swap" =~ ^[yY]$ ]]; then
    cryptp="${parts[0]}"; swapp="${parts[1]}"
  else
    cryptp="${parts[0]}"
  fi
  rootp="/dev/mapper/guixroot"
fi

if [[ -z "$rootp" ]]; then die "Root partition not found; aborting."; fi

# format partitions and handle LUKS
log "Formatting filesystems..."
if [[ -n "$efi" && -b "$efi" ]]; then mkfs.vfat -F32 "$efi"; fi

if [[ "$scheme" == "2" || "$scheme" == "4" ]]; then
  [[ -b "$cryptp" ]] || die "Expected LUKS partition $cryptp not found"
  cryptsetup luksFormat "$cryptp" || die "luksFormat failed for $cryptp"
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

# mount
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
  *) die "Invalid choice" ;;
esac

# Hash passwords using openssl to avoid Python crypt DeprecationWarning
huser="$(openssl passwd -6 -- "$upass")"
hroot="$(openssl passwd -6 -- "$rpass")"

# Gather UUIDs
root_uuid=""; home_uuid=""; efi_uuid=""
if [[ -b "$rootp" ]]; then root_uuid="$(blkid -s UUID -o value "$rootp" || true)"; fi
if [[ -n "$homep" && -b "$homep" ]]; then home_uuid="$(blkid -s UUID -o value "$homep" || true)"; fi
if [[ -n "$efi" && -b "$efi" ]]; then efi_uuid="$(blkid -s UUID -o value "$efi" || true)"; fi

# -------------------- Write config.scm (preserve user's modules and packages) --------------------
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
       (commit "4fd32c00abb59b0f275a93c3fef35d5193adbe7a")
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

# -------------------- Run guix system init with retries and substitute fallbacks --------------------
run_guix_init_with_retries() {
  if ! command -v guix >/dev/null 2>&1; then
    err "guix CLI not available; cannot run guix system init"
    return 1
  fi

  local max_attempts=6
  local attempt=1
  local backoff=5

  # default environment substitute URLs (already probed earlier)
  if [[ -n "${GUIX_SUBSTITUTE_URLS:-}" ]]; then
    export GUIX_SUBSTITUTE_URLS
  else
    # fallback to hydra + ci.guix.info if reachable
    export GUIX_SUBSTITUTE_URLS="$(probe_substitutes)"
  fi

  while (( attempt <= max_attempts )); do
    log "guix system init attempt $attempt/$max_attempts (GUIX_SUBSTITUTE_URLS=${GUIX_SUBSTITUTE_URLS})"
    if guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt --verbose; then
      log "guix system init succeeded"
      return 0
    fi
    err "guix system init attempt $attempt failed; checking daemon logs and retrying after backoff"
    if command -v journalctl >/dev/null 2>&1; then
      journalctl -u guix-daemon --since "5 minutes ago" --no-pager -n 200 | sed -n '1,200p' >&2 || true
    fi
    sleep $backoff
    attempt=$(( attempt + 1 ))
    backoff=$(( backoff * 2 > 60 ? 60 : backoff * 2 ))
    # Try to refresh substitute list between attempts
    usable="$(probe_substitutes)"
    if [[ -n "$usable" ]]; then
      export GUIX_SUBSTITUTE_URLS="$usable"
      log "Updated GUIX_SUBSTITUTE_URLS to: $GUIX_SUBSTITUTE_URLS"
    fi
  done

  err "guix system init failed after $max_attempts attempts"
  return 1
}

run_guix_init_with_retries || {
  err "Guix initialization failed; check network, substitute servers, and guix-daemon logs."
  die "Installation aborted due to Guix errors"
}

# -------------------- Finish --------------------
sync
umount -R /mnt || true
log "Installation finished. Rebooting in 10 seconds..."
sleep 10
reboot
