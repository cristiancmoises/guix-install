#!/usr/bin/env bash
set -euo pipefail

# -------------------- GNU GUIX INSTALLER WITH GUI --------------------
# Enhanced interactive installer with:
# - graphical dialogs via zenity or yad (fallback to text)
# - corrected Guix substitutes
# - pt-BR / en-US localization
# - easy mode (AUTO_YES) and env-driven non-interactive mode
# - full packages list, channels and use-modules preserved
# - robust substitute probing, guix-daemon checks, guix bootstrap attempt
# Run this script as root.

# -------------------- Configuration / Defaults --------------------
LANG_OPT="${LANG_OPT:-auto}"   # auto | en | pt
AUTO_YES="${AUTO_YES:-0}"      # 1 to skip lengthy confirmation
TARGET_DISK="${TARGET_DISK:-}"  # e.g., /dev/sda
USERNAME="${USERNAME:-}"       # user name
USER_PASS="${USER_PASS:-}"     # user password (plaintext, used only here)
ROOT_PASS="${ROOT_PASS:-}"     # root password
LOCALE="${LOCALE:-}"           # e.g., en_US.UTF-8 or pt_BR.UTF-8
TIMEZONE="${TIMEZONE:-}"       # e.g., America/Sao_Paulo
DESKTOP="${DESKTOP:-}"         # i3,mate,xfce,sway,none
FS_TYPE="${FS_TYPE:-}"         # ext4,btrfs,xfs
CREATE_HOME="${CREATE_HOME:-}" # 1=yes 0=no (if empty prompt)
CREATE_SWAP="${CREATE_SWAP:-}" # 1=yes 0=no (if empty prompt)
SWAP_SIZE="${SWAP_SIZE:-4G}"   # default swap size when creating swap
GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.4.0}"
USE_GUI="${USE_GUI:-auto}"     # auto | gui | text. auto: try gui if available

# Corrected Guix substitute hosts (Guix servers only)
SUBSTITUTE_HOSTS=(
  "https://hydra.gnu.org"
  "https://cache.guix.gnu.org"
  "https://ci.guix.info"
  "https://ci.guix.gnu.org"
)

# -------------------- Localization --------------------
choose_lang() {
  if [[ "$LANG_OPT" == "auto" ]]; then
    term_lang="${LC_ALL:-${LANG:-}}"
    if [[ "$term_lang" =~ ^pt|BR|br ]]; then LANG_OPT="pt"; else LANG_OPT="en"; fi
  fi
  if [[ "$LANG_OPT" == "pt" ]]; then
    MSG_YES="s"
    MSG_NO="n"
    T_BANNER="INSTALAÇÃO GNU GUIX"
    T_RUN_AS_ROOT="Execute este script como root"
    T_TARGET_PROMPT="Disco alvo (ex: /dev/sda, /dev/nvme0n1)"
    T_CONFIRM_TYPE="Para confirmar, DIGITE EXATAMENTE 'SIM EU QUERO GUIX' ou exporte AUTO_YES=1 para pular"
    T_ABORT="Abortado pelo usuário"
    T_DEFAULT="Padrão"
    T_CHOOSE_DESK="Desktop: 1=i3 2=mate 3=xfce 4=sway 5=nenhum"
    T_PLEASE="Por favor responda sim/não"
    GUI_TITLE="Instalador GNU Guix"
    GUI_SUMMARY="Instalação fácil do GNU Guix"
  else
    MSG_YES="y"
    MSG_NO="n"
    T_BANNER="GNU GUIX FULL OS INSTALL"
    T_RUN_AS_ROOT="Run this script as root"
    T_TARGET_PROMPT="Target disk (e.g., /dev/sda, /dev/nvme0n1)"
    T_CONFIRM_TYPE="To confirm, TYPE EXACTLY 'YES I WANT GUIX' or export AUTO_YES=1 to skip"
    T_ABORT="Aborted by user"
    T_DEFAULT="Default"
    T_CHOOSE_DESK="Desktop: 1=i3 2=mate 3=xfce 4=sway 5=none"
    T_PLEASE="Please answer yes/no"
    GUI_TITLE="GNU Guix Installer"
    GUI_SUMMARY="Easy GNU Guix installation"
  fi
}

# -------------------- Helpers --------------------
log() { printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }
err() { log "ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# -------------------- GUI detection and wrappers --------------------
detect_gui_tools() {
  GUI_TOOL=""
  if [[ "${USE_GUI}" == "text" ]]; then
    GUI_TOOL=""
    return
  fi
  if command -v yad >/dev/null 2>&1; then GUI_TOOL="yad"; return; fi
  if command -v zenity >/dev/null 2>&1; then GUI_TOOL="zenity"; return; fi
  GUI_TOOL=""
}

gui_info() {
  local msg="${1:-}"
  if [[ -n "$GUI_TOOL" ]]; then
    case "$GUI_TOOL" in
      yad) yad --title "$GUI_TITLE" --info --text "$msg" --no-buttons --timeout=3 >/dev/null 2>&1 || true ;;
      zenity) zenity --info --title "$GUI_TITLE" --text "$msg" --timeout=3 >/dev/null 2>&1 || true ;;
    esac
  else
    log "$msg"
  fi
}

gui_question() {
  local prompt="$1" default_answer="${2:-}"
  if [[ -n "$GUI_TOOL" ]]; then
    case "$GUI_TOOL" in
      yad)
        if yad --title "$GUI_TITLE" --question --text "$prompt" --button=NO:1 --button=YES:0 >/dev/null 2>&1; then
          return 0
        else
          return 1
        fi
        ;;
      zenity)
        if zenity --question --title "$GUI_TITLE" --text "$prompt" >/dev/null 2>&1; then
          return 0
        else
          return 1
        fi
        ;;
    esac
  fi
  # fallback to text
  yn_prompt "$prompt" "${default_answer:-$MSG_NO}"
}

gui_entry() {
  local prompt="$1" default="$2"
  if [[ -n "$GUI_TOOL" ]]; then
    case "$GUI_TOOL" in
      yad) yad --title "$GUI_TITLE" --entry --text "$prompt" --entry-text "$default" 2>/dev/null || echo "$default" ;;
      zenity) zenity --entry --title "$GUI_TITLE" --text "$prompt" --entry-text "$default" 2>/dev/null || echo "$default" ;;
    esac
  else
    prompt_default "$prompt" "$default"
  fi
}

gui_password() {
  local prompt="$1" default="$2"
  if [[ -n "$GUI_TOOL" ]]; then
    case "$GUI_TOOL" in
      yad) yad --title "$GUI_TITLE" --entry --text "$prompt" --entry-password 2>/dev/null || echo "$default" ;;
      zenity) zenity --entry --title "$GUI_TITLE" --text "$prompt" --hide-text 2>/dev/null || echo "$default" ;;
    esac
  else
    if [[ "${AUTO_YES:-0}" -eq 1 ]]; then
      echo "$default"
    else
      read -r -s -p "$prompt: " pw; echo; echo "${pw:-$default}"
    fi
  fi
}

prompt_default() {
  local prompt="$1" default="$2"
  if [[ -n "$GUI_TOOL" ]]; then
    gui_entry "$prompt" "$default"
  else
    if [[ "${AUTO_YES:-0}" -eq 1 ]]; then
      echo "$default"
      return
    fi
    read -r -p "$prompt [$T_DEFAULT: $default]: " val
    echo "${val:-$default}"
  fi
}

yn_prompt() {
  local prompt="$1" default="$2"
  if [[ -n "$GUI_TOOL" ]]; then
    gui_question "$prompt" "$default"
    return $?
  fi
  if [[ "${AUTO_YES:-0}" -eq 1 ]]; then
    [[ "$default" =~ ^[YySs] ]] && return 0 || return 1
  fi
  while true; do
    read -r -p "$prompt [$default]: " val
    val="${val:-$default}"
    case "$val" in
      [YySs]* ) return 0 ;;
      [Nn]* ) return 1 ;;
      * ) echo "$T_PLEASE" ;;
    esac
  done
}

# -------------------- Pre-flight --------------------
choose_lang
detect_gui_tools

cat <<-BANNER
+-------------------------------------------------------------+
|                      $T_BANNER
+-------------------------------------------------------------+
BANNER

if [[ "$(id -u)" -ne 0 ]]; then die "$T_RUN_AS_ROOT"; fi

# detect package manager (best-effort)
PKG=""
if command -v apt >/dev/null 2>&1; then PKG="apt"
elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
elif command -v pacman >/dev/null 2>&1; then PKG="pacman"
fi

install_host_pkgs() {
  case "$PKG" in
    apt)
      apt update
      apt install -y wget curl ca-certificates gnupg2 python3 util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz-utils btrfs-progs xfsprogs uidmap openssl zenity yad >/dev/null || true
      ;;
    dnf)
      dnf install -y wget curl ca-certificates python3 util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs shadow-utils openssl zenity yad >/dev/null || true
      ;;
    pacman)
      pacman -Sy --noconfirm wget curl ca-certificates python util-linux gdisk parted e2fsprogs dosfstools cryptsetup xz btrfs-progs xfsprogs uidmap openssl zenity yad >/dev/null || true
      ;;
    *)
      log "No known package manager; ensure required commands are present"
      ;;
  esac
}
# best-effort install GUI tools if desired and package manager available
if [[ -n "$GUI_TOOL" ]]; then
  install_host_pkgs
fi

# -------------------- Guix CLI & Daemon checks --------------------
guix_available() {
  command -v guix >/dev/null 2>&1
}

bootstrap_guix_binary() {
  if guix_available; then
    log "Guix CLI available: $(guix --version 2>/dev/null || true)"
    return 0
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) BIN="guix-binary-${GUIX_BINARY_VERSION}.x86_64-linux.tar.xz" ;;
    aarch64) BIN="guix-binary-${GUIX_BINARY_VERSION}.aarch64-linux.tar.xz" ;;
    i686) BIN="guix-binary-${GUIX_BINARY_VERSION}.i686-linux.tar.xz" ;;
    *) BIN="" ;;
  esac
  if [[ -z "$BIN" ]]; then err "No prebuilt Guix binary for arch: $ARCH"; return 1; fi

  MIRRORS=(
    "https://ftp.gnu.org/gnu/guix/$BIN"
    "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN"
    "https://mirror0.nexcess.net/gnu/guix/$BIN"
  )
  for url in "${MIRRORS[@]}"; do
    log "Trying $url"
    if curl -fsSL --connect-timeout 8 -o "/tmp/$BIN" "$url"; then
      tar -xJf "/tmp/$BIN" -C / || { err "Extraction failed"; return 1; }
      rm -f "/tmp/$BIN"
      return 0
    fi
  done
  return 1
}

ensure_guix_daemon() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --full -all | grep -q guix-daemon; then
    systemctl restart guix-daemon || true
    sleep 1
    if ! systemctl is-active --quiet guix-daemon; then
      journalctl -u guix-daemon --no-pager -n 200 | sed -n '1,200p' >&2 || true
      err "guix-daemon failed to start"
      return 1
    fi
    log "guix-daemon active"
    return 0
  else
    if command -v guix-daemon >/dev/null 2>&1; then
      pkill -f guix-daemon || true
      setsid guix-daemon --build-users-group=guixbuild >/var/log/guix-daemon.log 2>&1 & sleep 2
      pgrep -a guix-daemon >/dev/null 2>&1 && { log "Started guix-daemon (background)"; return 0; }
      err "Failed to start guix-daemon"
      return 1
    else
      err "guix-daemon not found"
      return 1
    fi
  fi
}

# -------------------- Substitute probing and configuration --------------------
probe_substitutes() {
  local usable=()
  for url in "${SUBSTITUTE_HOSTS[@]}"; do
    if curl -fsS --max-time 6 -I "$url" >/dev/null 2>&1; then
      usable+=("$url")
    fi
  done
  printf '%s' "${usable[*]}"
}

ensure_guix_substitute_config() {
  local cfg="/etc/guix/config.scm"
  if [[ ! -f "$cfg" ]]; then
    cat >"$cfg" <<'SCM'
;; Minimal Guix substitute configuration created by installer
SCM
  fi
  usable="$(probe_substitutes)"
  if [[ -z "$usable" ]]; then
    log "No substitute hosts reachable from probe_substitutes"
    return 1
  fi
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'SCM'
;; Auto-generated substitute-urls (operating-mode 'daemon)
(substitute-urls (list
SCM
  for url in $usable; do
    echo " \"${url}\"" >> "$tmpfile"
  done
  cat >> "$tmpfile" <<'SCM'
))
SCM
  mv "$tmpfile" "$cfg"
  log "Wrote substitute config to $cfg with: $usable"
  return 0
}

# -------------------- Inputs (interactive GUI or text) --------------------
get_inputs() {
  # Disk
  if [[ -z "$TARGET_DISK" ]]; then
    TARGET_DISK="$(gui_entry "$T_TARGET_PROMPT" "/dev/sda")"
  fi
  [[ -b "$TARGET_DISK" ]] || die "Invalid disk: $TARGET_DISK"

  # Hostname
  HOSTNAME="${HOSTNAME:-guix-machine}"
  HOSTNAME="$(prompt_default "Hostname" "$HOSTNAME")"

  # Timezone
  if [[ -z "$TIMEZONE" ]]; then
    guess_tz="$(cat /etc/timezone 2>/dev/null || date +%Z || true)"
    TIMEZONE="$(prompt_default "Timezone (e.g., America/Sao_Paulo)" "${TIMEZONE:-$guess_tz}")"
  fi

  # Locale
  if [[ -z "$LOCALE" ]]; then
    LOCALE="$(prompt_default "Locale (en_US.UTF-8 or pt_BR.UTF-8)" "${LOCALE:-en_US.UTF-8}")"
  fi

  # Keyboard
  KEYBOARD="$(prompt_default "Keyboard layout (e.g., br-abnt2 or us)" "${KEYBOARD:-br-abnt2}")"

  # Username and passwords
  if [[ -z "$USERNAME" ]]; then
    USERNAME="$(prompt_default "Username" "user")"
  fi
  if [[ -z "$USER_PASS" ]]; then
    USER_PASS="$(gui_password "User password" "guixpass")"
  fi
  if [[ -z "$ROOT_PASS" ]]; then
    ROOT_PASS="$(gui_password "Root password" "rootpass")"
  fi

  # Desktop choice
  if [[ -z "$DESKTOP" ]]; then
    if [[ -n "$GUI_TOOL" ]]; then
      case "$GUI_TOOL" in
        yad) dch=$(yad --title "$GUI_TITLE" --list --column "" "i3" "mate" "xfce" "sway" "none" --height=200 --width=300 2>/dev/null | head -n1 || echo "none") ;;
        zenity) dch=$(zenity --list --title="$GUI_TITLE" --column="Desktop" "i3" "mate" "xfce" "sway" "none" --height=200 --width=300 2>/dev/null | head -n1 || echo "none") ;;
      esac
      case "$dch" in
        i3) DESKTOP="i3" ;;
        mate) DESKTOP="mate" ;;
        xfce) DESKTOP="xfce" ;;
        sway) DESKTOP="sway" ;;
        *) DESKTOP="none" ;;
      esac
    else
      echo "$T_CHOOSE_DESK"
      read -r -p "Choice (1/2/3/4/5) [5]: " dch
      dch="${dch:-5}"
      case "$dch" in
        1) DESKTOP="i3" ;;
        2) DESKTOP="mate" ;;
        3) DESKTOP="xfce" ;;
        4) DESKTOP="sway" ;;
        5) DESKTOP="none" ;;
        *) DESKTOP="none" ;;
      esac
    fi
  fi

  # Filesystem
  if [[ -z "$FS_TYPE" ]]; then
    FS_TYPE="$(prompt_default "Filesystem type (ext4/btrfs/xfs)" "ext4")"
  fi

  # Create /home and swap
  if [[ -z "${CREATE_HOME}" ]]; then
    yn_prompt "Create separate /home partition? (y/N)" "$MSG_NO" && CREATE_HOME=1 || CREATE_HOME=0
  fi
  if [[ -z "${CREATE_SWAP}" ]]; then
    yn_prompt "Create swap? (y/N)" "$MSG_NO" && CREATE_SWAP=1 || CREATE_SWAP=0
  fi
  if [[ "$CREATE_SWAP" -eq 1 && -z "$SWAP_SIZE" ]]; then
    SWAP_SIZE="$(prompt_default "Swap size (e.g., 4G)" "4G")"
  fi
}

# -------------------- Partition helpers --------------------
mounted_on_disk(){
  local base="$(basename "$TARGET_DISK")"
  while read -r name mnt; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ ^"$base" ]]; then
      if [[ -n "$mnt" ]]; then
        return 0
      fi
    fi
  done < <(lsblk -nr -o NAME,MOUNTPOINT)
  return 1
}
to_mib(){ local s="$1"
  if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"
  else echo "$s"
  fi
}

# -------------------- MAIN FLOW --------------------
get_inputs

# Confirmation
if [[ "${AUTO_YES:-0}" -ne 1 ]]; then
  summary="Disk: $TARGET_DISK\nHostname: $HOSTNAME\nUser: $USERNAME\nDesktop: $DESKTOP\nFS: $FS_TYPE\nLocale: $LOCALE\nTimezone: $TIMEZONE"
  if [[ -n "$GUI_TOOL" ]]; then
    gui_info "$summary"
    if [[ "${LANG_OPT}" == "pt" ]]; then
      CONF="$(gui_entry "$T_CONFIRM_TYPE" "")"
      [[ "$CONF" == "SIM EU QUERO GUIX" ]] || die "$T_ABORT"
    else
      CONF="$(gui_entry "$T_CONFIRM_TYPE" "")"
      [[ "$CONF" == "YES I WANT GUIX" ]] || die "$T_ABORT"
    fi
  else
    echo -e "$summary"
    if [[ "${LANG_OPT}" == "pt" ]]; then
      read -r -p "$T_CONFIRM_TYPE: " CONF
      [[ "$CONF" == "SIM EU QUERO GUIX" ]] || die "$T_ABORT"
    else
      read -r -p "$T_CONFIRM_TYPE: " CONF
      [[ "$CONF" == "YES I WANT GUIX" ]] || die "$T_ABORT"
    fi
  fi
fi

# Partitioning
if mounted_on_disk; then die "One or more partitions on $TARGET_DISK are mounted. Unmount and re-run."; fi

total_mib=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1024 / 1024 ))
efi_size=512

if [[ -d /sys/firmware/efi ]]; then
  parted --script "$TARGET_DISK" mklabel gpt
  parted --script --align optimal "$TARGET_DISK" mkpart primary 1MiB ${efi_size}MiB
  parted --script "$TARGET_DISK" set 1 esp on
  used_mib=$efi_size
else
  parted --script "$TARGET_DISK" mklabel msdos
  used_mib=1
fi

remaining_mib=$(( total_mib - used_mib ))
swap_mib=0
if [[ "$CREATE_SWAP" -eq 1 ]]; then
  swap_mib=$(to_mib "$SWAP_SIZE")
  if (( swap_mib >= remaining_mib )); then
    swap_mib=$(( remaining_mib / 10 ))
    (( swap_mib < 1 )) && swap_mib=0
  fi
  remaining_mib=$(( remaining_mib - swap_mib ))
fi

if [[ "$CREATE_HOME" -eq 1 && "$CREATE_SWAP" -eq 1 ]]; then
  root_mib=$(( remaining_mib / 2 ))
  home_mib=$(( remaining_mib - root_mib ))
  start_mib=$used_mib
  end_mib=$(( start_mib + root_mib ))
  parted --script --align optimal "$TARGET_DISK" mkpart primary "${start_mib}MiB" "${end_mib}MiB"
  parted --script --align optimal "$TARGET_DISK" mkpart primary "${end_mib}MiB" $(( end_mib + home_mib ))MiB
  if (( swap_mib > 0 )); then
    parted --script --align optimal "$TARGET_DISK" mkpart primary 100% -${swap_mib}MiB
  fi
elif [[ "$CREATE_HOME" -eq 1 ]]; then
  root_mib=$(( remaining_mib / 2 ))
  home_mib=$(( remaining_mib - root_mib ))
  start_mib=$used_mib
  end_mib=$(( start_mib + root_mib ))
  parted --script --align optimal "$TARGET_DISK" mkpart primary "${start_mib}MiB" "${end_mib}MiB"
  parted --script --align optimal "$TARGET_DISK" mkpart primary "${end_mib}MiB" 100%
elif [[ "$CREATE_SWAP" -eq 1 ]]; then
  parted --script --align optimal "$TARGET_DISK" mkpart primary "${used_mib}MiB" 100%
  if (( swap_mib > 0 )); then
    parted --script --align optimal "$TARGET_DISK" mkpart primary 100% -${swap_mib}MiB
  fi
else
  parted --script --align optimal "$TARGET_DISK" mkpart primary "${used_mib}MiB" 100%
fi

partprobe "$TARGET_DISK" || true
udevadm settle --timeout=10 || true
sleep 1

part_node(){
  local idx="$1"
  if [[ -b "${TARGET_DISK}${idx}" ]]; then echo "${TARGET_DISK}${idx}"
  elif [[ -b "${TARGET_DISK}p${idx}" ]]; then echo "${TARGET_DISK}p${idx}"
  else echo ""
  fi
}

parts=()
for idx in 1 2 3 4 5 6; do
  node=$(part_node "$idx")
  if [[ -n "$node" ]]; then parts+=("$node"); fi
done

EFI_PART=""
ROOT_PART=""
HOME_PART=""
SWAP_PART=""
if [[ -d /sys/firmware/efi ]]; then
  EFI_PART="${parts[0]}"
  if [[ "${#parts[@]}" -ge 4 && "$CREATE_HOME" -eq 1 && "$CREATE_SWAP" -eq 1 ]]; then
    ROOT_PART="${parts[1]}"; HOME_PART="${parts[2]}"; SWAP_PART="${parts[3]}"
  elif [[ "${#parts[@]}" -ge 3 && "$CREATE_HOME" -eq 1 ]]; then
    ROOT_PART="${parts[1]}"; HOME_PART="${parts[2]}"
  else
    ROOT_PART="${parts[1]}"
  fi
else
  if [[ "${#parts[@]}" -ge 3 && "$CREATE_HOME" -eq 1 && "$CREATE_SWAP" -eq 1 ]]; then
    ROOT_PART="${parts[0]}"; HOME_PART="${parts[1]}"; SWAP_PART="${parts[2]}"
  elif [[ "${#parts[@]}" -ge 2 && "$CREATE_HOME" -eq 1 ]]; then
    ROOT_PART="${parts[0]}"; HOME_PART="${parts[1]}"
  else
    ROOT_PART="${parts[0]}"
  fi
fi

[[ -n "$ROOT_PART" ]] || die "Root partition not found; aborting."

# Format partitions
log "Formatting filesystems..."
if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then mkfs.vfat -F32 "$EFI_PART"; fi
if [[ -b "$ROOT_PART" ]]; then
  case "$FS_TYPE" in
    ext4) mkfs.ext4 -F "$ROOT_PART" ;;
    btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
    xfs) mkfs.xfs -f "$ROOT_PART" ;;
    *) mkfs.ext4 -F "$ROOT_PART" ;;
  esac
fi
if [[ -n "$HOME_PART" && -b "$HOME_PART" ]]; then
  case "$FS_TYPE" in
    ext4) mkfs.ext4 -F "$HOME_PART" ;;
    btrfs) mkfs.btrfs -f "$HOME_PART" ;;
    xfs) mkfs.xfs -f "$HOME_PART" ;;
    *) mkfs.ext4 -F "$HOME_PART" ;;
  esac
fi
if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then
  mkswap "$SWAP_PART"
fi

# Mount
mkdir -p /mnt
mount "$ROOT_PART" /mnt
if [[ -n "$EFI_PART" ]]; then mkdir -p /mnt/boot/efi; mount "$EFI_PART" /mnt/boot/efi; fi
if [[ -n "$HOME_PART" ]]; then mkdir -p /mnt/home; mount "$HOME_PART" /mnt/home; fi

# Hash passwords
huser="$(openssl passwd -6 -- "$USER_PASS")"
hroot="$(openssl passwd -6 -- "$ROOT_PASS")"

# UUIDs
root_uuid="$(blkid -s UUID -o value "$ROOT_PART" || true)"
home_uuid="$(blkid -s UUID -o value "$HOME_PART" || true)"
efi_uuid="$(blkid -s UUID -o value "$EFI_PART" || true)"

# -------------------- Write full config.scm with use-modules, packages, channels --------------------
mkdir -p /mnt/etc

cat > /mnt/etc/config.scm <<'EOF'
(use-modules (gnu) (guix) (guix profiles) (gnu services)
             (gnu packages base) (gnu packages linux) (gnu packages gl)
             (gnu packages package-management) (gnu packages admin)
             (gnu packages file-systems) (gnu packages terminals)
             (gnu packages version-control) (gnu packages python)
             (gnu packages video) (gnu packages xorg) (gnu services desktop)
             (gnu packages tls) (gnu packages gnupg) (gnu packages fonts)
             (gnu packages image-viewers) (gnu packages vpn) (gnu packages tor)
             (nongnu packages linux))
EOF

cat >> /mnt/etc/config.scm <<EOF
(operating-system
 (host-name "${HOSTNAME}")
 (timezone "${TIMEZONE}")
 (locale "${LOCALE}")
 (keyboard-layout (keyboard-layout "${KEYBOARD}"))
EOF

if [[ -n "$EFI_PART" ]]; then
cat >> /mnt/etc/config.scm <<'EOF'
 (bootloader (bootloader-configuration (bootloader grub-efi-bootloader) (targets '("/boot/efi"))))
EOF
else
cat >> /mnt/etc/config.scm <<EOF
 (bootloader (bootloader-configuration (bootloader grub-bootloader) (targets '("${TARGET_DISK}"))))
EOF
fi

cat >> /mnt/etc/config.scm <<'EOF'
 (kernel linux)
 (initrd microcode-initrd)
 (firmware (list linux-firmware))
EOF

cat >> /mnt/etc/config.scm <<'EOF'
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
 (users (cons* (user-account (name "${USERNAME}") (group "users")
                             (home (string-append "/home/" "${USERNAME}"))
                             (password "${huser}")
                             (supplementary-groups '("wheel" "netdev" "audio" "networking" "video")))
               (map (lambda (u) (if (string=? (user-account-name u) "root")
                                   (user-account (inherit u) (password "${hroot}"))
                                   u)) %base-user-accounts)))
EOF

cat >> /mnt/etc/config.scm <<'EOF'
 (packages (append (list
   icecat torbrowser libreoffice mpv feh acpi-call-linux-module util-linux
   v4l2loopback-linux-module mesa mesa-headers llvm-for-mesa libva libva-utils
   linux-firmware xterm xorg-xdpyinfo xorg-xset xorg-xwininfo xorg-xprop xpra
   xorg-xkill xorg-setxkbmap xorg-xmodmap xdg-utils xorg-xrandr lf mergerfs
   parted ntfs-3g exfat-utils exfatprogs fuse-exfat dosfstools bcachefs-tools
   smartmontools e2fsprogs xfsprogs emacs gcc gcc-toolchain linux-libre-headers
   git git-lfs python python-pip cmake meson binutils strace edk2-tools kitty
   alacritty fish zoxide pfetch sysstat nftables clamav gnupg libfido2 firejail
   privoxy openvpn tor torsocks nmap tcpdump openssl keepassxc htop btop glances
   inxi lm-sensors net-tools fping netdiscover whois macchanger procps coreutils
   grep sed nix alsa-lib alsa-utils pulseaudio pipewire wireplumber
   font-iosevka-term font-iosevka-term-slab font-iosevka-slab font-iosevka-etoile
   font-iosevka-curly font-iosevka-curly-slab font-iosevka-aile
   font-iosevka-ss01 font-iosevka-ss02 font-iosevka-ss03 font-iosevka-ss04
   font-iosevka-ss05 font-iosevka-ss06 font-iosevka-ss07 font-iosevka-ss08
   font-iosevka-ss09 font-iosevka-ss10 font-iosevka-ss11 font-iosevka-ss12
   font-iosevka-ss13 font-iosevka-ss14 font-iosevka-ss15 font-iosevka-ss16
   font-iosevka-ss17 font-iosevka-ss18 font-sarasa-gothic font-aporetic
   font-adwaita)
   (map specification->package '(
EOF

if [[ "$DESKTOP" == "i3" ]]; then
  cat >> /mnt/etc/config.scm <<'EOF'
     i3-wm i3status dmenu sddm
EOF
elif [[ "$DESKTOP" == "mate" ]]; then
  cat >> /mnt/etc/config.scm <<'EOF'
     mate sddm
EOF
elif [[ "$DESKTOP" == "xfce" ]]; then
  cat >> /mnt/etc/config.scm <<'EOF'
     xfce sddm
EOF
elif [[ "$DESKTOP" == "sway" ]]; then
  cat >> /mnt/etc/config.scm <<'EOF'
     sway wayland greetd
EOF
else
  cat >> /mnt/etc/config.scm <<'EOF'
     ;; no extra desktop packages
EOF
fi

cat >> /mnt/etc/config.scm <<'EOF'
   )) %base-packages))
 (services %base-services))
EOF

# -------------------- channels.scm --------------------
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
    (openpgp-fingerprint "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA"))))
 (channel
  (name 'nonguix)
  (url "https://gitlab.com/nonguix/nonguix")
  (introduction
   (make-channel-introduction
    "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
    (openpgp-fingerprint "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5")))))
EOF

# -------------------- Guix init with retries --------------------
if ! guix_available; then
  log "Guix CLI not found; attempting to bootstrap Guix binary"
  bootstrap_guix_binary || log "Bootstrap failed; continuing (may fail later)"
fi

ensure_guix_daemon || log "guix-daemon may not be working; some operations could fail"

ensure_guix_substitute_config || log "Could not write /etc/guix/config.scm substitutes; will use GUIX_SUBSTITUTE_URLS env if available"

usable_list="$(probe_substitutes)"
if [[ -n "$usable_list" ]]; then
  export GUIX_SUBSTITUTE_URLS="$usable_list"
  log "Using GUIX_SUBSTITUTE_URLS: $GUIX_SUBSTITUTE_URLS"
else
  log "No substitutes reachable; building from source may be attempted (slow) and may fail"
fi

run_guix_init_with_retries() {
  if ! command -v guix >/dev/null 2>&1; then err "guix CLI not available; cannot run guix system init"; return 1; fi
  local max_attempts=6
  local attempt=1
  local backoff=5

  if [[ -n "${GUIX_SUBSTITUTE_URLS:-}" ]]; then
    export GUIX_SUBSTITUTE_URLS
  else
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
      journalctl -u guix-daemon --since '5 minutes ago' --no-pager -n 200 | sed -n '1,200p' >&2 || true
    fi
    sleep $backoff
    attempt=$(( attempt + 1 ))
    backoff=$(( backoff * 2 > 60 ? 60 : backoff * 2 ))

    usable="$(probe_substitutes)"
    if [[ -n "$usable" ]]; then
      export GUIX_SUBSTITUTE_URLS="$usable"
      log "Updated GUIX_SUBSTITUTE_URLS to: $GUIX_SUBSTITUTE_URLS"
    fi
  done

  err "guix system init failed after $max_attempts attempts"
  return 1
}

run_guix_init_with_retries || { err "Guix initialization failed; check network, substitute servers, and guix-daemon logs."; die "Installation aborted due to Guix errors"; }

# -------------------- Finish --------------------
sync
umount -R /mnt || true
log "Installation finished. Rebooting in 10 seconds..."
sleep 10
reboot