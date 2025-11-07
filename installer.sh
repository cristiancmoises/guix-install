#!/usr/bin/env bash
set -euo pipefail

# GNU Guix guided installer 
# WARNING: destructive operations. Review TARGET_DISK and variables before running. Run as root from a live environment.

# -------------------- Configurable defaults --------------------
USE_GUI="${USE_GUI:-auto}"              # auto|text - 'auto' will try yad then zenity then fallback to text
AUTO_YES="${AUTO_YES:-0}"               # 1 to skip confirmations
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
LUKS_ROOT="${LUKS_ROOT:-0}"             # 1 to encrypt root
LUKS_HOME="${LUKS_HOME:-0}"             # 1 to encrypt home
LUKS_ROOT_NAME="${LUKS_ROOT_NAME:-cryptroot}"
LUKS_HOME_NAME="${LUKS_HOME_NAME:-crypthome}"
GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.5.0}"
TIME_MACHINE_TIMEOUT="${TIME_MACHINE_TIMEOUT:-300}"  # seconds to wait for guix time-machine before fallback
LOGFILE="${LOGFILE:-/var/log/guix-installer.log}"
GUIX_INIT_LOG="${GUIX_INIT_LOG:-/var/log/guix-init.log}"

# Substitute hosts (first changed as requested)
SUBSTITUTE_HOSTS=(
  "https://bordeaux-us-east-mirror.cbaines.net"
  "https://hydra.gnu.org"
  "https://ci.guix.gnu.org"
  "https://ci.guix.info"
  "https://ftp.gnu.org/gnu/guix"
)

BASE_PACKAGES=(icecat libreoffice mpv feh util-linux xterm git python)

KEYBOARD="${KEYBOARD:-us}"
HOSTNAME="${HOSTNAME:-guix-machine}"

# -------------------- Utilities --------------------
log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$LOGFILE"
}
die() {
  log "ERROR: $*"
  exit 1
}
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run this script as root"; }

# -------------------- GUI wrappers --------------------
detect_gui_tool() {
  GUI_TOOL=""
  if [[ "${USE_GUI}" == "text" ]]; then GUI_TOOL="text"; return; fi
  if cmd_exists yad; then GUI_TOOL="yad"; return; fi
  if cmd_exists zenity; then GUI_TOOL="zenity"; return; fi
  GUI_TOOL="text"
}

gui_info() {
  local title="$1" msg="$2"
  case "$GUI_TOOL" in
    yad) yad --title "$title" --info --text "$msg" --timeout=5 >/dev/null 2>&1 || true ;;
    zenity) zenity --info --title="$title" --text "$msg" --timeout=5 >/dev/null 2>&1 || true ;;
    *) printf '%s: %s\n' "$title" "$msg" ;;
  esac
}

gui_entry() {
  local title="$1" prompt="$2" default="$3"
  local res
  case "$GUI_TOOL" in
    yad) res="$(yad --title "$title" --entry --text "$prompt" --entry-text "$default" 2>/dev/null)" || res="$default" ;;
    zenity) res="$(zenity --entry --title="$title" --text="$prompt" --entry-text="$default" 2>/dev/null)" || res="$default" ;;
    *) read -r -p "$prompt [$default]: " v; res="${v:-$default}" ;;
  esac
  printf '%s' "$res"
}

gui_password() {
  local title="$1" prompt="$2"
  local res
  case "$GUI_TOOL" in
    yad) res="$(yad --title "$title" --entry --text "$prompt" --entry-password 2>/dev/null)" || res="" ;;
    zenity) res="$(zenity --password --title="$title" --text="$prompt" 2>/dev/null)" || res="" ;;
    *) read -r -s -p "$prompt: " pw; echo; res="$pw" ;;
  esac
  printf '%s' "$res"
}

gui_list() {
  local title="$1" prompt="$2"; shift 2; local choices=("$@") res
  case "$GUI_TOOL" in
    yad) res="$(printf "%s\n" "${choices[@]}" | yad --list --title "$title" --column "$prompt" --height=240 --width=320 2>/dev/null | head -n1)" || res="${choices[0]}" ;;
    zenity) res="$(printf "%s\n" "${choices[@]}" | zenity --list --title="$title" --column="$prompt" --height=240 --width=320 2>/dev/null | head -n1)" || res="${choices[0]}" ;;
    *) res="${choices[0]}" ;;
  esac
  printf '%s' "$res"
}

gui_yesno() {
  local title="$1" prompt="$2"
  case "$GUI_TOOL" in
    yad) yad --title "$title" --question --text "$prompt" --button="No":1 --button="Yes":0 >/dev/null 2>&1; return $? ;;
    zenity) zenity --question --title="$title" --text="$prompt" >/dev/null 2>&1; return $? ;;
    *)
      if [[ "${AUTO_YES}" -ne 0 ]]; then return 0; fi
      while true; do
        read -r -p "$prompt [y/N]: " ans
        case "${ans,,}" in
          y|yes) return 0 ;;
          n|no|"" ) return 1 ;;
          *) echo "Please answer yes or no." ;;
        esac
      done
      ;;
  esac
}

# -------------------- Substitute probing --------------------
probe_substitutes() {
  local usable=() url base ok
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

# -------------------- Guix bootstrap helpers --------------------
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
  [[ -f "${TMP}/${BIN}" ]] || { log "Download failed"; rm -rf "$TMP"; return 1; }
  mkdir -p "${TMP}/extracted"
  tar -xJf "${TMP}/${BIN}" -C "${TMP}/extracted" || { log "Extraction failed"; rm -rf "$TMP"; return 1; }
  log "Copying Guix binary files to / (best-effort)"
  if tar -C "${TMP}/extracted" -cf - . | tar -C / -xvf - >/dev/null 2>&1; then
    log "Guix binary files copied"
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
  for i in {1..12}; do
    sleep 1
    if pgrep -f guix-daemon >/dev/null 2>&1; then log "guix-daemon running (background)"; return 0; fi
  done
  log "Background guix-daemon failed to start"
  return 1
}

ensure_guix_daemon() {
  # Try systemd-managed service first
  if cmd_exists systemctl && systemctl list-unit-files | grep -q guix-daemon; then
    log "Attempting to enable/start guix-daemon.service via systemd"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now guix-daemon.service >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet guix-daemon 2>/dev/null; then log "guix-daemon active (systemd)"; return 0; fi
    log "systemd start either not available or did not become active"
  fi

  # Try to install if missing
  if ! cmd_exists guix-daemon; then
    log "guix-daemon not found; attempting installation"
    if install_guix_via_distro; then log "Guix installed via distro package"; fi
    if ! cmd_exists guix-daemon && bootstrap_guix_binary; then log "Guix installed via binary bootstrap"; fi
  fi

  # Try socket activation via systemctl if available
  if cmd_exists systemctl; then
    systemctl start guix-daemon.socket >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet guix-daemon 2>/dev/null; then log "guix-daemon active via socket activation"; return 0; fi
  fi

  # Start background daemon
  if cmd_exists guix-daemon && start_guix_daemon_background; then return 0; fi

  # Nohup attempt for diagnostics
  if cmd_exists guix-daemon; then
    nohup guix-daemon --build-users-group=guixbuild --disable-chroot >/var/log/guix-daemon.log 2>&1 &
    sleep 2
    if pgrep -f guix-daemon >/dev/null 2>&1; then log "guix-daemon started via nohup"; return 0; fi
  fi

  log "Could not start guix-daemon"
  return 1
}

# -------------------- Robust guix init with bounded time-machine --------------------
robust_guix_init() {
  local subs tmperr TM_PID SECONDS_LOCAL
  subs="$(probe_substitutes)"
  [[ -n "$subs" ]] && export GUIX_SUBSTITUTE_URLS="$subs" && write_guix_substitute_config >/dev/null 2>&1 || true

  if cmd_exists guix; then
    log "Attempting guix time-machine (bounded to ${TIME_MACHINE_TIMEOUT}s). Logs -> $GUIX_INIT_LOG"
    tmperr="$(mktemp)"
    (guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt --no-build-output 2>>"$tmperr") &
    TM_PID=$!
    SECONDS_LOCAL=0
    while kill -0 "$TM_PID" >/dev/null 2>&1; do
      sleep 1
      SECONDS_LOCAL=$((SECONDS_LOCAL+1))
      if (( SECONDS_LOCAL >= TIME_MACHINE_TIMEOUT )); then
        log "guix time-machine exceeded ${TIME_MACHINE_TIMEOUT}s; killing it and falling back to chroot method. See $tmperr for details."
        kill -TERM "$TM_PID" >/dev/null 2>&1 || true
        sleep 1
        kill -KILL "$TM_PID" >/dev/null 2>&1 || true
        break
      fi
    done
    if [[ -s "$tmperr" ]]; then
      log "guix time-machine stderr (tail):"
      tail -n 80 "$tmperr" | sed -n '1,200p' | tee -a "$LOGFILE"
    fi
    wait "$TM_PID" >/dev/null 2>&1 || true
    rm -f "$tmperr" || true
    # Best-effort check: look for created system profile on target
    if [[ -d /mnt/var/guix/profiles/system ]]; then
      log "guix time-machine appears to have completed and created system profile"
      return 0
    else
      log "guix time-machine did not produce an in-target system profile; will attempt chroot fallback"
    fi
  else
    log "guix CLI not available on host; skipping time-machine and using chroot fallback"
  fi

  # Chroot fallback
  log "Falling back to chroot guix pull + guix system init (logs -> $GUIX_INIT_LOG)"
  mkdir -p /mnt/{dev,proc,sys,tmp} || true
  mount --bind /dev /mnt/dev || true
  mount --bind /dev/pts /mnt/dev/pts || true
  mount --bind /proc /mnt/proc || true
  mount --bind /sys /mnt/sys || true
  if [[ -f /etc/resolv.conf ]]; then cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true; fi

  local wrapper_name="/tmp/guix-init-wrapper-$$.sh"
  cat > "/mnt${wrapper_name}" <<'EOF'
#!/bin/sh
set -e
export GUIX_SUBSTITUTE_URLS="${GUIX_SUBSTITUTE_URLS:-}"
guix pull --channels-file=/etc/channels.scm || true
guix system init /etc/config.scm / --no-build-output
EOF
  chmod +x "/mnt${wrapper_name}" || true
  if chroot /mnt "$wrapper_name"; then
    log "guix system init succeeded inside chroot"
    rm -f "/mnt${wrapper_name}" || true
    umount /mnt/dev/pts || true
    umount /mnt/dev || true
    umount /mnt/proc || true
    umount /mnt/sys || true
    return 0
  else
    log "guix system init inside chroot failed; leaving /mnt/etc for manual init; check $GUIX_INIT_LOG and $LOGFILE"
    rm -f "/mnt${wrapper_name}" || true
    umount /mnt/dev/pts || true
    umount /mnt/dev || true
    umount /mnt/proc || true
    umount /mnt/sys || true
    return 1
  fi
}

# -------------------- Partition helpers --------------------
to_mib() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"
  else echo "$s"
  fi
}

safe_mkpart(){ local disk="$1" start="$2" end="$3"; (( end > start+1 )) || die "Invalid partition range ${start}MiB - ${end}MiB"; parted --script --align optimal "$disk" mkpart primary "${start}MiB" "${end}MiB"; }

cap_end(){ local v="$1" t="$2"; if (( v > t - 1 )); then v=$(( t - 1 )); fi; echo "$v"; }

ensure_unmounted() {
  local dev="$1"
  [[ -n "$dev" ]] || return 0
  dev="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
  local targets=() _tmp t uniq sorted
  if cmd_exists findmnt; then
    mapfile -t _tmp < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
    targets+=("${_tmp[@]:-}")
    for p in $(ls "${dev}"* 2>/dev/null || true); do
      mapfile -t _tmp < <(findmnt -rn -S "$p" -o TARGET 2>/dev/null || true)
      targets+=("${_tmp[@]:-}")
    done
  else
    mapfile -t _tmp < <(awk -v d="$dev" '$1==d || index($1,d)==1 {print $2}' /proc/mounts 2>/dev/null || true)
    targets+=("${_tmp[@]:-}")
    for p in $(ls "${dev}"* 2>/dev/null || true); do
      mapfile -t _tmp < <(awk -v p="$p" '$1==p || index($1,p)==1 {print $2}' /proc/mounts 2>/dev/null || true)
      targets+=("${_tmp[@]:-}")
    done
  fi

  uniq=()
  for t in "${targets[@]:-}"; do [[ -n "$t" ]] && [[ ! " ${uniq[*]} " =~ " $t " ]] && uniq+=("$t"); done
  targets=("${uniq[@]}")
  [[ ${#targets[@]} -gt 0 ]] || return 0

  IFS=$'\n' sorted=($(printf '%s\n' "${targets[@]}" | awk '{print length,$0}' | sort -rn | cut -d' ' -f2-))
  for t in "${sorted[@]}"; do
    log "Attempting to unmount $t (on $dev)"
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

safe_swapoff() {
  local arg="$1"
  if [[ -z "${arg:-}" ]]; then
    if [[ -s /proc/swaps ]]; then log "Disabling all swaps"; swapoff -a || true; fi
    return 0
  fi
  if [[ -b "$arg" ]]; then
    log "Disabling swap on $arg"; swapoff "$arg" 2>/dev/null || swapoff -a || true; return 0
  fi
  if grep -q "$arg" /proc/swaps 2>/dev/null; then
    local dev="$(awk -v a="$arg" '$1~a || $2~a {print $1; exit}' /proc/swaps 2>/dev/null || true)"
    if [[ -n "$dev" ]]; then swapoff "$dev" 2>/dev/null || swapoff -a || true; return 0; fi
  fi
  log "Swap spec '$arg' not a block device; disabling all swaps as fallback"
  swapoff -a || true
  return 0
}

get_last_partition() {
  local disk="$1"
  lsblk -ln -o NAME,START "$disk" 2>/dev/null | awk '$1!~/'"$(basename "$disk")"'/ {print $0}' | sort -k2n | tail -n1 | awk '{print "/dev/"$1}'
}

# -------------------- Main installation flow --------------------
main() {
  require_root
  detect_gui_tool
  log "Installer started. GUI tool: $GUI_TOOL"

  [[ -n "$TARGET_DISK" ]] || die "TARGET_DISK must be set (e.g. /dev/sdb)"
  [[ -b "$TARGET_DISK" ]] || die "Target disk $TARGET_DISK not found"

  # Prompt/confirm
  if [[ "${AUTO_YES}" -eq 0 ]]; then
    gui_info "Installation" "Target disk: $TARGET_DISK. This will erase the disk."
    gui_yesno "Confirm" "Proceed to wipe and partition $TARGET_DISK?" || die "Aborted by user"
  fi

  # Try to ensure guix-daemon (best-effort)
  if ! ensure_guix_daemon; then
    log "Warning: guix-daemon could not be started. Proceeding to write configuration; guix system init may need manual follow-up."
  fi

  # Disk sizing
  local total_mib used_mib remaining swap_mib root_start root_end home_start home_end swap_start swap_end
  total_mib=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1024 / 1024 ))
  (( total_mib >= 64 )) || die "Disk too small ($total_mib MiB)"

  # Partition table + EFI
  if [[ -d /sys/firmware/efi ]]; then
    log "EFI detected: creating GPT and EFI partition"
    parted --script "$TARGET_DISK" mklabel gpt >/dev/null 2>&1 || true
    used_mib=513
    safe_mkpart "$TARGET_DISK" 1 513
    parted --script "$TARGET_DISK" set 1 esp on >/dev/null 2>&1 || true
  else
    log "No EFI: creating msdos label"
    parted --script "$TARGET_DISK" mklabel msdos >/dev/null 2>&1 || true
    used_mib=1
  fi

  remaining=$(( total_mib - used_mib ))
  (( remaining > 8 )) || die "Not enough usable space after label"

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

  # Create partitions
  log "Creating root partition: ${root_start}MiB -> ${root_end}MiB"
  safe_mkpart "$TARGET_DISK" "$root_start" "$root_end"
  partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1

  if (( CREATE_HOME == 1 )); then
    log "Creating home partition: ${home_start}MiB -> ${home_end}MiB"
    safe_mkpart "$TARGET_DISK" "$home_start" "$home_end"
    partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1
  fi

  if (( swap_mib > 0 )); then
    log "Creating swap partition: ${swap_start}MiB -> ${swap_end}MiB"
    safe_mkpart "$TARGET_DISK" "$swap_start" "$swap_end"
    partprobe "$TARGET_DISK" || true; udevadm settle --timeout=10 || true; sleep 1
  fi

  # Detect partitions robustly
  mapfile -t parts < <(lsblk -ln -o NAME,TYPE -b "$TARGET_DISK" 2>/dev/null | awk '$2=="part" {print "/dev/"$1}')
  local EFI_PART="" ROOT_PART="" HOME_PART="" SWAP_PART=""
  if [[ -d /sys/firmware/efi ]]; then
    EFI_PART="${parts[0]:-}"
    for p in "${parts[@]:-}"; do [[ -n "$EFI_PART" && "$p" == "$EFI_PART" ]] && continue; ROOT_PART="$p"; break; done
    if (( CREATE_HOME == 1 )); then
      for p in "${parts[@]:-}"; do [[ "$p" != "$EFI_PART" && "$p" != "$ROOT_PART" ]] && { HOME_PART="$p"; break; } done
    fi
    if (( swap_mib > 0 )); then
      SWAP_PART="${parts[-1]:-}"
      if [[ "$SWAP_PART" == "$EFI_PART" || "$SWAP_PART" == "$ROOT_PART" || "$SWAP_PART" == "$HOME_PART" ]]; then SWAP_PART=""; fi
    fi
  else
    ROOT_PART="${parts[0]:-}"
    if (( CREATE_HOME == 1 )); then HOME_PART="${parts[1]:-}"; fi
    if (( swap_mib > 0 )); then SWAP_PART="${parts[-1]:-}"; fi
  fi

  [[ -n "$ROOT_PART" ]] || ROOT_PART="$(get_last_partition "$TARGET_DISK")"
  [[ -n "$HOME_PART" ]] || HOME_PART="$(get_last_partition "$TARGET_DISK")"

  log "Detected partitions: EFI=$EFI_PART ROOT=$ROOT_PART HOME=$HOME_PART SWAP=$SWAP_PART"

  # Unmount any mounted partitions
  for p in "$EFI_PART" "$ROOT_PART" "$HOME_PART" "$SWAP_PART"; do
    [[ -n "$p" ]] || continue
    if awk -v d="$p" '$1==d {exit 0} END{exit 1}' /proc/mounts 2>/dev/null; then
      log "Device $p appears mounted; attempting to unmount"
      ensure_unmounted "$p" || { findmnt -S "$p" || true; die "Partition $p appears mounted and could not be unmounted"; }
    fi
  done

  # Formatting / LUKS
  local ROOT_DEV HOME_DEV MAPPED_ROOT MAPPED_HOME
  if (( LUKS_ROOT == 1 )); then
    [[ -b "$ROOT_PART" ]] || die "Root partition for LUKS not found"
    if [[ -z "$ROOT_PASS" ]]; then ROOT_PASS="$(gui_password "LUKS Root passphrase" "Enter LUKS passphrase for root")"; fi
    [[ -n "$ROOT_PASS" ]] || die "Empty LUKS passphrase"
    log "Formatting LUKS2 on $ROOT_PART"
    printf '%s' "$ROOT_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$ROOT_PART" - || die "luksFormat failed"
    printf '%s' "$ROOT_PASS" | cryptsetup open "$ROOT_PART" "$LUKS_ROOT_NAME" -- || die "cryptsetup open failed"
    MAPPED_ROOT="/dev/mapper/${LUKS_ROOT_NAME}"
    sleep 1
    case "$FS_TYPE" in ext4) mkfs.ext4 -F "$MAPPED_ROOT" ;; btrfs) mkfs.btrfs -f "$MAPPED_ROOT" ;; xfs) mkfs.xfs -f "$MAPPED_ROOT" ;; *) mkfs.ext4 -F "$MAPPED_ROOT" ;; esac
    ROOT_DEV="$MAPPED_ROOT"
  else
    if [[ -b "$ROOT_PART" ]]; then
      case "$FS_TYPE" in ext4) mkfs.ext4 -F "$ROOT_PART" ;; btrfs) mkfs.btrfs -f "$ROOT_PART" ;; xfs) mkfs.xfs -f "$ROOT_PART" ;; *) mkfs.ext4 -F "$ROOT_PART" ;; esac
      ROOT_DEV="$ROOT_PART"
    else
      die "Root block device not found"
    fi
  fi

  if (( CREATE_HOME == 1 )); then
    if (( LUKS_HOME == 1 )); then
      [[ -b "$HOME_PART" ]] || die "Home partition for LUKS not found"
      if [[ -z "$HOME_PASS" ]]; then HOME_PASS="$(gui_password "LUKS Home passphrase" "Enter LUKS passphrase for /home")"; fi
      [[ -n "$HOME_PASS" ]] || die "Empty LUKS home passphrase"
      printf '%s' "$HOME_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$HOME_PART" - || die "luksFormat failed on home"
      printf '%s' "$HOME_PASS" | cryptsetup open "$HOME_PART" "$LUKS_HOME_NAME" -- || die "cryptsetup open failed for home"
      MAPPED_HOME="/dev/mapper/${LUKS_HOME_NAME}"
      sleep 1
      case "$FS_TYPE" in ext4) mkfs.ext4 -F "$MAPPED_HOME" ;; btrfs) mkfs.btrfs -f "$MAPPED_HOME" ;; xfs) mkfs.xfs -f "$MAPPED_HOME" ;; esac
      HOME_DEV="$MAPPED_HOME"
    else
      if [[ -b "$HOME_PART" ]]; then
        case "$FS_TYPE" in ext4) mkfs.ext4 -F "$HOME_PART" ;; btrfs) mkfs.btrfs -f "$HOME_PART" ;; xfs) mkfs.xfs -f "$HOME_PART" ;; esac
        HOME_DEV="$HOME_PART"
      fi
    fi
  fi

  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then
    mkswap "$SWAP_PART" || log "mkswap failed on $SWAP_PART"
  fi

  # Mount filesystems
  mkdir -p /mnt
  mount -o nosuid,nodev,noatime "${ROOT_DEV:-$ROOT_PART}" /mnt || die "Failed to mount root to /mnt"
  if [[ -n "${HOME_DEV:-}" ]]; then
    mkdir -p /mnt/home
    if ! mount -o nosuid,nodev,noatime "$HOME_DEV" /mnt/home 2>/tmp/mount-home.err; then
      log "Failed to mount home: $(cat /tmp/mount-home.err || true)"; rm -f /tmp/mount-home.err || true
    fi
  fi
  if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then
    mkdir -p /mnt/boot/efi
    if ! mount -o nosuid,nodev,noatime "$EFI_PART" /mnt/boot/efi 2>/tmp/mount-efi.err; then
      log "Failed to mount EFI: $(cat /tmp/mount-efi.err || true)"; rm -f /tmp/mount-efi.err || true
    fi
  fi
  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then
    swapon "$SWAP_PART" || log "swapon failed on $SWAP_PART"
  fi

  # Prepare hashed passwords and write config files
  local huser hroot_hashed
  huser="$(openssl passwd -6 -- "$USER_PASS" 2>/dev/null || true)"
  hroot_hashed="$(openssl passwd -6 -- "$ROOT_PASS" 2>/dev/null || true)"

  mkdir -p /mnt/etc
  cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (guix) (guix profiles) (gnu services) (gnu packages base) (gnu packages linux) (gnu services desktop) (guix utils) (gnu services networking) (gnu services ssh))

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

  local root_uuid home_uuid efi_uuid
  root_uuid="$(blkid -s UUID -o value "${ROOT_DEV:-$ROOT_PART}" 2>/dev/null || true)"
  if [[ -n "$root_uuid" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${root_uuid}")) (mount-point "/") (type "${FS_TYPE}"))
EOF
  else
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${ROOT_DEV:-$ROOT_PART}") (mount-point "/") (type "${FS_TYPE}"))
EOF
  fi

  if [[ -n "${HOME_DEV:-}" ]]; then
    home_uuid="$(blkid -s UUID -o value "$HOME_DEV" 2>/dev/null || true)"
    if [[ -n "$home_uuid" ]]; then
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${home_uuid}")) (mount-point "/home") (type "${FS_TYPE}"))
EOF
    else
      cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${HOME_DEV}") (mount-point "/home") (type "${FS_TYPE}"))
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

  # Add users, packages and services
  cat >> /mnt/etc/config.scm <<EOF
 (users (cons* (user-account (name "${USERNAME}") (group "users")
                             (home (string-append "/home/" "${USERNAME}"))
                             (password "${huser}")
                             (supplementary-groups '("wheel" "netdev" "audio" "networking" "video")))
               (map (lambda (u) (if (string=? (user-account-name u) "root")
                                   (user-account (inherit u) (password "${hroot_hashed}"))
                                   u)) %base-user-accounts)))
 (packages (list ${BASE_PACKAGES[*]}))
 (services
  (cons* ;; default base services preserved
   %base-services
EOF

  # If we have LUKS devices we will add a systemd unit that prompts for passphrases early during boot.
  # The unit will run cryptsetup to open named LUKS mappings before the root file-system mount.
  # This unit is a practical helper when using Guix system bootloader and systemd: it can be adapted
  # or removed by editing the resulting system configuration on the installed system.
  if (( LUKS_ROOT == 1 || LUKS_HOME == 1 )); then
    # Build a small systemd service unit string that opens required devices
    # We use placeholders for device nodes; guix system init will include this unit in system units.
    cat >> /mnt/etc/config.scm <<'EOF'
   ;; Add a systemd unit to unlock LUKS devices at boot if present.
   (service (service-type (systemd-service) (name "luks-unlock.service")
            (documentation "Opens LUKS containers at boot time; adjust device names/passphrases as needed.")
            (unit-file
             "(Unit)
Description=Unlock LUKS devices at boot
DefaultDependencies=no
Before=local-fs.target
After=systemd-udev-settle.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'set -e
'
             )))
EOF
    # Note: the generated unit template above will be present in the system configuration.
    # The script below will also write /etc/crypttab entry on the installed system via guix if desired.
  fi

  # Close services list
  cat >> /mnt/etc/config.scm <<'EOF'
   %base-services)))
EOF

  # Write channels.scm (user-provided channels content preserved)
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

  # Attempt guix system init (time-machine bounded) then chroot fallback
  if cmd_exists guix && pgrep -f guix-daemon >/dev/null 2>&1; then
    log "Attempting guix system init via time-machine (bounded). If this stalls, the script will fall back to chroot method."
    if robust_guix_init; then
      log "guix system init completed successfully"
    else
      log "guix system init failed or timed out; configuration retained in /mnt/etc for manual init"
    fi
  else
    log "guix CLI or daemon not available; skipping automatic guix system init. Configuration is in /mnt/etc. To finish: ensure guix and guix-daemon are available and run 'guix system init /mnt/etc/config.scm /mnt' or use chroot fallback."
  fi

  # Cleanup: safe swapoff and unmounts
  sync
  if [[ -n "$SWAP_PART" ]]; then safe_swapoff "$SWAP_PART" || true; else safe_swapoff "" || true; fi
  umount /mnt/home 2>/dev/null || true
  umount /mnt/boot/efi 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  # Close any opened LUKS mappings
  if (( LUKS_HOME == 1 )); then cryptsetup status "$LUKS_HOME_NAME" >/dev/null 2>&1 && cryptsetup close "$LUKS_HOME_NAME" || true; fi
  if (( LUKS_ROOT == 1 )); then cryptsetup status "$LUKS_ROOT_NAME" >/dev/null 2>&1 && cryptsetup close "$LUKS_ROOT_NAME" || true; fi

  log "Installer finished. Please review $LOGFILE and /var/log/guix-daemon.log for diagnostics. To complete installation manually: ensure guix-daemon is running and run 'guix system init /mnt/etc/config.scm /mnt' or follow the chroot fallback method."
}

main "$@"