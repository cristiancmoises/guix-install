# In Code We Trust
#!/usr/bin/env bash
set -euo pipefail

# Calamares-like GNU Guix installer 
# - Step-based guided installer with yad/zenity fallback to text prompts
# - Guided partitioning (EFI + root [+ home] [+ swap])
# - Writes /mnt/etc/config.scm and channels.scm

# -------------------- Safe defaults / environment --------------------
LANG_OPT="${LANG_OPT:-auto}"
USE_GUI="${USE_GUI:-auto}"          # auto | gui | text
AUTO_YES="${AUTO_YES:-0}"           # 1 to skip interactive confirmations
TARGET_DISK="${TARGET_DISK:-}"      # e.g., /dev/sda
USERNAME="${USERNAME:-}"            # user name
USER_PASS="${USER_PASS:-}"          # user password (plaintext; script-only)
ROOT_PASS="${ROOT_PASS:-}"          # root password
LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
DESKTOP="${DESKTOP:-none}"          # i3,mate,xfce,sway,none
FS_TYPE="${FS_TYPE:-ext4}"          # ext4,btrfs,xfs
CREATE_HOME="${CREATE_HOME:-}"      # 1=yes 0=no
CREATE_SWAP="${CREATE_SWAP:-}"      # 1=yes 0=no
SWAP_SIZE="${SWAP_SIZE:-4G}"
GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.5.0}"
KEYBOARD="${KEYBOARD:-us}"

SUBSTITUTE_HOSTS=( "https://hydra.gnu.org" "https://cache.guix.gnu.org" "https://ci.guix.info" "https://ci.guix.gnu.org" )
BASE_PACKAGES=(icecat libreoffice mpv feh util-linux xterm git python)

# -------------------- Localization --------------------
choose_lang() {
  if [[ "$LANG_OPT" == "auto" ]]; then
    _term="${LC_ALL:-${LANG:-}}"
    if [[ "$_term" =~ ^pt|BR|br ]]; then LANG_OPT="pt"; else LANG_OPT="en"; fi
  fi

  if [[ "$LANG_OPT" == "pt" ]]; then
    L_WELCOME="Bem-vindo ao instalador GNU Guix"
    L_WELCOME_SUB="Instalação guiada"
    L_SELECT_DISK="Selecione o disco alvo"
    L_SELECT_PART="Gerenciar partições (simples)"
    L_USER_SETUP="Configurar usuário e senha"
    L_SUMMARY="Resumo"
    L_INSTALL="Instalando — aguarde"
    L_FINISH="Instalação concluída"
    L_ABORT_MSG="Abortado pelo usuário"
    L_CONFIRM_PHRASE="SIM EU QUERO GUIX"
    L_OK="OK"
    L_CANCEL="Cancelar"
    L_PLEASE="Por favor responda sim/não"
    L_GUIX_BOOTSTRAP="Tentando instalar Guix (pacote ou binário)"
  else
    L_WELCOME="Welcome to the GNU Guix installer"
    L_WELCOME_SUB="Guided installation"
    L_SELECT_DISK="Select target disk"
    L_SELECT_PART="Manage partitions (simple)"
    L_USER_SETUP="Set up user and passwords"
    L_SUMMARY="Summary"
    L_INSTALL="Installing — please wait"
    L_FINISH="Installation finished"
    L_ABORT_MSG="Aborted by user"
    L_CONFIRM_PHRASE="YES I WANT GUIX"
    L_OK="OK"
    L_CANCEL="Cancel"
    L_PLEASE="Please answer yes/no"
    L_GUIX_BOOTSTRAP="Attempting to install Guix (distro package or binary)"
  fi
}

# -------------------- Helpers --------------------
log() { printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# detect package manager early
PKG=""
if command -v apt >/dev/null 2>&1; then PKG="apt"
elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
elif command -v pacman >/dev/null 2>&1; then PKG="pacman"
fi

# -------------------- GUI detection and wrappers --------------------
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
    if [[ "$GUI_TOOL" == "yad" ]]; then
      yad --title "$title" --info --text "$msg" --timeout=3 >/dev/null 2>&1 || true
    else
      zenity --info --title="$title" --text "$msg" --timeout=3 >/dev/null 2>&1 || true
    fi
  else
    echo "$title: $msg"
  fi
}

gui_entry() {
  local title="$1" prompt="$2" default="$3"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then
      yad --title "$title" --entry --text "$prompt" --entry-text "$default" 2>/dev/null || echo "$default"
    else
      zenity --entry --title="$title" --text="$prompt" --entry-text "$default" 2>/dev/null || echo "$default"
    fi
  else
    if [[ "${AUTO_YES:-0}" -eq 1 ]]; then
      echo "$default"
    else
      read -r -p "$prompt [$default]: " val
      echo "${val:-$default}"
    fi
  fi
}

gui_list() {
  local title="$1" prompt="$2"; shift 2; local choices=("$@")
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then
      printf "%s\n" "${choices[@]}" | yad --list --title "$title" --column "$prompt" --height=240 --width=320 2>/dev/null | head -n1
    else
      printf "%s\n" "${choices[@]}" | zenity --list --title="$title" --column="$prompt" --height=240 --width=320 2>/dev/null | head -n1
    fi
  else
    # return first choice as fallback
    echo "${choices[0]}"
  fi
}

gui_yesno() {
  local title="$1" prompt="$2"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then
      yad --title "$title" --question --text "$prompt" --button="$L_CANCEL":1 --button="$L_OK":0 >/dev/null 2>&1
      return $?
    else
      zenity --question --title="$title" --text="$prompt" >/dev/null 2>&1
      return $?
    fi
  fi

  if [[ "${AUTO_YES:-0}" -eq 1 ]]; then
    return 0
  fi
  while true; do
    read -r -p "$prompt [y/N]: " ans
    case "$ans" in
      [YySs]* ) return 0 ;;
      [Nn]* ) return 1 ;;
      * ) echo "$L_PLEASE" ;;
    esac
  done
}

# -------------------- Guix helpers (bootstrap & daemon) --------------------
install_guix_via_distro() {
  if [[ -z "$PKG" ]]; then return 1; fi
  log "Trying to install guix via package manager ($PKG)"
  case "$PKG" in
    apt)
      apt update -y >/dev/null 2>&1 || true
      apt install -y guix >/dev/null 2>&1 || return 1
      ;;
    dnf)
      dnf install -y guix >/dev/null 2>&1 || return 1
      ;;
    pacman)
      pacman -Sy --noconfirm guix >/dev/null 2>&1 || return 1
      ;;
    *)
      return 1
      ;;
  esac
  command -v guix >/dev/null 2>&1
}

bootstrap_guix_binary() {
  log "$L_GUIX_BOOTSTRAP"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) BIN="guix-binary-${GUIX_BINARY_VERSION}.x86_64-linux.tar.xz" ;;
    aarch64) BIN="guix-binary-${GUIX_BINARY_VERSION}.aarch64-linux.tar.xz" ;;
    i686) BIN="guix-binary-${GUIX_BINARY_VERSION}.i686-linux.tar.xz" ;;
    *) BIN="" ;;
  esac
  if [[ -z "$BIN" ]]; then log "No binary tarball for arch $ARCH"; return 1; fi

  MIRRORS=( "https://ftp.gnu.org/gnu/guix/$BIN" "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN" )
  TMP="/tmp/guix-bootstrap-$$"
  mkdir -p "$TMP"
  for url in "${MIRRORS[@]}"; do
    log "Trying $url"
    if curl -fsSL --connect-timeout 12 -o "${TMP}/${BIN}" "$url"; then
      log "Downloaded ${BIN}"
      break
    fi
  done
  if [[ ! -f "${TMP}/${BIN}" ]]; then log "Binary tarball download failed"; rm -rf "$TMP"; return 1; fi

  mkdir -p "${TMP}/extracted"
  if ! tar -xJf "${TMP}/${BIN}" -C "${TMP}/extracted"; then log "Extraction failed"; rm -rf "$TMP"; return 1; fi

  # Copy extracted tree into / (best-effort)
  log "Installing Guix binary files to / (best-effort)"
  if tar -C "${TMP}/extracted" -cf - . | tar -C / -xvf - >/dev/null 2>&1; then
    log "Files copied from binary tarball"
  else
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "${TMP}/extracted/" /
    else
      log "Could not copy extracted files reliably (no tar/rsync success)"
      rm -rf "$TMP"
      return 1
    fi
  fi

  # Ensure groups and directories
  if ! getent group guix >/dev/null 2>&1; then groupadd --system guix || true; fi
  if ! getent group guixbuild >/dev/null 2>&1; then groupadd --system guixbuild || true; fi
  mkdir -p /var/guix /var/guix/profiles /run/guix || true
  chown -R root:guix /var/guix || true
  chmod -R 0775 /var/guix || true

  rm -rf "$TMP"
  command -v guix >/dev/null 2>&1 || log "guix binary may be installed but not on PATH"
  return 0
}

ensure_guix_daemon() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q guix-daemon; then
    log "Using systemd to enable/start guix-daemon"
    systemctl enable --now guix-daemon.service >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet guix-daemon; then log "guix-daemon active (systemd)"; return 0; fi
    log "systemd start failed; falling back"
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

probe_substitutes() {
  local usable=()
  for url in "${SUBSTITUTE_HOSTS[@]}"; do
    if curl -fsS --max-time 6 -I "$url" >/dev/null 2>&1; then usable+=("$url"); fi
  done
  printf '%s' "${usable[*]}"
}

write_substitute_config() {
  local usable
  usable="$(probe_substitutes)"
  if [[ -z "$usable" ]]; then log "No substitute hosts reachable"; return 1; fi
  local cfg="/etc/guix/config.scm"
  mkdir -p "$(dirname "$cfg")"
  {
    echo ";; Auto-generated substitute configuration"
    echo "(substitute-urls (list"
    for u in $usable; do echo " \"$u\""; done
    echo "))"
  } > "$cfg"
  log "Wrote $cfg"
  return 0
}

ensure_guix() {
  if command -v guix >/dev/null 2>&1; then
    log "Guix CLI already present: $(guix --version 2>/dev/null || true)"
  else
    if install_guix_via_distro; then
      log "Guix installed via distro package"
    else
      if bootstrap_guix_binary; then
        log "Guix binary bootstrap completed (best-effort)"
      else
        log "Guix bootstrap failed"
      fi
    fi
  fi

  if ensure_guix_daemon; then
    write_substitute_config || log "No substitutes written"
    return 0
  else
    return 1
  fi
}

# -------------------- Partition & install flow --------------------
to_mib() { local s="$1"; if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 )); elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$s"; fi; }

safe_mkpart() {
  local disk="$1" start="$2" end="$3"
  if (( end <= start + 1 )); then die "Invalid partition range ${start}MiB-${end}MiB"; fi
  parted --script --align optimal "$disk" mkpart primary "${start}MiB" "${end}MiB"
}

step_welcome() { gui_info "$L_WELCOME" "$L_WELCOME_SUB"; }

step_select_disk() {
  mapfile -t disks < <(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk" {printf "/dev/%s (%s)\n",$1,$2}')
  [[ ${#disks[@]} -gt 0 ]] || die "No disks found"
  if [[ -z "$TARGET_DISK" ]]; then
    choice="$(gui_list "$L_SELECT_DISK" "$L_SELECT_DISK" "${disks[@]}")"
    [[ -n "$choice" ]] || die "$L_ABORT_MSG"
    TARGET_DISK="$(echo "$choice" | awk '{print $1}')"
  fi
  gui_info "$L_SELECT_DISK" "Target: $TARGET_DISK"
}

step_partition_options() {
  if ! gui_yesno "$L_SELECT_PART" "Use guided partitioning (whole disk)?"; then
    if gui_yesno "$L_SELECT_PART" "Open a shell to partition manually now?"; then
      bash -i
      partprobe "$TARGET_DISK" || true
      udevadm settle --timeout=10 || true
      sleep 1
    else
      die "$L_ABORT_MSG"
    fi
    return
  fi

  if [[ -z "$FS_TYPE" ]]; then FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" ext4 btrfs xfs)"; fi
  if [[ -z "${CREATE_HOME}" ]]; then gui_yesno "Home" "Create separate /home partition?" && CREATE_HOME=1 || CREATE_HOME=0; fi
  if [[ -z "${CREATE_SWAP}" ]]; then gui_yesno "Swap" "Create swap partition?" && CREATE_SWAP=1 || CREATE_SWAP=0; fi

  total_mib=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1024 / 1024 ))
  if (( total_mib < 64 )); then die "Disk too small"; fi

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
  if (( remaining <= 8 )); then die "Not enough usable space on disk"; fi

  if (( CREATE_SWAP == 1 )); then
    swap_mib=$(to_mib "$SWAP_SIZE")
    if (( swap_mib < 4 )); then swap_mib=4; fi
    if (( swap_mib > remaining / 4 )); then swap_mib=$(( remaining / 10 )); fi
  else
    swap_mib=0
  fi

  usable=$(( remaining - swap_mib ))
  if (( usable < 8 )); then die "Not enough space for root/home after reserving swap"; fi

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

  # Cap ends
  cap_end() {
    local val=$1 total=$2
    if (( val > total - 1 )); then val=$(( total - 1 )); fi
    echo "$val"
  }
  root_end=$(cap_end "$root_end" "$total_mib")
  if [[ -n "${home_end:-}" ]]; then home_end=$(cap_end "$home_end" "$total_mib"); fi
  if (( swap_mib > 0 )); then
    swap_start=$(( total_mib - swap_mib - 1 ))
    if [[ -z "${home_end:-}" ]]; then
      if (( swap_start <= root_end )); then swap_start=$(( root_end + 1 )); fi
    else
      if (( swap_start <= home_end )); then swap_start=$(( home_end + 1 )); fi
    fi
    swap_end=$(cap_end $(( swap_start + swap_mib )) "$total_mib")
  fi

  # Validate minimal sizes
  if (( root_end <= root_start + 3 )); then die "Root partition too small"; fi
  if [[ -n "${home_start:-}" ]]; then
    if (( home_end <= home_start + 3 )); then die "Home partition too small"; fi
  fi
  if (( swap_mib > 0 )); then
    if (( swap_end <= swap_start + 3 )); then swap_mib=0; fi
  fi

  # Create partitions explicitly
  safe_mkpart "$TARGET_DISK" "$root_start" "$root_end"
  if [[ -n "${home_start:-}" && -n "${home_end:-}" ]]; then
    safe_mkpart "$TARGET_DISK" "$home_start" "$home_end"
  fi
  if (( swap_mib > 0 )); then
    safe_mkpart "$TARGET_DISK" "$swap_start" "$swap_end"
  fi

  partprobe "$TARGET_DISK" || true
  udevadm settle --timeout=10 || true
  sleep 1
  gui_info "$L_SELECT_PART" "Guided partitioning complete"
}

step_user_setup() {
  if [[ -z "$USERNAME" ]]; then USERNAME="$(gui_entry "$L_USER_SETUP" "Choose a username" "user")"; fi
  if [[ -z "$USER_PASS" ]]; then USER_PASS="$(gui_entry "$L_USER_SETUP" "Choose a password for $USERNAME" "guixpass")"; fi
  if [[ -z "$ROOT_PASS" ]]; then ROOT_PASS="$(gui_entry "$L_USER_SETUP" "Choose root password" "rootpass")"; fi
  if [[ -z "$LOCALE" ]]; then LOCALE="$(gui_list "Locale" "Choose locale" "en_US.UTF-8" "pt_BR.UTF-8")"; fi
  if [[ -z "$TIMEZONE" ]]; then TIMEZONE="$(gui_entry "Timezone" "Region/City" "America/Sao_Paulo")"; fi
  if [[ -z "$DESKTOP" ]]; then DESKTOP="$(gui_list "Desktop" "Choose desktop" "i3" "mate" "xfce" "sway" "none")"; fi
  if [[ -z "$FS_TYPE" ]]; then FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" "ext4" "btrfs" "xfs")"; fi
}

step_summary() {
  summary="Disk: $TARGET_DISK
User: ${USERNAME:-user}
Desktop: $DESKTOP
FS: $FS_TYPE
Locale: $LOCALE
Timezone: $TIMEZONE
Keyboard: $KEYBOARD
Create /home: ${CREATE_HOME:-auto}
Create swap: ${CREATE_SWAP:-auto}"
  gui_info "$L_SUMMARY" "$summary"
  if [[ "${AUTO_YES:-0}" -eq 0 ]]; then
    gui_yesno "$L_SUMMARY" "Proceed with installation?" || die "$L_ABORT_MSG"
  fi
}

discover_parts() {
  partprobe "$TARGET_DISK" || true
  udevadm settle --timeout=10 || true
  sleep 1
  parts=()
  for idx in 1 2 3 4 5 6; do
    if [[ -b "${TARGET_DISK}${idx}" ]]; then parts+=("${TARGET_DISK}${idx}"); fi
    if [[ -b "${TARGET_DISK}p${idx}" ]]; then parts+=("${TARGET_DISK}p${idx}"); fi
  done
  EFI_PART=""; ROOT_PART=""; HOME_PART=""; SWAP_PART=""
  if [[ -d /sys/firmware/efi ]]; then
    EFI_PART="${parts[0]:-}"
    ROOT_PART="${parts[1]:-}"
    HOME_PART="${parts[2]:-}"
    SWAP_PART="${parts[3]:-}"
  else
    ROOT_PART="${parts[0]:-}"
    HOME_PART="${parts[1]:-}"
    SWAP_PART="${parts[2]:-}"
  fi
}

step_install() {
  discover_parts
  [[ -n "$ROOT_PART" ]] || die "Root partition not found"

  if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then mkfs.vfat -F32 "$EFI_PART"; fi
  case "$FS_TYPE" in
    ext4) mkfs.ext4 -F "$ROOT_PART" ;;
    btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
    xfs) mkfs.xfs -f "$ROOT_PART" ;;
    *) mkfs.ext4 -F "$ROOT_PART" ;;
  esac
  if [[ -n "$HOME_PART" && -b "$HOME_PART" ]]; then
    case "$FS_TYPE" in
      ext4) mkfs.ext4 -F "$HOME_PART" ;;
      btrfs) mkfs.btrfs -f "$HOME_PART" ;;
      xfs) mkfs.xfs -f "$HOME_PART" ;;
    esac
  fi
  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then mkswap "$SWAP_PART"; fi

  mkdir -p /mnt
  mount "$ROOT_PART" /mnt
  if [[ -n "$EFI_PART" ]]; then mkdir -p /mnt/boot/efi; mount "$EFI_PART" /mnt/boot/efi; fi
  if [[ -n "$HOME_PART" ]]; then mkdir -p /mnt/home; mount "$HOME_PART" /mnt/home; fi

  huser="$(openssl passwd -6 -- "$USER_PASS")"
  hroot="$(openssl passwd -6 -- "$ROOT_PASS")"

  root_uuid="$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)"
  home_uuid="$(blkid -s UUID -o value "$HOME_PART" 2>/dev/null || true)"
  efi_uuid="$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)"

  mkdir -p /mnt/etc
  cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (guix) (guix profiles) (gnu services) (gnu packages base) (gnu packages linux) (gnu services desktop))
(operating-system
 (host-name "${HOSTNAME:-guix-machine}")
 (timezone "${TIMEZONE}")
 (locale "${LOCALE}")
 (keyboard-layout (keyboard-layout "${KEYBOARD}")))
EOF

  if [[ -n "$EFI_PART" ]]; then
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

  if [[ -n "$root_uuid" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${root_uuid}")) (mount-point "/") (type "${FS_TYPE}"))
EOF
  else
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${ROOT_PART}") (mount-point "/") (type "${FS_TYPE}"))
EOF
  fi

  if [[ -n "$home_uuid" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${home_uuid}")) (mount-point "/home") (type "${FS_TYPE}"))
EOF
  elif [[ -n "$HOME_PART" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device "${HOME_PART}") (mount-point "/home") (type "${FS_TYPE}"))
EOF
  fi

  if [[ -n "$efi_uuid" ]]; then
    cat >> /mnt/etc/config.scm <<EOF
 (file-system (device (uuid "${efi_uuid}")) (mount-point "/boot/efi") (type "vfat"))
EOF
  fi

  cat >> /mnt/etc/config.scm <<'EOF'
 %base-file-systems))
EOF

  if [[ -n "$SWAP_PART" ]]; then
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
                                   (user-account (inherit u) (password "${hroot}"))
                                   u)) %base-user-accounts)))
 (packages (list ${BASE_PACKAGES[*]}))
 (services %base-services))
EOF

  cat > /mnt/etc/channels.scm <<'EOF'
(list (channel (name 'guix) (url "https://codeberg.org/guix/guix.git") (branch "master")))
EOF

  # Try to ensure Guix CLI and daemon
  if ensure_guix; then
    subs="$(probe_substitutes)"
    if [[ -n "$subs" ]]; then export GUIX_SUBSTITUTE_URLS="$subs"; fi
    if command -v guix >/dev/null 2>&1; then
      attempts=0
      while (( attempts < 4 )); do
        log "guix system init attempt $((attempts+1))"
        if guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt --no-build-output; then
          log "guix system init succeeded"
          break
        fi
        attempts=$((attempts+1))
        sleep $((5 * attempts))
      done
      if (( attempts >= 4 )); then log "guix system init failed after retries; configuration written to /mnt/etc"; fi
    else
      log "guix CLI unavailable after bootstrap attempts; configuration written to /mnt/etc"
    fi
  else
    log "Guix bootstrap/daemon start failed; configuration written to /mnt/etc"
  fi

  gui_info "$L_FINISH" "Installation steps completed (best-effort)."
}

# -------------------- Orchestration --------------------
main() {
  choose_lang
  detect_gui
  if [[ "$(id -u)" -ne 0 ]]; then die "Run this script as root"; fi
  step_welcome
  step_select_disk
  step_partition_options
  step_user_setup
  step_summary
  step_install
  sync
  umount -R /mnt || true
  gui_info "$L_FINISH" "Rebooting in 5s..."
  sleep 5
  reboot
}

main "$@"