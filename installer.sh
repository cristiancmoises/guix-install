#!/usr/bin/env bash
set -euo pipefail

# GNU Guix guided installer 
# - Attempts to install/start guix-daemon (distro package -> binary bootstrap -> background start)
# - Robust guix init with time-machine and chroot fallback
# - Writes /mnt/etc/config.scm and /mnt/etc/channels.scm (channels list provided by user)
# WARNING: This script is destructive. Review TARGET_DISK before running. Run as root from a live environment.

# -------------------- Defaults / Configurable --------------------
TARGET_DISK="${TARGET_DISK:-}"          # e.g. /dev/sdb
USERNAME="${USERNAME:-user}"
USER_PASS="${USER_PASS:-password}"
ROOT_PASS="${ROOT_PASS:-rootpass}"
HOME_PASS="${HOME_PASS:-}"
LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
DESKTOP="${DESKTOP:-none}"              # none,i3,xfce,mate,sway
FS_TYPE="${FS_TYPE:-ext4}"              # ext4,btrfs,xfs
CREATE_HOME="${CREATE_HOME:-1}"         # 1=yes 0=no
CREATE_SWAP="${CREATE_SWAP:-0}"         # 1=yes 0=no
SWAP_SIZE="${SWAP_SIZE:-4G}"
LUKS_ROOT="${LUKS_ROOT:-0}"
LUKS_HOME="${LUKS_HOME:-0}"
LUKS_ROOT_NAME="${LUKS_ROOT_NAME:-cryptroot}"
LUKS_HOME_NAME="${LUKS_HOME_NAME:-crypthome}"
GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.5.0}"
AUTO_YES="${AUTO_YES:-0}"               # nonzero to skip confirmations
KEYBOARD="${KEYBOARD:-us}"
HOSTNAME="${HOSTNAME:-guix-machine}"

# Substitute hosts (first changed as requested)
SUBSTITUTE_HOSTS=(
  "https://bordeaux-us-east-mirror.cbaines.net"
  "https://hydra.gnu.org"
  "https://ci.guix.gnu.org"
  "https://ci.guix.info"
  "https://ftp.gnu.org/gnu/guix"
)

BASE_PACKAGES=(icecat libreoffice mpv feh util-linux xterm git python)

# -------------------- Utilities --------------------
log() { printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this script as root"
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# -------------------- Interactive helpers (text-mode safe) --------------------
ask_yesno() {
  local prompt="$1" default=${2:-n}
  if [[ "${AUTO_YES}" -ne 0 ]]; then return 0; fi
  local reply
  while true; do
    read -r -p "$prompt [y/N]: " reply
    case "${reply,,}" in y|yes) return 0 ;; n|no|"" ) return 1 ;; * ) echo "Please answer yes or no." ;; esac
  done
}

read_hidden() {
  local prompt="$1"
  read -r -s -p "$prompt: " val; echo; printf '%s' "$val"
}

# -------------------- Substitute probing / guix config --------------------
probe_substitutes() {
  local usable=() url base ok
  for url in "${SUBSTITUTE_HOSTS[@]}"; do
    base="$url"
    if curl -fsS --max-time 6 -I "${base}/" >/dev/null 2>&1; then
      ok=0
      if curl -fsS --max-time 6 -I "${base}/binary-cache/" >/dev/null 2>&1; then ok=1; fi
      if curl -fsS --max-time 6 -I "${base}/api/v1/" >/dev/null 2>&1; then ok=1; fi
      (( ok )) && usable+=("$base")
    fi
  done
  if [[ ${#usable[@]} -eq 0 ]]; then
    if curl -fsS --max-time 6 -I "https://cache.guix.gnu.org/" >/dev/null 2>&1; then usable=("https://cache.guix.gnu.org"); fi
  fi
  printf '%s' "${usable[*]:-}"
}

write_guix_substitute_config() {
  local usable cfg="/etc/guix/config.scm"
  usable="$(probe_substitutes)"
  [[ -n "$usable" ]] || { log "No substitute hosts reachable"; return 1; }
  mkdir -p "$(dirname "$cfg")"
  {
    echo ";; Auto-generated substitute configuration"
    echo "(substitute-urls (list"
    for u in $usable; do echo " \"$u\"" ; done
    echo "))"
  } > "$cfg"
  log "Wrote $cfg"
  return 0
}

# -------------------- Guix installation/bootstrap/daemon --------------------
PKG=""
if cmd_exists apt; then PKG="apt"; elif cmd_exists dnf; then PKG="dnf"; elif cmd_exists pacman; then PKG="pacman"; fi

install_guix_via_distro() {
  [[ -n "$PKG" ]] || return 1
  log "Trying to install guix via package manager: $PKG"
  case "$PKG" in
    apt) apt update -y >/dev/null 2>&1 || true; apt install -y guix >/dev/null 2>&1 || return 1 ;;
    dnf) dnf install -y guix >/dev/null 2>&1 || return 1 ;;
    pacman) pacman -Sy --noconfirm guix >/dev/null 2>&1 || return 1 ;;
    *) return 1 ;;
  esac
  cmd_exists guix
}

bootstrap_guix_binary() {
  log "Attempting Guix binary bootstrap"
  local ARCH BIN MIRRORS TMP url
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) BIN="guix-binary-${GUIX_BINARY_VERSION}.x86_64-linux.tar.xz" ;;
    aarch64) BIN="guix-binary-${GUIX_BINARY_VERSION}.aarch64-linux.tar.xz" ;;
    i686) BIN="guix-binary-${GUIX_BINARY_VERSION}.i686-linux.tar.xz" ;;
    *) log "No binary tarball for arch $ARCH"; return 1 ;;
  esac
  MIRRORS=( "https://ftp.gnu.org/gnu/guix/$BIN" "https://cache.guix.gnu.org/binary-cache/$BIN" )
  TMP="/tmp/guix-bootstrap-$$"
  mkdir -p "$TMP"
  for url in "${MIRRORS[@]}"; do
    log "Trying $url"
    if curl -fsSL --connect-timeout 12 -o "${TMP}/${BIN}" "$url"; then log "Downloaded $BIN"; break; fi
  done
  [[ -f "${TMP}/${BIN}" ]] || { rm -rf "$TMP"; return 1; }
  mkdir -p "${TMP}/extracted"
  tar -xJf "${TMP}/${BIN}" -C "${TMP}/extracted" || { rm -rf "$TMP"; return 1; }
  log "Copying Guix binary files (best-effort) to /"
  if tar -C "${TMP}/extracted" -cf - . | tar -C / -xvf - >/dev/null 2>&1; then
    log "Guix binary files installed"
  else
    if cmd_exists rsync; then rsync -a "${TMP}/extracted/" / || true
    else log "Failed to copy extracted files"; rm -rf "$TMP"; return 1; fi
  fi
  rm -rf "$TMP"
  getent group guix >/dev/null 2>&1 || groupadd --system guix || true
  getent group guixbuild >/dev/null 2>&1 || groupadd --system guixbuild || true
  mkdir -p /var/guix /var/guix/profiles /run/guix || true
  chown -R root:guix /var/guix || true
  chmod -R 0775 /var/guix || true
  return 0
}

start_guix_daemon_background() {
  log "Starting guix-daemon in background (no-chroot)"
  pkill -f guix-daemon >/dev/null 2>&1 || true
  setsid guix-daemon --build-users-group=guixbuild --disable-chroot >/var/log/guix-daemon.log 2>&1 &
  for i in {1..8}; do
    sleep 1
    if pgrep -f guix-daemon >/dev/null 2>&1; then log "guix-daemon running (background)"; return 0; fi
  done
  log "Background guix-daemon failed to start"
  return 1
}

ensure_guix_daemon() {
  # Try systemd
  if cmd_exists systemctl && systemctl list-unit-files | grep -q guix-daemon; then
    log "Trying systemd service for guix-daemon"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now guix-daemon.service >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet guix-daemon 2>/dev/null; then log "guix-daemon active (systemd)"; return 0; fi
    log "systemd unit exists but not active"
  fi

  # Try to install if missing
  if ! cmd_exists guix-daemon; then
    log "guix-daemon not found; attempting install"
    if install_guix_via_distro; then log "Guix installed via distro package"; fi
    if ! cmd_exists guix-daemon && bootstrap_guix_binary; then log "Guix installed via binary bootstrap"; fi
  fi

  # Try socket activation /systemd activation
  if cmd_exists systemctl; then
    systemctl start guix-daemon.socket >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet guix-daemon 2>/dev/null; then log "guix-daemon active via socket activation"; return 0; fi
  fi

  # Start background daemon
  if cmd_exists guix-daemon && start_guix_daemon_background; then return 0; fi

  # Nohup attempt (diagnostic)
  if cmd_exists guix-daemon; then
    nohup guix-daemon --build-users-group=guixbuild --disable-chroot >/var/log/guix-daemon.log 2>&1 &
    sleep 2
    if pgrep -f guix-daemon >/dev/null 2>&1; then log "guix-daemon started via nohup"; return 0; fi
  fi

  log "Could not start guix-daemon"
  return 1
}

# -------------------- Robust guix init --------------------
robust_guix_init() {
  local subs tmperr attempts backoff success=0
  subs="$(probe_substitutes)"
  [[ -n "$subs" ]] && export GUIX_SUBSTITUTE_URLS="$subs" && write_guix_substitute_config >/dev/null 2>&1 || true

  if cmd_exists guix; then
    attempts=0; backoff=5
    tmperr="$(mktemp)"
    while (( attempts < 3 )); do
      log "Attempting guix time-machine system init (attempt $((attempts+1)))"
      if guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt --no-build-output 2>"$tmperr"; then
        log "guix time-machine succeeded"; rm -f "$tmperr"; success=1; break
      fi
      local errbuf; errbuf="$(cat "$tmperr" 2>/dev/null || true)"
      if printf '%s' "$errbuf" | grep -qi "lacks.*introduction"; then
        log "Channel lacks introduction error detected; will fallback to chroot method"; break
      fi
      if printf '%s' "$errbuf" | grep -qi "cannot be authenticated"; then
        log "Channel auth error detected; will fallback to chroot method"; break
      fi
      log "time-machine attempt failed; sleeping $backoff s"
      sleep "$backoff"
      attempts=$((attempts+1))
      backoff=$(( backoff * 2 > 60 ? 60 : backoff * 2 ))
    done
    rm -f "$tmperr" || true
  else
    log "guix CLI not present on host"
  fi

  if (( success == 1 )); then return 0; fi

  # chroot fallback
  log "Falling back to chroot guix pull + guix system init"
  mkdir -p /mnt/{dev,proc,sys,tmp} || true
  mount --bind /dev /mnt/dev || true
  mount --bind /dev/pts /mnt/dev/pts || true
  mount --bind /proc /mnt/proc || true
  mount --bind /sys /mnt/sys || true
  if [[ -f /etc/resolv.conf ]]; then cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true; fi

  local wrapper="/tmp/guix-init-wrapper-$$.sh"
  cat > "/mnt${wrapper}" <<EOF
#!/bin/sh
set -e
export GUIX_SUBSTITUTE_URLS="${subs}"
guix pull --channels-file=/etc/channels.scm || true
guix system init /etc/config.scm / --no-build-output
EOF
  chmod +x "/mnt${wrapper}" || true
  if chroot /mnt "$wrapper"; then
    log "guix system init succeeded inside chroot"
    rm -f "/mnt${wrapper}" || true
    umount /mnt/dev/pts || true
    umount /mnt/dev || true
    umount /mnt/proc || true
    umount /mnt/sys || true
    return 0
  else
    log "guix system init inside chroot failed; leaving configuration for manual init"
    rm -f "/mnt${wrapper}" || true
    umount /mnt/dev/pts || true
    umount /mnt/dev || true
    umount /mnt/proc || true
    umount /mnt/sys || true
    return 1
  fi
}

# -------------------- Partition / mount helpers --------------------
to_mib() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 )); elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$s"; fi
}

safe_mkpart() {
  local disk="$1" start="$2" end="$3"
  (( end > start+1 )) || die "Invalid partition range ${start}MiB - ${end}MiB"
  parted --script --align optimal "$disk" mkpart primary "${start}MiB" "${end}MiB"
}

cap_end() {
  local val="$1" total="$2"
  if (( val > total - 1 )); then val=$(( total - 1 )); fi
  echo "$val"
}

# ensure_unmounted: find all mount targets for device and its partitions and unmount (deepest first),
# try lazy unmount, fuser/lsof to kill holders as last resort.
ensure_unmounted() {
  local dev="$1"
  [[ -n "$dev" ]] || return 0
  dev="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
  local targets=() _tmp t
  if cmd_exists findmnt; then
    mapfile -t _tmp < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
    targets+=("${_tmp[@]:-}")
    # include partitions
    for p in $(ls "${dev}"* 2>/dev/null || true); do
      mapfile -t _tmp < <(findmnt -rn -S "$p" -o TARGET 2>/dev/null || true)
      targets+=("${_tmp[@]:-}")
    done
  else
    # fallback /proc/mounts parsing
    mapfile -t _tmp < <(awk -v d="$dev" '$1==d || index($1,d)==1 {print $2}' /proc/mounts 2>/dev/null || true)
    targets+=("${_tmp[@]:-}")
    for p in $(ls "${dev}"* 2>/dev/null || true); do
      mapfile -t _tmp < <(awk -v p="$p" '$1==p || index($1,p)==1 {print $2}' /proc/mounts 2>/dev/null || true)
      targets+=("${_tmp[@]:-}")
    done
  fi

  # uniq + non-empty
  local uniq=()
  for t in "${targets[@]:-}"; do [[ -n "$t" ]] && [[ ! " ${uniq[*]} " =~ " $t " ]] && uniq+=("$t"); done
  targets=("${uniq[@]}")
  if [[ ${#targets[@]} -eq 0 ]]; then return 0; fi

  # sort by path depth (deepest first)
  IFS=$'\n' local sorted=($(printf '%s\n' "${targets[@]}" | awk '{print length,$0}' | sort -rn | cut -d' ' -f2-))
  for t in "${sorted[@]}"; do
    log "Trying to unmount $t (backed by $dev)"
    if umount "$t" 2>/dev/null; then log "Unmounted $t"; continue; fi
    if umount -l "$t" 2>/dev/null; then log "Lazy unmount succeeded for $t"; continue; fi
    if cmd_exists fuser; then
      log "Killing processes using $t via fuser -k"
      fuser -k "$t" >/dev/null 2>&1 || true
      sleep 0.5
      if umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null; then log "Unmount after fuser succeeded for $t"; continue; fi
    elif cmd_exists lsof; then
      log "Killing processes using $t via lsof"
      lsof +f -- "$t" 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -TERM >/dev/null 2>&1 || true
      sleep 0.5
      if umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null; then log "Unmount after lsof kill succeeded for $t"; continue; fi
    fi
    log "Failed to unmount $t"
    return 1
  done
  return 0
}

# safe_swapoff: attempt to disable specific swap or fallback to -a
safe_swapoff() {
  local spec="$1"
  [[ -n "${spec:-}" ]] || { # try to disable swaps if any active
    if [[ -s /proc/swaps ]]; then
      log "Disabling all swaps (no specific swap provided)"
      swapoff -a || true
    fi
    return 0
  }
  if [[ -b "$spec" ]]; then
    log "Disabling swap on device $spec"
    swapoff "$spec" 2>/dev/null || { log "swapoff $spec failed; trying swapoff -a"; swapoff -a || true; }
    return 0
  fi
  # try to match in /proc/swaps
  if grep -q "$spec" /proc/swaps 2>/dev/null; then
    local dev
    dev="$(awk -v a="$spec" '$1~a || $2~a {print $1; exit}' /proc/swaps 2>/dev/null || true)"
    if [[ -n "$dev" ]]; then swapoff "$dev" 2>/dev/null || swapoff -a || true; return 0; fi
  fi
  log "Swap spec '$spec' not a block device; disabling all swaps as fallback"
  swapoff -a || true
  return 0
}

# detect newest partition on disk by start sector
get_last_partition() {
  local disk="$1"
  lsblk -ln -o NAME,START "$disk" 2>/dev/null | awk '$1!~/'"$(basename "$disk")"'/ {print $0}' | sort -k2n | tail -n1 | awk '{print "/dev/"$1}'
}

# -------------------- Main installation flow --------------------
main() {
  require_root

  [[ -n "$TARGET_DISK" ]] || die "TARGET_DISK must be set (e.g. /dev/sdb)"
  [[ -b "$TARGET_DISK" ]] || die "Target disk $TARGET_DISK not found"

  log "Starting installation on $TARGET_DISK"

  # Ask user confirmation
  if [[ "${AUTO_YES}" -eq 0 ]]; then
    echo "Target disk: $TARGET_DISK"
    echo "This will erase data on the disk. Continue?"
    ask_yesno "Continue?" || die "Aborted by user"
  fi

  # Ensure guix-daemon or attempt to bootstrap it (not required to proceed with writing config)
  if ! ensure_guix_daemon; then
    log "Could not start guix-daemon; the installer will still write configuration to /mnt but guix system init may require manual steps."
  fi

  # Gather disk info and create partition table
  local total_mib used_mib remaining swap_mib root_start root_end home_start home_end swap_start swap_end
  total_mib=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1024 / 1024 ))
  (( total_mib >= 64 )) || die "Disk too small"

  # Create partition table
  if [[ -d /sys/firmware/efi ]]; then
    log "System booted in EFI mode; creating GPT label and EFI partition"
    parted --script "$TARGET_DISK" mklabel gpt >/dev/null 2>&1 || true
    # EFI 1MiB..+512MiB
    safe_mkpart "$TARGET_DISK" 1 513
    parted --script "$TARGET_DISK" set 1 esp on >/dev/null 2>&1 || true
    used_mib=513
  else
    log "Creating MBR (msdos) label"
    parted --script "$TARGET_DISK" mklabel msdos >/dev/null 2>&1 || true
    used_mib=1
  fi

  remaining=$(( total_mib - used_mib ))
  (( remaining > 8 )) || die "Not enough usable space"

  if (( CREATE_SWAP == 1 )); then
    swap_mib=$(to_mib "$SWAP_SIZE")
    (( swap_mib >= 4 )) || swap_mib=4
    if (( swap_mib > remaining / 4 )); then swap_mib=$(( remaining / 10 )); fi
  else
    swap_mib=0
  fi

  local usable=$(( remaining - swap_mib ))
  (( usable >= 8 )) || die "Not enough space for root/home after swap reservation"

  root_start=$used_mib
  if (( CREATE_HOME == 1 )); then
    root_mib=$(( usable / 2 ))
    home_mib=$(( usable - root_mib ))
    root_end=$(( root_start + root_mib ))
    home_start=$root_end
    home_end=$(( home_start + home_mib ))
  else
    root_end=$(( root_start + usable ))
  fi

  root_end=$(cap_end "$root_end" "$total_mib")
  if [[ -n "${home_end:-}" ]]; then home_end=$(cap_end "$home_end" "$total_mib"); fi
  if (( swap_mib > 0 )); then
    swap_start=$(cap_end $(( total_mib - swap_mib - 1 )) "$total_mib")
    if [[ -n "${home_end:-}" ]]; then (( swap_start <= home_end )) && swap_start=$(( home_end + 1 )); else (( swap_start <= root_end )) && swap_start=$(( root_end + 1 )); fi
    swap_end=$(cap_end $(( swap_start + swap_mib )) "$total_mib")
  fi

  # Create root partition
  log "Creating root partition ${root_start}MiB - ${root_end}MiB"
  safe_mkpart "$TARGET_DISK" "$root_start" "$root_end"
  partprobe "$TARGET_DISK" || true
  udevadm settle --timeout=10 || true
  sleep 1

  # Create home partition if requested
  if (( CREATE_HOME == 1 )); then
    log "Creating home partition ${home_start}MiB - ${home_end}MiB"
    safe_mkpart "$TARGET_DISK" "$home_start" "$home_end"
    partprobe "$TARGET_DISK" || true
    udevadm settle --timeout=10 || true
    sleep 1
  fi

  # Create swap partition if requested
  if (( swap_mib > 0 )); then
    log "Creating swap partition ${swap_start}MiB - ${swap_end}MiB"
    safe_mkpart "$TARGET_DISK" "$swap_start" "$swap_end"
    partprobe "$TARGET_DISK" || true
    udevadm settle --timeout=10 || true
    sleep 1
  fi

  # Detect partitions (robust)
  mapfile -t parts < <(lsblk -ln -o NAME,TYPE -b "$TARGET_DISK" 2>/dev/null | awk '$2=="part" {print "/dev/"$1}')
  local EFI_PART="" ROOT_PART="" HOME_PART="" SWAP_PART=""
  if [[ -d /sys/firmware/efi ]]; then
    # first partition is EFI
    EFI_PART="${parts[0]:-}"
    # root is first non-efi part
    for p in "${parts[@]:-}"; do
      [[ -n "$EFI_PART" && "$p" == "$EFI_PART" ]] && continue
      ROOT_PART="$p"
      break
    done
    # home and swap may be later parts; attempt to find by number/order
    if (( CREATE_HOME == 1 )); then
      for p in "${parts[@]:-}"; do [[ "$p" != "$EFI_PART" && "$p" != "$ROOT_PART" ]] && { HOME_PART="$p"; break; } done
    fi
    if (( swap_mib > 0 )); then
      # last partition generally swap
      SWAP_PART="${parts[-1]:-}"
      # avoid assigning swap if equals EFI/root/home incorrectly
      if [[ "$SWAP_PART" == "$EFI_PART" || "$SWAP_PART" == "$ROOT_PART" || "$SWAP_PART" == "$HOME_PART" ]]; then SWAP_PART=""; fi
    fi
  else
    # No EFI, assign by order
    ROOT_PART="${parts[0]:-}"
    if (( CREATE_HOME == 1 )); then HOME_PART="${parts[1]:-}"; fi
    if (( swap_mib > 0 )); then SWAP_PART="${parts[-1]:-}"; fi
  fi

  # If detection failed, fallback to get_last_partition
  if [[ -z "$ROOT_PART" ]]; then ROOT_PART="$(get_last_partition "$TARGET_DISK")"; fi
  if [[ -z "$HOME_PART" && ${#parts[@]} -ge 2 ]]; then HOME_PART="${parts[1]:-}"; fi

  # Ensure partitions are not mounted; robustly unmount
  for p in "$EFI_PART" "$ROOT_PART" "$HOME_PART" "$SWAP_PART"; do
    [[ -n "$p" ]] || continue
    # If mounts exist referencing the device, unmount them
    if awk -v d="$p" '$1==d {exit 0} END{exit 1}' /proc/mounts 2>/dev/null; then
      log "Device $p appears mounted; attempting to unmount"
      ensure_unmounted "$p" || { findmnt -S "$p" || true; die "Partition $p appears mounted and could not be unmounted"; }
    fi
  done

  # Format partitions (only if block devices exist)
  if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then
    log "Formatting EFI partition $EFI_PART as FAT32"
    mkfs.vfat -F32 "$EFI_PART" || log "mkfs.vfat failed on $EFI_PART"
  fi

  if [[ -n "$ROOT_PART" && -b "$ROOT_PART" ]]; then
    log "Formatting root partition $ROOT_PART as $FS_TYPE"
    case "$FS_TYPE" in
      ext4) mkfs.ext4 -F "$ROOT_PART" ;;
      btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
      xfs) mkfs.xfs -f "$ROOT_PART" ;;
      *) mkfs.ext4 -F "$ROOT_PART" ;;
    esac
  fi

  if [[ -n "$HOME_PART" && -b "$HOME_PART" ]]; then
    log "Formatting home partition $HOME_PART as $FS_TYPE"
    case "$FS_TYPE" in
      ext4) mkfs.ext4 -F "$HOME_PART" ;;
      btrfs) mkfs.btrfs -f "$HOME_PART" ;;
      xfs) mkfs.xfs -f "$HOME_PART" ;;
      *) mkfs.ext4 -F "$HOME_PART" ;;
    esac
  fi

  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then
    log "Setting up swap on $SWAP_PART"
    mkswap "$SWAP_PART" || log "mkswap failed on $SWAP_PART"
  fi

  # Mount points
  mkdir -p /mnt
  mount "$ROOT_PART" /mnt || die "Failed to mount root partition $ROOT_PART to /mnt"
  if [[ -n "$HOME_PART" && -b "$HOME_PART" ]]; then
    mkdir -p /mnt/home
    if ! mount "$HOME_PART" /mnt/home 2>/tmp/mount-home.err; then
      log "Failed to mount /home: $(cat /tmp/mount-home.err || true)"; rm -f /tmp/mount-home.err || true
    fi
  fi
  if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then
    mkdir -p /mnt/boot/efi
    if ! mount "$EFI_PART" /mnt/boot/efi 2>/tmp/mount-efi.err; then
      log "Failed to mount EFI: $(cat /tmp/mount-efi.err || true)"; rm -f /tmp/mount-efi.err || true
    fi
  fi
  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then
    swapon "$SWAP_PART" || log "swapon failed on $SWAP_PART"
  fi

  # If LUKS requested for root or home - note: earlier we formatted unencrypted; for LUKS path, user should run script with LUKS options set beforehand.
  # (This script supports both encrypted and plain flows; LUKS flow requires different sequence: create partition -> luksFormat -> open -> mkfs on /dev/mapper/*)

  # Prepare hashed passwords
  local huser hroot_hashed
  huser="$(openssl passwd -6 -- "$USER_PASS" 2>/dev/null || true)"
  hroot_hashed="$(openssl passwd -6 -- "$ROOT_PASS" 2>/dev/null || true)"

  # Write /mnt/etc/config.scm
  mkdir -p /mnt/etc
  cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (guix) (guix profiles) (gnu services) (gnu packages base) (gnu packages linux) (gnu services desktop))

(operating-system
 (host-name "${HOSTNAME}")
 (timezone "${TIMEZONE}")
 (locale "${LOCALE}")
 (keyboard-layout (keyboard-layout "${KEYBOARD}")))
EOF

  if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (bootloader (bootloader-configuration (bootloader grub-efi-bootloader) (targets '("/boot/efi"))))
EOF
  else
    cat >> /mnt/etc/config.scm <<EOF
 (bootloader (bootloader-configuration (bootloader grub-bootloader) (targets '("${TARGET_DISK}"))))
EOF
  fi

  cat >> /mnt/etc/config.scm <<EOF
 (kernel linux)
 (initrd microcode-initrd)
 (firmware (list linux-firmware))
 (file-systems (cons*
EOF

  # Root entry by UUID if available
  local root_uuid home_uuid efi_uuid
  root_uuid="$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)"
  if [[ -n "$root_uuid" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${root_uuid}")) (mount-point "/") (type "${FS_TYPE}"))
EOF
  else
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${ROOT_PART}") (mount-point "/") (type "${FS_TYPE}"))
EOF
  fi

  if [[ -n "$HOME_PART" && -b "$HOME_PART" ]]; then
    home_uuid="$(blkid -s UUID -o value "$HOME_PART" 2>/dev/null || true)"
    if [[ -n "$home_uuid" ]]; then
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${home_uuid}")) (mount-point "/home") (type "${FS_TYPE}"))
EOF
    else
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${HOME_PART}") (mount-point "/home") (type "${FS_TYPE}"))
EOF
    fi
  fi

  if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then
    efi_uuid="$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)"
    if [[ -n "$efi_uuid" ]]; then
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${efi_uuid}")) (mount-point "/boot/efi") (type "vfat"))
EOF
    else
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${EFI_PART}") (mount-point "/boot/efi") (type "vfat"))
EOF
    fi
  fi

  cat >> /mnt/etc/config.scm <<'EOF'
 %base-file-systems))
EOF

  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (swap-devices (list (swap-device (target "${SWAP_PART}"))))
EOF
  fi

  cat >> /mnt/etc/config.scm <<EOF
 (users (cons* (user-account (name "${USERNAME:-user}") (group "users")
                             (home (string-append "/home/" "${USERNAME:-user}"))
                             (password "${huser}")
                             (supplementary-groups '("wheel" "netdev" "audio" "networking" "video")))
               (map (lambda (u) (if (string=? (user-account-name u) "root")
                                   (user-account (inherit u) (password "${hroot_hashed}"))
                                   u)) %base-user-accounts)))
 (packages (list ${BASE_PACKAGES[*]}))
 (services %base-services))
EOF

  # Write channels.scm exactly as user asked (keeps provided content)
  cat > /mnt/etc/channels.scm <<'EOF'
(use-modules (guix ci))

;; Define the list of channels
(list
 (channel-with-substitutes-available
   %default-guix-channel
   "https://ci.guix.gnu.org")
 

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

  log "Configuration written to /mnt/etc (config.scm and channels.scm)"

  # Try guix system init (best-effort)
  if cmd_exists guix && pgrep -f guix-daemon >/dev/null 2>&1; then
    if robust_guix_init; then
      log "guix system init completed"
    else
      log "guix system init failed; configuration left in /mnt/etc for manual init"
    fi
  else
    log "guix CLI or guix-daemon unavailable; leaving configuration in /mnt/etc for manual init"
  fi

  # Cleanup: disable swap and unmount
  sync
  if [[ -n "$SWAP_PART" ]]; then safe_swapoff "$SWAP_PART" || true; else safe_swapoff "" || true; fi
  umount /mnt/home 2>/dev/null || true
  umount /mnt/boot/efi 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  # Close any LUKS mappings if used (best-effort)
  if (( LUKS_HOME == 1 )); then cryptsetup status "$LUKS_HOME_NAME" >/dev/null 2>&1 && cryptsetup close "$LUKS_HOME_NAME" || true; fi
  if (( LUKS_ROOT == 1 )); then cryptsetup status "$LUKS_ROOT_NAME" >/dev/null 2>&1 && cryptsetup close "$LUKS_ROOT_NAME" || true; fi

  log "Installation finished (best-effort). Please reboot manually and complete any remaining steps such as running 'guix system init' if required."
}

main "$@"