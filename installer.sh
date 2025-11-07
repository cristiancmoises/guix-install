#!/usr/bin/env bash
set -euo pipefail

# GNU Guix guided installer 
# - Writes channels.scm with the user-supplied content
# - WARNING: destructive operations. Review TARGET_DISK before running. Run as root from a live environment.

# -------------------- Configurable defaults --------------------
LANG_OPT="${LANG_OPT:-en}"
USE_GUI="${USE_GUI:-auto}"
AUTO_YES="${AUTO_YES:-0}"
TARGET_DISK="${TARGET_DISK:-}"          # e.g. /dev/sdb
USERNAME="${USERNAME:-}"
USER_PASS="${USER_PASS:-}"
ROOT_PASS="${ROOT_PASS:-}"
HOME_PASS="${HOME_PASS:-}"
LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
DESKTOP="${DESKTOP:-none}"
FS_TYPE="${FS_TYPE:-ext4}"
CREATE_HOME="${CREATE_HOME:-}"
CREATE_SWAP="${CREATE_SWAP:-}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
LUKS_ROOT="${LUKS_ROOT:-}"
LUKS_HOME="${LUKS_HOME:-}"
LUKS_ROOT_NAME="${LUKS_ROOT_NAME:-cryptroot}"
LUKS_HOME_NAME="${LUKS_HOME_NAME:-crypthome}"
GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.5.0}"

# Updated substitute hosts (first changed as requested)
SUBSTITUTE_HOSTS=(
  "https://bordeaux-us-east-mirror.cbaines.net"
  "https://hydra.gnu.org"
  "https://ci.guix.gnu.org"
  "https://ci.guix.info"
  "https://ftp.gnu.org/gnu/guix"
)

BASE_PACKAGES=(icecat libreoffice mpv feh util-linux xterm git python)

# -------------------- Messages --------------------
WELCOME_TITLE="Welcome to the GNU Guix installer"
WELCOME_SUB="Guided installation with LUKS and Guix"
SELECT_DISK="Select target disk"
SELECT_PART="Partition options"
USER_SETUP="User and password setup"
SUMMARY_TITLE="Installation summary"
INSTALL_MSG="Installing — please wait"
FINISH_MSG="Installation finished"
ABORT_MSG="Installation aborted by user"
GUIX_BOOTSTRAP_MSG="Attempting to install Guix (distro package or binary)"
PLEASE_ANSWER="Please answer yes or no"

# -------------------- Helpers --------------------
log(){ printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }
die(){ log "ERROR: $*" >&2; exit 1; }

KEYBOARD="${KEYBOARD:-us}"
HOSTNAME="${HOSTNAME:-guix-machine}"

PKG=""
if command -v apt >/dev/null 2>&1; then PKG="apt"
elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
elif command -v pacman >/dev/null 2>&1; then PKG="pacman"
fi

# -------------------- GUI wrappers --------------------
detect_gui() {
  GUI_TOOL=""
  if [[ "${USE_GUI}" == "text" ]]; then GUI_TOOL=""; return; fi
  if command -v yad >/dev/null 2>&1; then GUI_TOOL="yad"; return; fi
  if command -v zenity >/dev/null 2>&1; then GUI_TOOL="zenity"; return; fi
  GUI_TOOL=""
}

gui_info() {
  local title="$1" msg="$2"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then yad --title "$title" --info --text "$msg" --timeout=4 >/dev/null 2>&1 || true
    else zenity --info --title="$title" --text="$msg" --timeout=4 >/dev/null 2>&1 || true; fi
  else
    printf '%s: %s\n' "$title" "$msg"
  fi
}

gui_entry() {
  local title="$1" prompt="$2" default="$3"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then yad --title "$title" --entry --text "$prompt" --entry-text "$default" 2>/dev/null || echo "$default"
    else zenity --entry --title="$title" --text="$prompt" --entry-text="$default" 2>/dev/null || echo "$default"; fi
  else
    if [[ "${AUTO_YES:-0}" -eq 1 ]]; then
      echo "$default"
    else
      read -r -p "$prompt [$default]: " v
      echo "${v:-$default}"
    fi
  fi
}

gui_password() {
  local title="$1" prompt="$2"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then yad --title "$title" --entry --text "$prompt" --entry-password 2>/dev/null || true
    else zenity --password --title="$title" --text="$prompt" 2>/dev/null || true; fi
  else
    read -r -s -p "$prompt: " pw; echo; echo "$pw"
  fi
}

gui_list() {
  local title="$1" prompt="$2"; shift 2; local choices=("$@")
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then printf "%s\n" "${choices[@]}" | yad --list --title "$title" --column "$prompt" --height=240 --width=320 2>/dev/null | head -n1
    else printf "%s\n" "${choices[@]}" | zenity --list --title="$title" --column="$prompt" --height=240 --width=320 2>/dev/null | head -n1; fi
  else
    echo "${choices[0]}"
  fi
}

gui_yesno() {
  local title="$1" prompt="$2"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then yad --title "$title" --question --text "$prompt" --button="No":1 --button="Yes":0 >/dev/null 2>&1; return $?
    else zenity --question --title="$title" --text="$prompt" >/dev/null 2>&1; return $?
    fi
  fi
  if [[ "${AUTO_YES:-0}" -eq 1 ]]; then return 0; fi
  while true; do
    read -r -p "$prompt [y/N]: " ans
    case "$ans" in [YySs]* ) return 0 ;; [Nn]* ) return 1 ;; * ) echo "$PLEASE_ANSWER" ;; esac
  done
}

# -------------------- Substitute probing --------------------
probe_substitutes() {
  local usable=()
  local url base ok
  for url in "${SUBSTITUTE_HOSTS[@]}"; do
    base="$url"
    if curl -fsS --max-time 6 -I "${base}/" >/dev/null 2>&1; then
      ok=0
      if curl -fsS --max-time 6 -I "${base}/binary-cache/" >/dev/null 2>&1; then ok=1; fi
      if curl -fsS --max-time 6 -I "${base}/api/v1/" >/dev/null 2>&1; then ok=1; fi
      if (( ok == 1 )); then usable+=("$base"); fi
    fi
  done
  if [[ ${#usable[@]} -eq 0 ]]; then
    if curl -fsS --max-time 6 -I "https://cache.guix.gnu.org/" >/dev/null 2>&1; then usable+=("https://cache.guix.gnu.org"); fi
  fi
  printf '%s' "${usable[*]}"
}

write_guix_substitute_config() {
  local usable
  usable="$(probe_substitutes)"
  [[ -n "$usable" ]] || { log "No substitute hosts reachable"; return 1; }
  local cfg="/etc/guix/config.scm"
  mkdir -p "$(dirname "$cfg")"
  {
    echo ";; Auto-generated substitute configuration"
    echo "(substitute-urls (list"
    for u in $usable; do echo " \"$u\"" ; done
    echo "))"
  } > "$cfg"
  log "Wrote $cfg"
  printf '%s' "$usable"
}

# -------------------- Guix bootstrap helpers --------------------
install_guix_via_distro() {
  if [[ -z "$PKG" ]]; then return 1; fi
  log "Trying to install guix via package manager: $PKG"
  case "$PKG" in
    apt) apt update -y >/dev/null 2>&1 || true; apt install -y guix >/dev/null 2>&1 || return 1 ;;
    dnf) dnf install -y guix >/dev/null 2>&1 || return 1 ;;
    pacman) pacman -Sy --noconfirm guix >/dev/null 2>&1 || return 1 ;;
    *) return 1 ;;
  esac
  command -v guix >/dev/null 2>&1
}

bootstrap_guix_binary() {
  log "$GUIX_BOOTSTRAP_MSG"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) BIN="guix-binary-${GUIX_BINARY_VERSION}.x86_64-linux.tar.xz" ;;
    aarch64) BIN="guix-binary-${GUIX_BINARY_VERSION}.aarch64-linux.tar.xz" ;;
    i686) BIN="guix-binary-${GUIX_BINARY_VERSION}.i686-linux.tar.xz" ;;
    *) BIN="" ;;
  esac
  [[ -n "$BIN" ]] || { log "No binary tarball for arch $ARCH"; return 1; }

  MIRRORS=( "https://ftp.gnu.org/gnu/guix/$BIN" "https://cache.guix.gnu.org/binary-cache/$BIN" )
  TMP="/tmp/guix-bootstrap-$$"
  mkdir -p "$TMP"
  for url in "${MIRRORS[@]}"; do
    log "Trying $url"
    if curl -fsSL --connect-timeout 12 -o "${TMP}/${BIN}" "$url"; then log "Downloaded $BIN"; break; fi
  done
  [[ -f "${TMP}/${BIN}" ]] || { log "Download failed"; rm -rf "$TMP"; return 1; }

  mkdir -p "${TMP}/extracted"
  if ! tar -xJf "${TMP}/${BIN}" -C "${TMP}/extracted"; then log "Extraction failed"; rm -rf "$TMP"; return 1; fi

  log "Installing Guix binary (best-effort) to /"
  if tar -C "${TMP}/extracted" -cf - . | tar -C / -xvf - >/dev/null 2>&1; then
    log "Guix binary files copied"
  else
    if command -v rsync >/dev/null 2>&1; then rsync -a "${TMP}/extracted/" / || true
    else log "Failed to copy extracted files"; rm -rf "$TMP"; return 1; fi
  fi

  if ! getent group guix >/dev/null 2>&1; then groupadd --system guix || true; fi
  if ! getent group guixbuild >/dev/null 2>&1; then groupadd --system guixbuild || true; fi
  mkdir -p /var/guix /var/guix/profiles /run/guix || true
  chown -R root:guix /var/guix || true
  chmod -R 0775 /var/guix || true
  rm -rf "$TMP"
  command -v guix >/dev/null 2>&1 || log "guix may be installed but not on PATH"
  return 0
}

ensure_guix_daemon() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q guix-daemon; then
    log "Starting guix-daemon via systemd"
    systemctl enable --now guix-daemon.service >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet guix-daemon; then log "guix-daemon active (systemd)"; return 0; fi
    log "systemd start failed; fallback to background start"
  fi

  if command -v guix-daemon >/dev/null 2>&1; then
    log "Starting guix-daemon in background"
    pkill -f guix-daemon >/dev/null 2>&1 || true
    setsid guix-daemon --build-users-group=guixbuild --disable-chroot >/var/log/guix-daemon.log 2>&1 &
    sleep 2
    if pgrep -f guix-daemon >/dev/null 2>&1; then log "guix-daemon started (background)"; return 0; fi
  fi

  log "Could not start guix-daemon"
  return 1
}

# -------------------- Robust guix init (time-machine fallback to chroot method) --------------------
robust_guix_init() {
  local subs attempts backoff success=0 errbuf tmperr tmpf wrapper_name
  subs="$(probe_substitutes)"
  if [[ -n "$subs" ]]; then
    export GUIX_SUBSTITUTE_URLS="$subs"
    write_guix_substitute_config >/dev/null 2>&1 || true
    log "Using substitute hosts: $subs"
  else
    log "No substitutes reachable; will proceed without preconfigured substitutes"
  fi

  if command -v guix >/dev/null 2>&1; then
    attempts=0; backoff=5
    tmperr="$(mktemp)"
    while (( attempts < 3 )); do
      log "Attempting guix time-machine (attempt $((attempts+1)))"
      if guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt --no-build-output 2>"$tmperr"; then
        log "guix time-machine succeeded"
        rm -f "$tmperr" || true
        success=1; break
      fi
      errbuf="$(cat "$tmperr" 2>/dev/null || true)"
      if printf '%s' "$errbuf" | grep -qi "lacks.*introduction"; then
        log "Detected channel 'lacks introduction' error; falling back to chroot method"
        break
      fi
      if printf '%s' "$errbuf" | grep -qi "cannot be authenticated"; then
        log "Detected channel authentication error; falling back to chroot method"
        break
      fi
      log "time-machine attempt failed; sleeping $backoff s"
      sleep "$backoff"
      attempts=$((attempts+1))
      backoff=$(( backoff * 2 > 60 ? 60 : backoff * 2 ))
    done
    rm -f "$tmperr" || true
  else
    log "guix CLI not on host; skipping time-machine tries"
  fi

  if (( success == 1 )); then return 0; fi

  # Chroot fallback
  log "Falling back to chroot guix pull + guix system init"

  mkdir -p /mnt/{dev,proc,sys,tmp} || true
  mount --bind /dev /mnt/dev || true
  mount --bind /dev/pts /mnt/dev/pts || true
  mount --bind /proc /mnt/proc || true
  mount --bind /sys /mnt/sys || true
  if [[ -f /etc/resolv.conf ]]; then cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true; fi

  wrapper_name="/tmp/guix-init-wrapper-$$.sh"
  tmpf="/mnt${wrapper_name}"

  if [[ -n "$subs" ]]; then
    cat > "$tmpf" <<EOF
#!/bin/sh
export GUIX_SUBSTITUTE_URLS="${subs}"
set -e
guix pull --channels-file=/etc/channels.scm || true
guix system init /etc/config.scm / --no-build-output
EOF
  else
    cat > "$tmpf" <<'EOF'
#!/bin/sh
set -e
guix pull --channels-file=/etc/channels.scm || true
guix system init /etc/config.scm / --no-build-output
EOF
  fi
  chmod +x "$tmpf" || true

  if chroot /mnt "$wrapper_name"; then
    log "guix system init inside chroot succeeded"
    rm -f "$tmpf" || true
    umount /mnt/dev/pts || true
    umount /mnt/dev || true
    umount /mnt/proc || true
    umount /mnt/sys || true
    return 0
  else
    log "guix system init inside chroot failed; leaving /mnt/etc for manual init"
    rm -f "$tmpf" || true
    umount /mnt/dev/pts || true
    umount /mnt/dev || true
    umount /mnt/proc || true
    umount /mnt/sys || true
    return 1
  fi
}

# -------------------- Partition helpers --------------------
to_mib(){ local s="$1"; if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 )); elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$s"; fi; }

safe_mkpart() {
  local disk="$1" start="$2" end="$3"
  if (( end <= start + 1 )); then die "Invalid partition range ${start}MiB - ${end}MiB"; fi
  parted --script --align optimal "$disk" mkpart primary "${start}MiB" "${end}MiB"
}

cap_end() {
  local val="$1" total="$2"
  if (( val > total - 1 )); then val=$(( total - 1 )); fi
  echo "$val"
}

# improved ensure_unmounted: finds all mountpoints using the device and unmounts them.
ensure_unmounted() {
  local dev="$1"
  if [[ -z "$dev" ]]; then return 0; fi
  # resolve device to canonical path (resolve symlinks)
  if command -v readlink >/dev/null 2>&1; then
    dev="$(readlink -f "$dev" || echo "$dev")"
  fi

  # find all mount targets whose source is this device or begins with this device path
  local targets
  # use findmnt if available for robust detection
  if command -v findmnt >/dev/null 2>&1; then
    IFS=$'\n' read -r -d '' -a targets < <(findmnt -nr -S "$dev" -o TARGET 2>/dev/null || true; printf '\0')
  else
    # fallback parse /proc/mounts
    IFS=$'\n' read -r -d '' -a targets < <(awk -v d="$dev" '$1==d || index($1,d)==1 {print $2}' /proc/mounts 2>/dev/null || true; printf '\0')
  fi

  # If no mountpoints found, also check for partitions (e.g., /dev/sdb -> /dev/sdb1)
  if [[ ${#targets[@]} -eq 0 ]]; then
    # look for partitions of the device
    local part
    for part in $(ls "${dev}"* 2>/dev/null || true); do
      if [[ -b "$part" ]]; then
        if command -v findmnt >/dev/null 2>&1; then
          IFS=$'\n' read -r -d '' -a more < <(findmnt -nr -S "$part" -o TARGET 2>/dev/null || true; printf '\0')
        else
          IFS=$'\n' read -r -d '' -a more < <(awk -v p="$part" '$1==p || index($1,p)==1 {print $2}' /proc/mounts 2>/dev/null || true; printf '\0')
        fi
        targets+=("${more[@]}")
      fi
    done
  fi

  # remove empty entries
  local cleaned=()
  local t
  for t in "${targets[@]:-}"; do
    [[ -n "$t" ]] && cleaned+=("$t")
  done
  targets=("${cleaned[@]}")

  if [[ ${#targets[@]} -eq 0 ]]; then
    # nothing mounted with this device
    return 0
  fi

  # attempt orderly unmount: deepest mountpoint first
  IFS=$'\n' sorted=($(printf '%s\n' "${targets[@]}" | awk '{print length,$0}' | sort -rn | cut -d' ' -f2-))
  local mp
  for mp in "${sorted[@]}"; do
    log "Attempting to unmount $mp (backed by $dev)"
    if umount "$mp" 2>/dev/null; then
      log "Unmounted $mp"
      continue
    fi
    log "Standard umount of $mp failed; trying lazy unmount -l"
    if umount -l "$mp" 2>/dev/null; then
      log "Lazy unmount succeeded for $mp"
      continue
    fi
    # try to kill processes using the mount (best-effort)
    if command -v fuser >/dev/null 2>&1; then
      log "Killing processes using $mp via fuser -k"
      fuser -k "$mp" >/dev/null 2>&1 || true
      sleep 0.5
      if umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null; then
        log "Unmount after fuser succeeded for $mp"
        continue
      fi
    elif command -v lsof >/dev/null 2>&1; then
      log "Killing processes using $mp via lsof"
      lsof +f -- "$mp" 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -TERM >/dev/null 2>&1 || true
      sleep 0.5
      if umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null; then
        log "Unmount after lsof kill succeeded for $mp"
        continue
      fi
    fi
    log "Failed to unmount $mp (attempts exhausted)"
    return 1
  done

  return 0
}

# safe_swapoff: attempt to disable swap in a safe way.
safe_swapoff() {
  local arg="$1"
  if [[ -z "${arg:-}" ]]; then
    return 0
  fi

  if [[ -b "$arg" ]]; then
    log "Disabling swap on device $arg"
    swapoff "$arg" 2>/dev/null || { log "swapoff $arg failed — trying swapoff -a"; swapoff -a || true; }
    return 0
  fi

  # if arg is present in /proc/swaps (maybe UUID path), try to match and disable
  if grep -q "$arg" /proc/swaps 2>/dev/null; then
    local dev
    dev="$(awk -v a="$arg" '$1~a || $2~a {print $1; exit}' /proc/swaps 2>/dev/null || true)"
    if [[ -n "$dev" ]]; then
      log "Disabling swap on discovered device $dev for arg $arg"
      swapoff "$dev" 2>/dev/null || swapoff -a || true
      return 0
    fi
  fi

  log "swap spec '$arg' not a block device and not found in /proc/swaps; disabling all swaps as fallback"
  swapoff -a || true
  return 0
}

# -------------------- UI Steps --------------------
detect_gui

if [[ "$(id -u)" -ne 0 ]]; then die "Run this script as root"; fi
log "Starting GNU Guix installer (improved unmount behavior)"

step_welcome() { gui_info "$WELCOME_TITLE" "$WELCOME_SUB"; }

step_select_disk() {
  mapfile -t disks < <(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk" {printf "/dev/%s (%s)\n",$1,$2}')
  [[ ${#disks[@]} -gt 0 ]] || die "No block devices found"
  if [[ -z "$TARGET_DISK" ]]; then
    choice="$(gui_list "$SELECT_DISK" "$SELECT_DISK" "${disks[@]}")"
    [[ -n "$choice" ]] || die "$ABORT_MSG"
    TARGET_DISK="$(echo "$choice" | awk '{print $1}')"
  fi
  [[ -b "$TARGET_DISK" ]] || die "Target disk $TARGET_DISK not found"
  gui_info "$SELECT_DISK" "Target: $TARGET_DISK"
}

step_partition_options() {
  if ! gui_yesno "$SELECT_PART" "Use guided partitioning (will wipe $TARGET_DISK)?"; then
    if gui_yesno "$SELECT_PART" "Open a shell for manual partitioning now?"; then bash -i; partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1; else die "$ABORT_MSG"; fi
    return
  fi

  if [[ -z "$FS_TYPE" ]]; then FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" ext4 btrfs xfs)"; fi
  if [[ -z "${CREATE_HOME}" ]]; then gui_yesno "Home" "Create separate /home partition?" && CREATE_HOME=1 || CREATE_HOME=0; fi
  if [[ -z "${CREATE_SWAP}" ]]; then gui_yesno "Swap" "Create swap partition?" && CREATE_SWAP=1 || CREATE_SWAP=0; fi
  if [[ -z "${LUKS_ROOT}" ]]; then gui_yesno "LUKS" "Encrypt root with LUKS?" && LUKS_ROOT=1 || LUKS_ROOT=0; fi
  if [[ "$CREATE_HOME" -eq 1 && -z "${LUKS_HOME}" ]]; then gui_yesno "LUKS Home" "Encrypt /home with LUKS separately?" && LUKS_HOME=1 || LUKS_HOME=0; fi

  total_mib=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1024 / 1024 ))
  (( total_mib >= 64 )) || die "Disk too small"

  if [[ -d /sys/firmware/efi ]]; then
    parted --script "$TARGET_DISK" mklabel gpt
    efi_end=512
    safe_mkpart "$TARGET_DISK" 1 "$efi_end"
    parted --script "$TARGET_DISK" set 1 esp on
    used_mib=$efi_end
  else
    parted --script "$TARGET_DISK" mklabel msdos
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

  usable=$(( remaining - swap_mib ))
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

  (( root_end > root_start + 3 )) || die "Root partition too small"
  if [[ -n "${home_start:-}" ]]; then (( home_end > home_start + 3 )) || die "Home partition too small"; fi
  if (( swap_mib > 0 )); then (( swap_end > swap_start + 3 )) || swap_mib=0; fi

  # Create root partition (encrypted or not)
  if (( LUKS_ROOT == 1 )); then
    safe_mkpart "$TARGET_DISK" "$root_start" "$root_end"
    partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1

    if [[ -b "${TARGET_DISK}p1" ]]; then
      ROOT_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}p[0-9]+" | tail -n1 || true)"
    else
      ROOT_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}[0-9]+" | tail -n1 || true)"
    fi
    [[ -n "$ROOT_PART" && -b "$ROOT_PART" ]] || die "Could not detect root partition device"

    if ! ensure_unmounted "$ROOT_PART"; then
      log "Attempt to unmount $ROOT_PART failed; re-checking mountpoints for diagnostics"
      findmnt -S "$ROOT_PART" || true
      die "Partition $ROOT_PART appears mounted and could not be unmounted"
    fi

    if [[ -z "$ROOT_PASS" ]]; then
      ROOT_PASS="$(gui_password "LUKS Root passphrase" "Enter LUKS passphrase for root")"
      [[ -n "$ROOT_PASS" ]] || die "Empty LUKS passphrase"
    fi

    log "Formatting LUKS on $ROOT_PART"
    printf '%s' "$ROOT_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$ROOT_PART" -
    printf '%s' "$ROOT_PASS" | cryptsetup open "$ROOT_PART" "$LUKS_ROOT_NAME" --
    MAPPED_ROOT="/dev/mapper/${LUKS_ROOT_NAME}"
    sleep 1
    case "$FS_TYPE" in ext4) mkfs.ext4 -F "$MAPPED_ROOT" ;; btrfs) mkfs.btrfs -f "$MAPPED_ROOT" ;; xfs) mkfs.xfs -f "$MAPPED_ROOT" ;; *) mkfs.ext4 -F "$MAPPED_ROOT" ;; esac
  else
    safe_mkpart "$TARGET_DISK" "$root_start" "$root_end"
    partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1

    if [[ -b "${TARGET_DISK}p1" ]]; then
      ROOT_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}p[0-9]+" | tail -n1 || true)"
    else
      ROOT_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}[0-9]+" | tail -n1 || true)"
    fi
    [[ -n "$ROOT_PART" && -b "$ROOT_PART" ]] || die "Could not detect root partition device"

    if ! ensure_unmounted "$ROOT_PART"; then
      log "Attempt to unmount $ROOT_PART failed; diagnostics:"
      findmnt -S "$ROOT_PART" || true
      die "Partition $ROOT_PART appears mounted and could not be unmounted"
    fi

    case "$FS_TYPE" in ext4) mkfs.ext4 -F "$ROOT_PART" ;; btrfs) mkfs.btrfs -f "$ROOT_PART" ;; xfs) mkfs.xfs -f "$ROOT_PART" ;; *) mkfs.ext4 -F "$ROOT_PART" ;; esac
    MAPPED_ROOT="$ROOT_PART"
  fi

  # Create /home if requested
  if (( CREATE_HOME == 1 )); then
    if (( LUKS_HOME == 1 )); then
      safe_mkpart "$TARGET_DISK" "$home_start" "$home_end"
      partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1
      if [[ -b "${TARGET_DISK}p1" ]]; then
        HOME_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}p[0-9]+" | tail -n1 || true)"
      else
        HOME_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}[0-9]+" | tail -n1 || true)"
      fi
      [[ -n "$HOME_PART" && -b "$HOME_PART" ]] || die "Could not detect home partition device"
      if ! ensure_unmounted "$HOME_PART"; then
        log "Attempt to unmount $HOME_PART failed; diagnostics:"
        findmnt -S "$HOME_PART" || true
        die "Partition $HOME_PART appears mounted and could not be unmounted"
      fi
      HOME_PASS="${HOME_PASS:-}"
      if [[ -z "$HOME_PASS" ]]; then HOME_PASS="$(gui_password "LUKS Home passphrase" "Enter LUKS passphrase for /home")"; fi
      [[ -n "$HOME_PASS" ]] || die "Empty LUKS passphrase for home"
      printf '%s' "$HOME_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$HOME_PART" -
      printf '%s' "$HOME_PASS" | cryptsetup open "$HOME_PART" "$LUKS_HOME_NAME" --
      MAPPED_HOME="/dev/mapper/${LUKS_HOME_NAME}"
      sleep 1
      case "$FS_TYPE" in ext4) mkfs.ext4 -F "$MAPPED_HOME" ;; btrfs) mkfs.btrfs -f "$MAPPED_HOME" ;; xfs) mkfs.xfs -f "$MAPPED_HOME" ;; esac
    else
      safe_mkpart "$TARGET_DISK" "$home_start" "$home_end"
      partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1
      if [[ -b "${TARGET_DISK}p1" ]]; then
        HOME_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}p[0-9]+" | tail -n1 || true)"
      else
        HOME_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}[0-9]+" | tail -n1 || true)"
      fi
      [[ -n "$HOME_PART" && -b "$HOME_PART" ]] || die "Could not detect home partition device"
      if ! ensure_unmounted "$HOME_PART"; then
        log "Attempt to unmount $HOME_PART failed; diagnostics:"
        findmnt -S "$HOME_PART" || true
        die "Partition $HOME_PART appears mounted and could not be unmounted"
      fi
      case "$FS_TYPE" in ext4) mkfs.ext4 -F "$HOME_PART" ;; btrfs) mkfs.btrfs -f "$HOME_PART" ;; xfs) mkfs.xfs -f "$HOME_PART" ;; esac
      MAPPED_HOME="$HOME_PART"
    fi
  fi

  # Create swap if requested
  if (( swap_mib > 0 )); then
    safe_mkpart "$TARGET_DISK" "$swap_start" "$swap_end"
    partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1
    if [[ -b "${TARGET_DISK}p1" ]]; then
      SWAP_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}p[0-9]+" | tail -n1 || true)"
    else
      SWAP_PART="$(ls -1 "${TARGET_DISK}"* | grep -E "^${TARGET_DISK}[0-9]+" | tail -n1 || true)"
    fi
    [[ -n "$SWAP_PART" ]] || log "Warning: swap partition not detected"
    if [[ -n "$SWAP_PART" ]]; then
      if ! ensure_unmounted "$SWAP_PART"; then
        log "Attempt to unmount $SWAP_PART failed; diagnostics:"
        findmnt -S "$SWAP_PART" || true
        die "Swap partition $SWAP_PART appears mounted and could not be unmounted"
      fi
      mkswap "$SWAP_PART"
    fi
  fi

  partprobe "$TARGET_DISK" || true
  udevadm settle --timeout=10 || true
  sleep 1
  gui_info "$SELECT_PART" "Partitioning complete"
}

step_user_setup() {
  if [[ -z "$USERNAME" ]]; then USERNAME="$(gui_entry "$USER_SETUP" "Choose a username" "user")"; fi
  if [[ -z "$USER_PASS" ]]; then USER_PASS="$(gui_password "$USER_SETUP" "Enter password for $USERNAME")"; fi
  if [[ -z "$ROOT_PASS" ]]; then ROOT_PASS="$(gui_password "Root password" "Enter root password for installed system (or LUKS root passphrase if used)")"; fi
  if [[ -z "$LOCALE" ]]; then LOCALE="$(gui_list "Locale" "Choose locale" "en_US.UTF-8" "pt_BR.UTF-8")"; fi
  if [[ -z "$TIMEZONE" ]]; then TIMEZONE="$(gui_entry "Timezone" "Region/City" "America/Sao_Paulo")"; fi
  if [[ -z "$DESKTOP" ]]; then DESKTOP="$(gui_list "Desktop" "Choose desktop" "none" "i3" "xfce" "mate" "sway")"; fi
  if [[ -z "$FS_TYPE" ]]; then FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" "ext4" "btrfs" "xfs")"; fi
}

step_summary() {
  summary="Disk: $TARGET_DISK
User: ${USERNAME:-user}
Desktop: $DESKTOP
Filesystem: $FS_TYPE
Locale: $LOCALE
Timezone: $TIMEZONE
LUKS root: ${LUKS_ROOT:-0}
LUKS home: ${LUKS_HOME:-0}
Create swap: ${CREATE_SWAP:-0}"
  gui_info "$SUMMARY_TITLE" "$summary"
  if [[ "${AUTO_YES:-0}" -eq 0 ]]; then gui_yesno "$SUMMARY_TITLE" "Proceed with installation?" || die "$ABORT_MSG"; fi
}

discover_parts() {
  partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1
  mapfile -t parts < <(lsblk -ln -o NAME,TYPE | awk -v disk="$(basename "$TARGET_DISK")" '$2=="part" {print "/dev/"$1}')
  EFI_PART="${parts[0]:-}"
  ROOT_PART="${parts[1]:-}"
  HOME_PART="${parts[2]:-}"
  SWAP_PART="${parts[3]:-}"
}

step_install() {
  discover_parts

  if [[ -n "${MAPPED_ROOT:-}" && -b "${MAPPED_ROOT}" ]]; then MROOT="${MAPPED_ROOT}"; else MROOT="${ROOT_PART:-}"; fi
  [[ -n "$MROOT" ]] || die "Root device not found"

  mkdir -p /mnt
  if ! mount -o nosuid,nodev,noatime "$MROOT" /mnt 2>/tmp/mount-root.err; then
    log "Failed to mount root ($MROOT): $(cat /tmp/mount-root.err || true)"
    die "Cannot mount root device $MROOT"
  fi

  if [[ -n "${MAPPED_HOME:-}" && -b "${MAPPED_HOME}" ]]; then
    mkdir -p /mnt/home
    if ! mount -o nosuid,nodev,noatime "$MAPPED_HOME" /mnt/home 2>/tmp/mount-home.err; then
      log "Failed to mount MAPPED_HOME ($MAPPED_HOME): $(cat /tmp/mount-home.err || true)"
      rm -f /tmp/mount-home.err || true
    fi
  elif [[ -n "${HOME_PART:-}" && -b "${HOME_PART}" ]]; then
    mkdir -p /mnt/home
    if ! mount -o nosuid,nodev,noatime "$HOME_PART" /mnt/home 2>/tmp/mount-home.err; then
      log "Failed to mount HOME_PART ($HOME_PART): $(cat /tmp/mount-home.err || true)"
      rm -f /tmp/mount-home.err || true
    fi
  fi

  if [[ -n "${EFI_PART:-}" && -b "${EFI_PART}" ]]; then
    mkdir -p /mnt/boot/efi
    if ! mount -o nosuid,nodev,noatime "$EFI_PART" /mnt/boot/efi 2>/tmp/mount-efi.err; then
      log "Failed to mount EFI_PART ($EFI_PART): $(cat /tmp/mount-efi.err || true)"
      rm -f /tmp/mount-efi.err || true
    fi
  fi

  if [[ -n "${SWAP_PART:-}" && -b "${SWAP_PART}" ]]; then swapon "$SWAP_PART" || true; fi

  huser="$(openssl passwd -6 -- "$USER_PASS" 2>/dev/null || true)"
  hroot_hashed="$(openssl passwd -6 -- "$ROOT_PASS" 2>/dev/null || true)"

  mkdir -p /mnt/etc
  cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (guix) (guix profiles) (gnu services) (gnu packages base) (gnu packages linux) (gnu services desktop))

(operating-system
 (host-name "${HOSTNAME}")
 (timezone "${TIMEZONE}")
 (locale "${LOCALE}")
 (keyboard-layout (keyboard-layout "${KEYBOARD}")))
EOF

  if [[ -n "${EFI_PART:-}" ]]; then
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

  if [[ -n "${MAPPED_ROOT:-}" && -b "${MAPPED_ROOT}" ]]; then root_dev="${MAPPED_ROOT}"; else root_dev="${MROOT}"; fi
  root_uuid="$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)"
  if [[ -n "$root_uuid" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${root_uuid}")) (mount-point "/") (type "${FS_TYPE}"))
EOF
  else
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${root_dev}") (mount-point "/") (type "${FS_TYPE}"))
EOF
  fi

  if [[ -n "${MAPPED_HOME:-}" && -b "${MAPPED_HOME}" ]]; then
    home_dev="${MAPPED_HOME}"
    home_uuid="$(blkid -s UUID -o value "$home_dev" 2>/dev/null || true)"
    if [[ -n "$home_uuid" ]]; then
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${home_uuid}")) (mount-point "/home") (type "${FS_TYPE}"))
EOF
    else
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${home_dev}") (mount-point "/home") (type "${FS_TYPE}"))
EOF
    fi
  elif [[ -n "${HOME_PART:-}" && -b "${HOME_PART}" ]]; then
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

  if [[ -n "${EFI_PART:-}" && -b "${EFI_PART}" ]]; then
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

  if [[ -n "${SWAP_PART:-}" && -b "${SWAP_PART}" ]]; then
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

  # write channels.scm exactly as requested by user
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

  gui_info "Guix" "$GUIX_BOOTSTRAP_MSG"

  if ensure_guix_daemon; then
    subs="$(probe_substitutes)"
    if [[ -n "$subs" ]]; then
      export GUIX_SUBSTITUTE_URLS="$subs"
      write_guix_substitute_config >/dev/null 2>&1 || true
    fi

    if ! robust_guix_init; then
      log "guix system init failed after fallbacks. Configuration left at /mnt/etc for manual init."
      gui_info "$FINISH_MSG" "guix system init failed after retries. Configuration in /mnt/etc; run 'guix system init' manually when ready."
    else
      gui_info "$FINISH_MSG" "guix system init completed successfully"
    fi
  else
    log "Could not ensure Guix CLI/daemon. Configuration written to /mnt/etc"
    gui_info "$FINISH_MSG" "Could not start Guix daemon. Configuration is at /mnt/etc."
  fi

  # cleanup: use safe_swapoff to avoid invalid-argument errors
  sync
  if [[ -n "${SWAP_PART:-}" ]]; then
    safe_swapoff "$SWAP_PART" || true
  else
    if [ -s /proc/swaps ]; then
      log "No SWAP_PART variable set but swaps are active; disabling all swaps"
      swapoff -a || true
    fi
  fi

  # unmount earlier mountpoints if present
  umount /mnt/home 2>/dev/null || true
  umount /mnt/boot/efi 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  if (( LUKS_HOME == 1 )) && cryptsetup status "$LUKS_HOME_NAME" >/dev/null 2>&1; then cryptsetup close "$LUKS_HOME_NAME" || true; fi
  if (( LUKS_ROOT == 1 )) && cryptsetup status "$LUKS_ROOT_NAME" >/dev/null 2>&1; then cryptsetup close "$LUKS_ROOT_NAME" || true; fi

  log "Installation finished (best-effort). Configuration and files are on the target filesystem. Please reboot manually when ready."
}

# -------------------- Main --------------------
main() {
  detect_gui
  if [[ "$(id -u)" -ne 0 ]]; then die "Run this script as root"; fi
  step_welcome
  step_select_disk
  step_partition_options
  step_user_setup
  step_summary
  step_install
}

main "$@"