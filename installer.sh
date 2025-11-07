# IN CODE WE TRUST.
#!/usr/bin/env bash
set -euo pipefail

# GNU EASY INSTALLER - POWERED BY ALIENS
# Calamares-like GNU Guix installer
# - Keeps guided partitioning, GUI/text dialogs, config.scm/channels.scm generation
# - Meant to run from a live environment as root
#
# Usage: sudo ./install.sh
# Non-interactive: export AUTO_YES=1 and other vars (TARGET_DISK, USERNAME, USER_PASS, ROOT_PASS, LOCALE, TIMEZONE, DESKTOP, FS_TYPE)

# -------------------- Defaults / env (safe defaults for all variables) --------------------
LANG_OPT="${LANG_OPT:-auto}"        # auto | en | pt
USE_GUI="${USE_GUI:-auto}"          # auto | gui | text
AUTO_YES="${AUTO_YES:-0}"           # 1 skip confirmations
TARGET_DISK="${TARGET_DISK:-}"      # e.g., /dev/sda
USERNAME="${USERNAME:-}"            # user name
USER_PASS="${USER_PASS:-}"          # user password plaintext (for script use only)
ROOT_PASS="${ROOT_PASS:-}"          # root password plaintext
LOCALE="${LOCALE:-en_US.UTF-8}"     # e.g., en_US.UTF-8 or pt_BR.UTF-8
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
DESKTOP="${DESKTOP:-none}"          # i3,mate,xfce,sway,none
FS_TYPE="${FS_TYPE:-ext4}"          # ext4,btrfs,xfs
CREATE_HOME="${CREATE_HOME:-}"      # 1=yes 0=no
CREATE_SWAP="${CREATE_SWAP:-}"      # 1=yes 0=no
SWAP_SIZE="${SWAP_SIZE:-4G}"        # swap size
GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.4.0}"
KEYBOARD="${KEYBOARD:-us}"          # keyboard layout default to 'us'

SUBSTITUTE_HOSTS=( "https://hydra.gnu.org" "https://cache.guix.gnu.org" "https://ci.guix.info" "https://ci.guix.gnu.org" )
BASE_PACKAGES=(icecat torbrowser libreoffice mpv feh util-linux xterm git python)

# -------------------- Localization --------------------
choose_lang() {
  if [[ "$LANG_OPT" == "auto" ]]; then
    term_lang="${LC_ALL:-${LANG:-}}"
    if [[ "$term_lang" =~ ^pt|BR|br ]]; then LANG_OPT="pt"; else LANG_OPT="en"; fi
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
  fi
}

# -------------------- Helpers --------------------
log(){ printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }
die(){ log "ERROR: $*" >&2; exit 1; }

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
gui_yesno() {
  local title="$1" prompt="$2"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then yad --center --title "$title" --question --text "$prompt" --button="$L_CANCEL":1 --button="$L_OK":0 >/dev/null 2>&1; return $?
    else zenity --question --title="$title" --text="$prompt" >/dev/null 2>&1; return $?; fi
  fi
  if [[ "${AUTO_YES:-0}" -eq 1 ]]; then return 0; fi
  while true; do
    read -r -p "$prompt [y/N]: " ans
    case "$ans" in [YySs]* ) return 0 ;; [Nn]* ) return 1 ;; * ) echo "$L_PLEASE" ;; esac
  done
}
gui_entry() {
  local title="$1" prompt="$2" default="$3"
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then yad --title "$title" --entry --text "$prompt" --entry-text "$default" 2>/dev/null || echo "$default"
    else zenity --entry --title="$title" --text "$prompt" --entry-text "$default" 2>/dev/null || echo "$default"; fi
  else
    if [[ "${AUTO_YES:-0}" -eq 1 ]]; then echo "$default"; else read -r -p "$prompt [$default]: " v; echo "${v:-$default}"; fi
  fi
}
gui_list() {
  local title="$1" prompt="$2" choices=("${@:3}")
  if [[ -n "${GUI_TOOL:-}" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then printf "%s\n" "${choices[@]}" | yad --list --title "$title" --column "$prompt" --height=200 --width=300 2>/dev/null | head -n1
    else printf "%s\n" "${choices[@]}" | zenity --list --title="$title" --column="$prompt" --height=200 --width=300 2>/dev/null | head -n1; fi
  else
    echo "${choices[0]}"
  fi
}
gui_info(){ local t="$1" m="$2"; if [[ -n "${GUI_TOOL:-}" ]]; then if [[ "$GUI_TOOL" == "yad" ]]; then yad --title "$t" --info --text "$m" --timeout=3 >/dev/null 2>&1; else zenity --info --title="$t" --text "$m" --timeout=3 >/dev/null 2>&1; fi; else echo "$m"; fi; }

# -------------------- Pre-flight --------------------
choose_lang
detect_gui

if [[ "$(id -u)" -ne 0 ]]; then die "Run as root"; fi
log "Starting installer"

# -------------------- UI Steps --------------------
step_welcome(){ gui_info "$L_WELCOME" "$L_WELCOME_SUB"; }

step_select_disk(){
  mapfile -t disks < <(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk" {printf "/dev/%s (%s)\n",$1,$2}')
  [[ ${#disks[@]} -gt 0 ]] || die "No disks found"
  if [[ -z "$TARGET_DISK" ]]; then
    choice="$(gui_list "$L_SELECT_DISK" "$L_SELECT_DISK" "${disks[@]}")"
    [[ -n "$choice" ]] || die "$L_ABORT_MSG"
    TARGET_DISK="$(echo "$choice" | awk '{print $1}')"
  fi
  gui_info "$L_SELECT_DISK" "Target: $TARGET_DISK"
}

# safe parted mkpart using explicit MiB ranges
safe_mkpart() {
  local disk="$1" start_mib="$2" end_mib="$3"
  # ensure end_mib > start_mib + 1
  if (( end_mib <= start_mib + 1 )); then
    die "Calculated partition range invalid: ${start_mib}MiB - ${end_mib}MiB"
  fi
  parted --script --align optimal "$disk" mkpart primary "${start_mib}MiB" "${end_mib}MiB"
}

to_mib(){ local s="$1"; if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 )); elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$s"; fi; }

step_partition_options(){
  if ! gui_yesno "$L_SELECT_PART" "Use guided partitioning (whole disk)?"; then
    if gui_yesno "$L_SELECT_PART" "Open parted in a terminal for manual partitioning now?"; then
      (which xterm >/dev/null 2>&1 && xterm -e "parted --script $TARGET_DISK unit MiB print; echo 'When done, close this window' ; bash") || bash -c "parted --script $TARGET_DISK unit MiB print; echo 'When done, return to installer'; bash"
      gui_info "$L_SELECT_PART" "Resuming"
    else
      die "$L_ABORT_MSG"
    fi
    return
  fi

  if [[ -z "$FS_TYPE" ]]; then FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" "ext4" "btrfs" "xfs")"; fi
  if [[ -z "${CREATE_HOME}" ]]; then gui_yesno "Home" "Create separate /home partition?" && CREATE_HOME=1 || CREATE_HOME=0; fi
  if [[ -z "${CREATE_SWAP}" ]]; then gui_yesno "Swap" "Create swap partition?" && CREATE_SWAP=1 || CREATE_SWAP=0; fi

  # Disk size and safe calculations
  total_mib=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1024 / 1024 ))
  if (( total_mib < 10 )); then die "Disk too small"; fi
  efi_mib=512
  used_mib=1

  if [[ -d /sys/firmware/efi ]]; then
    parted --script "$TARGET_DISK" mklabel gpt
    # create small EFI partition from 1MiB to efi_mib
    parted --script --align optimal "$TARGET_DISK" mkpart primary 1MiB "${efi_mib}MiB"
    parted --script "$TARGET_DISK" set 1 esp on
    used_mib=$efi_mib
  else
    parted --script "$TARGET_DISK" mklabel msdos
    used_mib=1
  fi

  remaining_mib=$(( total_mib - used_mib ))
  if (( remaining_mib <= 4 )); then die "Not enough usable space on disk"; fi

  # swap in MiB
  if (( CREATE_SWAP == 1 )); then
    swap_mib=$(to_mib "$SWAP_SIZE")
    if (( swap_mib < 4 )); then swap_mib=4; fi
    if (( swap_mib > remaining_mib - 2 )); then
      # leave at least 2 MiB for root; scale down swap
      swap_mib=$(( (remaining_mib - 2) / 10 ))
      (( swap_mib < 4 )) && swap_mib=0
    fi
  else
    swap_mib=0
  fi

  usable_mib=$(( remaining_mib - swap_mib ))
  if (( usable_mib <= 2 )); then die "Not enough space for root/home after reserving swap"; fi

  # Determine partitions with strict bounds:
  # root first, then home (if chosen), swap last (if chosen).
  root_start=$used_mib
  if (( CREATE_HOME == 1 )); then
    root_mib=$(( usable_mib / 2 ))
    home_mib=$(( usable_mib - root_mib ))
    root_end=$(( root_start + root_mib ))
    home_start=$root_end
    home_end=$(( home_start + home_mib ))
    swap_start=$home_end
    swap_end=$(( swap_start + swap_mib ))
  else
    root_end=$(( root_start + usable_mib ))
    swap_start=$root_end
    swap_end=$(( swap_start + swap_mib ))
  fi

  # Cap any end to total_mib - 1 (leave tiny slack)
  cap_end() {
    local v="$1"
    local t="$2"
    if (( v > t - 1 )); then v=$(( t - 1 )); fi
    echo "$v"
  }
  root_end=$(cap_end "$root_end" "$total_mib")
  if [[ -n "${home_end:-}" ]]; then home_end=$(cap_end "$home_end" "$total_mib"); fi
  if (( swap_mib > 0 )); then swap_end=$(cap_end "$swap_end" "$total_mib"); fi

  # Validate non-overlap and minimum sizes (>=4 MiB)
  if (( root_end <= root_start + 3 )); then die "Root partition too small"; fi
  if [[ -n "${home_start:-}" ]]; then
    if (( home_end <= home_start + 3 )); then die "Home partition too small"; fi
  fi
  if (( swap_mib > 0 )); then
    if (( swap_end <= swap_start + 3 )); then
      # try to reduce swap to available tail
      swap_start=$(( total_mib - 5 ))
      swap_end=$(( total_mib - 1 ))
      if (( swap_end <= swap_start )); then swap_mib=0; fi
    fi
  fi

  # Create partitions
  safe_mkpart "$TARGET_DISK" "$root_start" "$root_end"
  if [[ -n "${home_start:-}" && -n "${home_end:-}" ]]; then
    safe_mkpart "$TARGET_DISK" "$home_start" "$home_end"
  fi
  if (( swap_mib > 0 )); then
    # final cap again
    swap_end=$(cap_end "$swap_end" "$total_mib")
    if (( swap_end > swap_start )); then
      safe_mkpart "$TARGET_DISK" "$swap_start" "$swap_end"
    fi
  fi

  partprobe "$TARGET_DISK" || true
  udevadm settle --timeout=10 || true
  sleep 1
  gui_info "$L_SELECT_PART" "Guided partitioning completed"
}

step_user_setup(){
  if [[ -z "$USERNAME" ]]; then USERNAME="$(gui_entry "$L_USER_SETUP" "Choose a username" "user")"; fi
  if [[ -z "$USER_PASS" ]]; then USER_PASS="$(gui_entry "$L_USER_SETUP" "Choose password for $USERNAME" "guixpass")"; fi
  if [[ -z "$ROOT_PASS" ]]; then ROOT_PASS="$(gui_entry "$L_USER_SETUP" "Choose root password" "rootpass")"; fi
  if [[ -z "$LOCALE" ]]; then LOCALE="$(gui_list "Locale" "Choose locale" "en_US.UTF-8" "pt_BR.UTF-8")"; fi
  if [[ -z "$TIMEZONE" ]]; then TIMEZONE="$(gui_entry "Timezone" "Region/City" "America/Sao_Paulo")"; fi
  if [[ -z "$DESKTOP" ]]; then DESKTOP="$(gui_list "Desktop" "Choose desktop" "i3" "mate" "xfce" "sway" "none")"; fi
  if [[ -z "$FS_TYPE" ]]; then FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" "ext4" "btrfs" "xfs")"; fi
  # ensure KEYBOARD variable is set (fixes previously reported unbound error)
  KEYBOARD="${KEYBOARD:-us}"
}

step_summary(){
  summary="Disk: $TARGET_DISK
User: $USERNAME
Desktop: $DESKTOP
FS: $FS_TYPE
Locale: $LOCALE
Timezone: $TIMEZONE
Keyboard: $KEYBOARD
Create /home: ${CREATE_HOME:-auto}
Create swap: ${CREATE_SWAP:-auto}"
  gui_info "$L_SUMMARY" "$summary"
  if [[ "${AUTO_YES:-0}" -eq 0 ]]; then gui_yesno "$L_SUMMARY" "Proceed with installation?" || die "$L_ABORT_MSG"; fi
}

discover_parts(){
  partprobe "$TARGET_DISK" || true
  udevadm settle --timeout=10 || true
  sleep 1
  parts=()
  for idx in 1 2 3 4 5 6; do
    if [[ -b "${TARGET_DISK}${idx}" ]]; then parts+=("${TARGET_DISK}${idx}")
    elif [[ -b "${TARGET_DISK}p${idx}" ]]; then parts+=("${TARGET_DISK}p${idx}"); fi
  done
  EFI_PART=""; ROOT_PART=""; HOME_PART=""; SWAP_PART=""
  if [[ -d /sys/firmware/efi ]]; then
    EFI_PART="${parts[0]:-}"; ROOT_PART="${parts[1]:-}"; HOME_PART="${parts[2]:-}"; SWAP_PART="${parts[3]:-}"
  else
    ROOT_PART="${parts[0]:-}"; HOME_PART="${parts[1]:-}"; SWAP_PART="${parts[2]:-}"
  fi
}

step_install(){
  discover_parts
  [[ -n "$ROOT_PART" ]] || die "Root partition not found"

  # format partitions
  if [[ -n "$EFI_PART" && -b "$EFI_PART" ]]; then mkfs.vfat -F32 "$EFI_PART"; fi
  case "$FS_TYPE" in
    ext4) mkfs.ext4 -F "$ROOT_PART" ;;
    btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
    xfs) mkfs.xfs -f "$ROOT_PART" ;;
    *) mkfs.ext4 -F "$ROOT_PART" ;;
  esac
  if [[ -n "$HOME_PART" && -b "$HOME_PART" ]]; then
    case "$FS_TYPE" in ext4) mkfs.ext4 -F "$HOME_PART" ;; btrfs) mkfs.btrfs -f "$HOME_PART" ;; xfs) mkfs.xfs -f "$HOME_PART" ;; esac
  fi
  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then mkswap "$SWAP_PART"; fi

  # mount
  mkdir -p /mnt
  mount "$ROOT_PART" /mnt
  if [[ -n "$EFI_PART" ]]; then mkdir -p /mnt/boot/efi; mount "$EFI_PART" /mnt/boot/efi; fi
  if [[ -n "$HOME_PART" ]]; then mkdir -p /mnt/home; mount "$HOME_PART" /mnt/home; fi

  # hash passwords
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

  # try to bootstrap guix cli if missing
  if ! command -v guix >/dev/null 2>&1; then
    log "Guix CLI not found; attempting lightweight bootstrap (best-effort)"
    ARCH="$(uname -m)"
    case "$ARCH" in x86_64) BIN="guix-binary-${GUIX_BINARY_VERSION}.x86_64-linux.tar.xz" ;; aarch64) BIN="guix-binary-${GUIX_BINARY_VERSION}.aarch64-linux.tar.xz" ;; i686) BIN="guix-binary-${GUIX_BINARY_VERSION}.i686-linux.tar.xz" ;; *) BIN="" ;; esac
    if [[ -n "$BIN" ]]; then
      for m in "https://ftp.gnu.org/gnu/guix/$BIN" "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN"; do
        if curl -fsSL --connect-timeout 8 -o "/tmp/$BIN" "$m"; then tar -xJf "/tmp/$BIN" -C / || true; rm -f "/tmp/$BIN"; break; fi
      done
    fi
  fi

  # start or ensure guix-daemon
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --full -all | grep -q guix-daemon; then systemctl restart guix-daemon >/dev/null 2>&1 || true; sleep 1; fi
  if ! pgrep -f guix-daemon >/dev/null 2>&1 && command -v guix-daemon >/dev/null 2>&1; then setsid guix-daemon --build-users-group=guixbuild >/var/log/guix-daemon.log 2>&1 & sleep 2; fi

  # substitutes best-effort
  usable_subs=""
  for u in "${SUBSTITUTE_HOSTS[@]}"; do
    if curl -fsS --max-time 4 -I "$u" >/dev/null 2>&1; then usable_subs="${usable_subs} $u"; fi
  done
  if [[ -n "$usable_subs" ]]; then export GUIX_SUBSTITUTE_URLS="${usable_subs}"; fi

  # run guix system init if available
  if command -v guix >/dev/null 2>&1; then
    attempts=0
    while (( attempts < 4 )); do
      if guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt --no-build-output; then break; fi
      attempts=$((attempts+1)); sleep $((5 * attempts))
    done
    if (( attempts >= 4 )); then die "guix system init failed"; fi
  else
    log "guix CLI unavailable; skip system init"
  fi

  gui_info "$L_FINISH" "Installation completed (best-effort)."
}

# Orchestration
main(){
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