#!/usr/bin/env bash
set -euo pipefail

#   GNU GUIX - POWERED BY ALIENS
# - Step-based GUI installer flow (Welcome, Disk, Partition, User, Summary, Install, Finish)
# - Uses yad or zenity for GUI; falls back to text-mode dialogs
# - Supports pt-BR / en-US, AUTO_YES and env-driven non-interactive usage
# - Meant to be run from a live environment as root
#
# Usage hints:
#  - Run as root: sudo ./installer.sh
#  - Non-interactive: export AUTO_YES=1 and other vars (TARGET_DISK, USERNAME, USER_PASS, ROOT_PASS, LOCALE, TIMEZONE, DESKTOP, FS_TYPE)
#  - GUI: install yad or zenity in the live image for polished dialogs

# -------------------- Defaults and environment --------------------
LANG_OPT="${LANG_OPT:-auto}"        # auto | en | pt
USE_GUI="${USE_GUI:-auto}"          # auto | gui | text
AUTO_YES="${AUTO_YES:-0}"           # 1 skip confirmations
TARGET_DISK="${TARGET_DISK:-}"      # e.g., /dev/sda
USERNAME="${USERNAME:-}"            # user name
USER_PASS="${USER_PASS:-}"          # user password plaintext (for script use only)
ROOT_PASS="${ROOT_PASS:-}"          # root password plaintext
LOCALE="${LOCALE:-}"                # e.g., en_US.UTF-8 or pt_BR.UTF-8
TIMEZONE="${TIMEZONE:-}"            # e.g., America/Sao_Paulo
DESKTOP="${DESKTOP:-}"              # i3,mate,xfce,sway,none
FS_TYPE="${FS_TYPE:-}"              # ext4,btrfs,xfs
CREATE_HOME="${CREATE_HOME:-}"      # 1=yes 0=no
CREATE_SWAP="${CREATE_SWAP:-}"      # 1=yes 0=no
SWAP_SIZE="${SWAP_SIZE:-4G}"        # swap if requested
GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.4.0}"

# Guix substitute hosts (Guix servers)
SUBSTITUTE_HOSTS=(
  "https://hydra.gnu.org"
  "https://cache.guix.gnu.org"
  "https://ci.guix.info"
  "https://ci.guix.gnu.org"
)

# Full packages list (kept from your prior request)
BASE_PACKAGES=(
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
  font-iosevka-ss17 font-iosevka-ss18 font-sarasa-gothic font-aporetic font-adwaita
)

# -------------------- Localization --------------------
choose_lang() {
  if [[ "$LANG_OPT" == "auto" ]]; then
    term_lang="${LC_ALL:-${LANG:-}}"
    if [[ "$term_lang" =~ ^pt|BR|br ]]; then LANG_OPT="pt"; else LANG_OPT="en"; fi
  fi
  if [[ "$LANG_OPT" == "pt" ]]; then
    L_WELCOME="Bem-vindo ao instalador GNU Guix"
    L_WELCOME_SUB="Instalação fácil e guiada — estilo Calamares"
    L_SELECT_DISK="Selecione o disco alvo"
    L_SELECT_PART="Gerenciar partições (simples)"
    L_USER_SETUP="Configurar usuário e senha"
    L_SUMMARY="Resumo da instalação"
    L_INSTALL="Instalando — aguarde"
    L_FINISH="Instalação concluída"
    L_CANCELLED="Instalação cancelada"
    L_CONFIRM_PHRASE="SIM EU QUERO GUIX"
    L_ABORT_MSG="Abortado pelo usuário"
    L_OK="OK"
    L_CANCEL="Cancelar"
  else
    L_WELCOME="Welcome to the GNU Guix installer"
    L_WELCOME_SUB="Easy guided installation — Calamares-like"
    L_SELECT_DISK="Select target disk"
    L_SELECT_PART="Manage partitions (simple)"
    L_USER_SETUP="Set up user and passwords"
    L_SUMMARY="Installation summary"
    L_INSTALL="Installing — please wait"
    L_FINISH="Installation finished"
    L_CANCELLED="Installation cancelled"
    L_CONFIRM_PHRASE="YES I WANT GUIX"
    L_ABORT_MSG="Aborted by user"
    L_OK="OK"
    L_CANCEL="Cancel"
  fi
}

# -------------------- Helpers --------------------
log() { printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# -------------------- GUI toolkit detection --------------------
detect_gui() {
  GUI_TOOL=""
  if [[ "${USE_GUI}" == "text" ]]; then GUI_TOOL=""; return; fi
  if command -v yad >/dev/null 2>&1; then GUI_TOOL="yad"; return; fi
  if command -v zenity >/dev/null 2>&1; then GUI_TOOL="zenity"; return; fi
  GUI_TOOL=""
}
gui_yesno() {
  local title="$1" prompt="$2"
  if [[ -n "$GUI_TOOL" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then
      yad --center --title "$title" --question --text "$prompt" --button="$L_CANCEL":1 --button="$L_OK":0 >/dev/null 2>&1
      return $?
    else
      zenity --question --title="$title" --text="$prompt" >/dev/null 2>&1
      return $?
    fi
  fi
  # text fallback
  if [[ "${AUTO_YES:-0}" -eq 1 ]]; then return 0; fi
  while true; do
    read -r -p "$prompt [y/N]: " ans
    case "$ans" in
      [YySs]* ) return 0 ;;
      [Nn]* ) return 1 ;;
      *) echo "Please answer yes/no" ;;
    esac
  done
}
gui_entry() {
  local title="$1" prompt="$2" default="$3"
  if [[ -n "$GUI_TOOL" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then
      yad --title "$title" --entry --text "$prompt" --entry-text "$default" 2>/dev/null || echo "$default"
    else
      zenity --entry --title="$title" --text="$prompt" --entry-text="$default" 2>/dev/null || echo "$default"
    fi
  else
    if [[ "${AUTO_YES:-0}" -eq 1 ]]; then echo "$default"; else read -r -p "$prompt [$default]: " v; echo "${v:-$default}"; fi
  fi
}
gui_list() {
  local title="$1" prompt="$2" choices=("${@:3}")
  if [[ -n "$GUI_TOOL" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then
      printf "%s\n" "${choices[@]}" | yad --list --title "$title" --column "$prompt" --height=250 --width=300 2>/dev/null | head -n1
    else
      printf "%s\n" "${choices[@]}" | zenity --list --title="$title" --column="$prompt" --height=250 --width=300 2>/dev/null | head -n1
    fi
  else
    echo "${choices[0]}"
  fi
}
gui_info() {
  local title="$1" msg="$2"
  if [[ -n "$GUI_TOOL" ]]; then
    if [[ "$GUI_TOOL" == "yad" ]]; then yad --title "$title" --info --text "$msg" --buttons=OK:0 --timeout=3 >/dev/null 2>&1 || true
    else zenity --info --title="$title" --text "$msg" --timeout=3 >/dev/null 2>&1 || true; fi
  else
    echo "$msg"
  fi
}
gui_progress_start() {
  # For yad: create pipe; for zenity: background output with --progress --auto-close
  if [[ "$GUI_TOOL" == "yad" ]]; then
    PROG_PIPE="$(mktemp -u)"
    mkfifo "$PROG_PIPE"
    yad --title "$L_INSTALL" --progress --pulsate --auto-close < "$PROG_PIPE" &
    PROG_PID=$!
    echo "$PROG_PID" > /tmp/guix_installer_progid
    exec 3> "$PROG_PIPE"
  elif [[ "$GUI_TOOL" == "zenity" ]]; then
    ( while true; do echo "# $1"; sleep 1; done ) | zenity --progress --title="$L_INSTALL" --auto-close >/dev/null 2>&1 &
    PROG_PID=$!
  else
    echo "$L_INSTALL"
  fi
}
gui_progress_set() {
  local pct="${1:-}"
  if [[ "$GUI_TOOL" == "yad" ]]; then
    printf "%s\n" "$pct" >&3 || true
  elif [[ "$GUI_TOOL" == "zenity" ]]; then
    echo "$pct"
  else
    :
  fi
}
gui_progress_stop() {
  if [[ "$GUI_TOOL" == "yad" ]]; then
    exec 3>&- || true
    sleep 1
    kill "${PROG_PID:-0}" 2>/dev/null || true
    rm -f /tmp/guix_installer_progid || true
  elif [[ "$GUI_TOOL" == "zenity" ]]; then
    kill "${PROG_PID:-0}" 2>/dev/null || true
  fi
}

# -------------------- Preconditions --------------------
choose_lang
detect_gui

if [[ "$(id -u)" -ne 0 ]]; then die "Run this as root"; fi
log "Starting Calamares-like installer"

# Attempt to install GUI tools if user wants GUI and package manager exists
if [[ -n "$GUI_TOOL" && -n "$PKG" ]]; then
  case "$PKG" in
    apt) apt update && apt install -y yad zenity >/dev/null 2>&1 || true ;;
    dnf) dnf install -y yad zenity >/dev/null 2>&1 || true ;;
    pacman) pacman -Sy --noconfirm yad zenity >/dev/null 2>&1 || true ;;
  esac
fi

# -------------------- UI Steps --------------------
step_welcome() {
  gui_info "$L_WELCOME" "$L_WELCOME_SUB"
}

step_select_disk() {
  # detect available disks for user convenience
  mapfile -t disks < <(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk" {print "/dev/"$1" ("$2")"}')
  if [[ ${#disks[@]} -eq 0 ]]; then die "No block devices found"; fi

  if [[ -z "$TARGET_DISK" ]]; then
    choice="$(gui_list "$L_SELECT_DISK" "$L_SELECT_DISK" "${disks[@]}")"
    if [[ -z "$choice" ]]; then
      die "$L_ABORT_MSG"
    fi
    # extract /dev/XXX
    TARGET_DISK="$(echo "$choice" | awk '{print $1}')"
  fi

  # quick confirm
  gui_info "$L_SELECT_DISK" "Target: $TARGET_DISK"
}

step_partition_options() {
  # offer simple partition options: Guided (use whole disk), Manual (open parted), Cancel
  if ! gui_yesno "$L_SELECT_PART" "Use guided partitioning (whole disk, creates EFI/root[/home[/swap]])?"; then
    if gui_yesno "$L_SELECT_PART" "Open parted in a terminal for manual partitioning?"; then
      xterm -e "parted --script $TARGET_DISK unit MiB print; echo 'Run parted commands then close this window'; bash" >/dev/null 2>&1 || true
      gui_info "$L_SELECT_PART" "Resuming installer after manual partitioning"
    else
      die "$L_ABORT_MSG"
    fi
  else
    # gather guided partition choices
    if [[ -z "$FS_TYPE" ]]; then
      FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" "ext4" "btrfs" "xfs")"
    fi
    if [[ -z "${CREATE_HOME}" ]]; then
      if gui_yesno "Home partition" "Create separate /home partition?"; then CREATE_HOME=1; else CREATE_HOME=0; fi
    fi
    if [[ -z "${CREATE_SWAP}" ]]; then
      if gui_yesno "Swap" "Create swap partition?"; then CREATE_SWAP=1; else CREATE_SWAP=0; fi
    fi

    # Partition automatically (similar to earlier logic)
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
      if (( swap_mib >= remaining_mib )); then swap_mib=$(( remaining_mib/10 )); fi
      remaining_mib=$(( remaining_mib - swap_mib ))
    fi

    if [[ "$CREATE_HOME" -eq 1 && "$CREATE_SWAP" -eq 1 ]]; then
      root_mib=$(( remaining_mib / 2 ))
      home_mib=$(( remaining_mib - root_mib ))
      start_mib=$used_mib; end_mib=$(( start_mib + root_mib ))
      parted --script --align optimal "$TARGET_DISK" mkpart primary "${start_mib}MiB" "${end_mib}MiB"
      parted --script --align optimal "$TARGET_DISK" mkpart primary "${end_mib}MiB" 100%
      if (( swap_mib > 0 )); then
        parted --script --align optimal "$TARGET_DISK" mkpart primary 100% -${swap_mib}MiB
      fi
    elif [[ "$CREATE_HOME" -eq 1 ]]; then
      root_mib=$(( remaining_mib / 2 ))
      home_mib=$(( remaining_mib - root_mib ))
      start_mib=$used_mib; end_mib=$(( start_mib + root_mib ))
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
    gui_info "$L_SELECT_PART" "Guided partitioning done"
  fi
}

# helper: to_mib reused
to_mib(){ local s="$1"; if [[ "$s" =~ ^([0-9]+)[Gg]$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 )); elif [[ "$s" =~ ^([0-9]+)[Mm]$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$s"; fi; }

step_user_setup() {
  if [[ -z "$USERNAME" ]]; then
    USERNAME="$(gui_entry "$L_USER_SETUP" "Choose a username" "user")"
  fi
  if [[ -z "$USER_PASS" ]]; then
    USER_PASS="$(gui_entry "$L_USER_SETUP" "Choose a password for $USERNAME" "guixpass")"
  fi
  if [[ -z "$ROOT_PASS" ]]; then
    ROOT_PASS="$(gui_entry "$L_USER_SETUP" "Choose root password" "rootpass")"
  fi
  if [[ -z "$LOCALE" ]]; then
    LOCALE="$(gui_list "Locale" "Choose locale" "en_US.UTF-8" "pt_BR.UTF-8")"
  fi
  if [[ -z "$TIMEZONE" ]]; then
    TIMEZONE="$(gui_entry "Timezone" "Timezone (Region/City)" "America/Sao_Paulo")"
  fi
  if [[ -z "$DESKTOP" ]]; then
    DESKTOP="$(gui_list "Desktop" "Choose desktop" "i3" "mate" "xfce" "sway" "none")"
  fi
  if [[ -z "$FS_TYPE" ]]; then
    FS_TYPE="$(gui_list "Filesystem" "Choose filesystem" "ext4" "btrfs" "xfs")"
  fi
}

step_summary() {
  summary="Disk: $TARGET_DISK\nUser: $USERNAME\nDesktop: $DESKTOP\nFS: $FS_TYPE\nLocale: $LOCALE\nTimezone: $TIMEZONE\nCreate /home: ${CREATE_HOME:-auto}\nCreate swap: ${CREATE_SWAP:-auto}"
  gui_info "$L_SUMMARY" "$summary"
  if [[ "${AUTO_YES:-0}" -eq 0 ]]; then
    if ! gui_yesno "$L_SUMMARY" "Proceed with installation?"; then die "$L_ABORT_MSG"; fi
  fi
}

# Partition discovery (resolve created partitions)
discover_parts() {
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
    EFI_PART="${parts[0]:-}"
    # subsequent mapping heuristics
    if [[ "${#parts[@]}" -ge 4 && "$CREATE_HOME" -eq 1 && "$CREATE_SWAP" -eq 1 ]]; then
      ROOT_PART="${parts[1]}"; HOME_PART="${parts[2]}"; SWAP_PART="${parts[3]}"
    elif [[ "${#parts[@]}" -ge 3 && "$CREATE_HOME" -eq 1 ]]; then
      ROOT_PART="${parts[1]}"; HOME_PART="${parts[2]}"
    else
      ROOT_PART="${parts[1]:-}"
    fi
  else
    if [[ "${#parts[@]}" -ge 3 && "$CREATE_HOME" -eq 1 && "$CREATE_SWAP" -eq 1 ]]; then
      ROOT_PART="${parts[0]}"; HOME_PART="${parts[1]}"; SWAP_PART="${parts[2]}"
    elif [[ "${#parts[@]}" -ge 2 && "$CREATE_HOME" -eq 1 ]]; then
      ROOT_PART="${parts[0]}"; HOME_PART="${parts[1]}"
    else
      ROOT_PART="${parts[0]:-}"
    fi
  fi
}

step_install() {
  discover_parts
  [[ -n "$ROOT_PART" ]] || die "Root partition not found"

  # Format partitions
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
      *) mkfs.ext4 -F "$HOME_PART" ;;
    esac
  fi
  if [[ -n "$SWAP_PART" && -b "$SWAP_PART" ]]; then mkswap "$SWAP_PART"; fi

  # Mount
  mkdir -p /mnt
  mount "$ROOT_PART" /mnt
  if [[ -n "$EFI_PART" ]]; then mkdir -p /mnt/boot/efi; mount "$EFI_PART" /mnt/boot/efi; fi
  if [[ -n "$HOME_PART" ]]; then mkdir -p /mnt/home; mount "$HOME_PART" /mnt/home; fi

  # Hash passwords
  huser="$(openssl passwd -6 -- "$USER_PASS")"
  hroot="$(openssl passwd -6 -- "$ROOT_PASS")"

  # UUIDs
  root_uuid="$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)"
  home_uuid="$(blkid -s UUID -o value "$HOME_PART" 2>/dev/null || true)"
  efi_uuid="$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null || true)"

  # Write config.scm
  mkdir -p /mnt/etc
  cat > /mnt/etc/config.scm <<EOF
(use-modules (gnu) (guix) (guix profiles) (gnu services)
             (gnu packages base) (gnu packages linux) (gnu packages gl)
             (gnu packages package-management) (gnu packages admin)
             (gnu packages file-systems) (gnu packages terminals)
             (gnu packages python) (gnu packages xorg) (gnu services desktop)
             (gnu packages tls) (gnu packages gnupg) (gnu packages fonts)
             (gnu packages image-viewers) (gnu packages vpn) (nongnu packages linux))

(operating-system
 (host-name "${HOSTNAME}")
 (timezone "${TIMEZONE}")
 (locale "${LOCALE}")
 (keyboard-layout (keyboard-layout "${KEYBOARD}")))
EOF

  # append bootloader stanza
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
 (users (cons* (user-account (name "${USERNAME}") (group "users")
                             (home (string-append "/home/" "${USERNAME}"))
                             (password "${huser}")
                             (supplementary-groups '("wheel" "netdev" "audio" "networking" "video")))
               (map (lambda (u) (if (string=? (user-account-name u) "root")
                                   (user-account (inherit u) (password "${hroot}"))
                                   u)) %base-user-accounts)))
EOF

  # packages and desktop-specific extras
  cat >> /mnt/etc/config.scm <<'EOF'
 (packages (append (list
EOF

  for p in "${BASE_PACKAGES[@]}"; do
    echo "   $p" >> /mnt/etc/config.scm
  done

  # desktop extras:
  case "$DESKTOP" in
    i3) echo "   i3-wm i3status dmenu sddm" >> /mnt/etc/config.scm ;;
    mate) echo "   mate sddm" >> /mnt/etc/config.scm ;;
    xfce) echo "   xfce sddm" >> /mnt/etc/config.scm ;;
    sway) echo "   sway wayland greetd" >> /mnt/etc/config.scm ;;
    *) echo "   ;; no extra desktop packages" >> /mnt/etc/config.scm ;;
  esac

  cat >> /mnt/etc/config.scm <<'EOF'
   ) %base-packages))
 (services %base-services))
EOF

  # channels.scm
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

  # Ensure guix installed (best-effort)
  if ! command -v guix >/dev/null 2>&1; then
    log "Attempting to bootstrap Guix binary"
    bootstrap_guix_binary || log "Bootstrap failed; continuing"
  fi

  # Ensure guix-daemon
  ensure_guix_daemon || log "guix-daemon may not be active"

  # Write substitutes
  ensure_guix_substitute_config || log "Could not write substitutes; proceed with GUIX_SUBSTITUTE_URLS if set"

  # Try to run guix system init with retries
  gui_progress_start
  run_guix_init_with_retries || { gui_progress_stop; die "Guix system init failed"; }
  gui_progress_stop

  gui_info "$L_FINISH" "Installation seems complete. System will reboot shortly."
}

# -------------------- Supporting guix functions --------------------
bootstrap_guix_binary() {
  ARCH="$(uname -m)"
  case "$ARCH" in x86_64) BIN="guix-binary-${GUIX_BINARY_VERSION}.x86_64-linux.tar.xz" ;; aarch64) BIN="guix-binary-${GUIX_BINARY_VERSION}.aarch64-linux.tar.xz" ;; i686) BIN="guix-binary-${GUIX_BINARY_VERSION}.i686-linux.tar.xz" ;; *) BIN="" ;; esac
  if [[ -z "$BIN" ]]; then return 1; fi
  MIRRORS=( "https://ftp.gnu.org/gnu/guix/$BIN" "https://mirror.csclub.uwaterloo.ca/gnu/guix/$BIN" "https://mirror0.nexcess.net/gnu/guix/$BIN" )
  for url in "${MIRRORS[@]}"; do
    if curl -fsSL --connect-timeout 8 -o "/tmp/$BIN" "$url"; then
      tar -xJf "/tmp/$BIN" -C / || return 1
      rm -f "/tmp/$BIN"
      return 0
    fi
  done
  return 1
}

ensure_guix_daemon() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --full -all | grep -q guix-daemon; then
    systemctl restart guix-daemon >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet guix-daemon; then return 0; fi
    return 1
  fi
  if command -v guix-daemon >/dev/null 2>&1; then
    setsid guix-daemon --build-users-group=guixbuild >/var/log/guix-daemon.log 2>&1 & sleep 2
    pgrep -a guix-daemon >/dev/null 2>&1 && return 0
  fi
  return 1
}

probe_substitutes() {
  local usable=()
  for url in "${SUBSTITUTE_HOSTS[@]}"; do
    if curl -fsS --max-time 6 -I "$url" >/dev/null 2>&1; then usable+=("$url"); fi
  done
  printf '%s' "${usable[*]}"
}

ensure_guix_substitute_config() {
  local cfg="/etc/guix/config.scm"
  if [[ ! -f "$cfg" ]]; then echo ";; Minimal Guix substitute configuration" > "$cfg"; fi
  usable="$(probe_substitutes)"
  if [[ -z "$usable" ]]; then return 1; fi
  tmp="$(mktemp)"
  echo ";; Auto-generated substitute-urls (operating-mode 'daemon)" > "$tmp"
  echo "(substitute-urls (list" >> "$tmp"
  for u in $usable; do echo " \"$u\"" >> "$tmp"; done
  echo "))" >> "$tmp"
  mv "$tmp" "$cfg"
  return 0
}

run_guix_init_with_retries() {
  if ! command -v guix >/dev/null 2>&1; then log "guix CLI not available"; return 1; fi
  local max_attempts=6 attempt=1 backoff=5 usable
  if [[ -n "${GUIX_SUBSTITUTE_URLS:-}" ]]; then export GUIX_SUBSTITUTE_URLS; else export GUIX_SUBSTITUTE_URLS="$(probe_substitutes)"; fi
  while (( attempt <= max_attempts )); do
    log "Attempt $attempt: guix system init (GUIX_SUBSTITUTE_URLS=${GUIX_SUBSTITUTE_URLS})"
    if guix time-machine -C /mnt/etc/channels.scm -- system init /mnt/etc/config.scm /mnt --verbose; then return 0; fi
    sleep $backoff
    attempt=$((attempt+1))
    backoff=$(( backoff * 2 > 60 ? 60 : backoff * 2 ))
    usable="$(probe_substitutes)" && [[ -n "$usable" ]] && export GUIX_SUBSTITUTE_URLS="$usable"
  done
  return 1
}

# -------------------- Orchestration --------------------
main() {
  step_welcome
  step_select_disk
  step_partition_options
  step_user_setup
  step_summary
  step_install
  # finish: unmount & reboot
  sync
  umount -R /mnt || true
  gui_info "$L_FINISH" "Rebooting now..."
  sleep 5
  reboot
}

main "$@"