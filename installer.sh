#!/usr/bin/env bash
# WARNING: Running with LUKS or disk formatting will destroy data. Test in VM first.

set -euo pipefail
IFS=$'\n\t'

# ------------------------
# Defaults
# ------------------------
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_KEYMAP="us"
DEFAULT_LANG="en_US"
TMPDIR="${TMPDIR:-/tmp}"
GUI_CMD=""
DESTRUCTIVE_ACTIONS=()

# ------------------------
# Utility functions
# ------------------------
info() { printf '\n[INFO] %s\n' "$*"; }
error() { printf '\n[ERROR] %s\n' "$*" >&2; }
fatal() { error "$*"; exit 1; }

prompt_confirm() {
  local msg=${1:-"Proceed?"}
  if [[ -n "$GUI_CMD" ]]; then
    if [[ "$GUI_CMD" == "zenity" ]]; then
      zenity --question --text="$msg" || return 1
    elif [[ "$GUI_CMD" == "yad" ]]; then
      yad --center --button=gtk-yes:0 --button=gtk-no:1 --text="$msg" || return 1
    else
      dialog --yesno "$msg" 10 60 || return 1
    fi
  else
    read -r -p "$msg [y/N]: " yn
    case "$yn" in [Yy]*) return 0 ;; *) return 1 ;; esac
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return 0; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return 0; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return 0; fi
  echo "unknown"
}

install_packages() {
  local pkgs=("$@")
  local mgr
  mgr=$(detect_pkg_mgr)
  info "Detected package manager: $mgr"
  case "$mgr" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    unknown)
      error "Unknown package manager. Please install: ${pkgs[*]} manually."
      return 1
      ;;
  esac
}

ensure_command() {
  local cmd=$1; shift || true
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ $# -gt 0 ]]; then
      info "Attempting to install host packages required for: $cmd -> $*"
      install_packages "$@" || true
    fi
  fi
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fatal "Required command '$cmd' not available. Install it and re-run."
  fi
}

# ------------------------
# GUI detection & helpers
# ------------------------
detect_gui() {
  if command -v zenity >/dev/null 2>&1; then GUI_CMD="zenity"; return; fi
  if command -v yad >/dev/null 2>&1; then GUI_CMD="yad"; return; fi
  if command -v dialog >/dev/null 2>&1; then GUI_CMD="dialog"; return; fi
  GUI_CMD=""
}

zenity_input() { zenity --entry --text="$1" --entry-text="$2"; }
yad_input() { yad --entry --text="$1" --entry="$2" --center; }
dialog_input(){
  local title="$1" default="$2" tmpf
  tmpf="$(mktemp)"
  dialog --title "$title" --inputbox "$title" 10 60 "$default" 2> "$tmpf"
  sed -n '1p' "$tmpf"; rm -f "$tmpf"
}

ask_gui() {
  local prompt="$1" default="${2:-}"
  if [[ "$GUI_CMD" == "zenity" ]]; then
    zenity_input "$prompt" "$default"
  elif [[ "$GUI_CMD" == "yad" ]]; then
    yad_input "$prompt" "$default"
  elif [[ "$GUI_CMD" == "dialog" ]]; then
    dialog_input "$prompt" "$default"
  else
    read -r -p "$prompt [$default]: " val
    printf '%s\n' "${val:-$default}"
  fi
}

ask_password() {
  local prompt="${1:-Password}"
  if [[ "$GUI_CMD" == "zenity" ]]; then
    zenity --password --title="$prompt"
  elif [[ "$GUI_CMD" == "yad" ]]; then
    yad --password --entry --text="$prompt" --center
  elif [[ "$GUI_CMD" == "dialog" ]]; then
    local tmpf; tmpf="$(mktemp)"
    dialog --title "$prompt" --insecure --passwordbox "$prompt" 10 60 2> "$tmpf"
    sed -n '1p' "$tmpf"; rm -f "$tmpf"
  else
    read -r -s -p "$prompt: " pw; printf '\n'; printf '%s\n' "$pw"
  fi
}

show_info_box() {
  local msg="$1"
  if [[ "$GUI_CMD" == "zenity" ]]; then
    zenity --info --text="$msg"
  elif [[ "$GUI_CMD" == "yad" ]]; then
    yad --text="$msg" --center
  elif [[ "$GUI_CMD" == "dialog" ]]; then
    dialog --msgbox "$msg" 10 60
  else
    echo -e "$msg"
  fi
}

# ------------------------
# Ensure host prerequisites (installs GUI helpers and essential tools)
# ------------------------
install_host_helpers() {
  detect_gui
  # Always ensure core helpers for this script: curl, gpg, tar, xz, sed, awk, grep
  local base_helpers=(curl gpg tar xz-utils xz coreutils sed awk grep)
  # cryptsetup, util-linux (wipefs, fdisk, mkfs), e2fsprogs (mkfs.ext4, e2label)
  local disk_helpers=(cryptsetup wipefs e2fsprogs util-linux)
  # GUI helpers candidates
  local gui_candidates=(zenity yad dialog)
  # Map distro package names if necessary
  local to_install=()
  for pkg in curl gpg tar xz wipefs cryptsetup e2label mkfs.ext4 sed awk grep; do
    : # not used directly; we will attempt to install reasonable names below
  done

  # Choose package names per package manager
  local mgr; mgr=$(detect_pkg_mgr)
  case "$mgr" in
    apt)
      install_packages apt-transport-https ca-certificates gnupg curl dirmngr \
        xz-utils tar coreutils sed gawk grep dialog wget cryptsetup e2fsprogs util-linux locales || true
      # Try to install zenity and yad if available
      install_packages zenity yad || true
      ;;
    dnf)
      install_packages curl gpg tar xz coreutils sed gawk grep dialog wget cryptsetup e2fsprogs util-linux glibc-langpack-en || true
      install_packages zenity yad || true
      ;;
    pacman)
      install_packages curl gnupg tar xz coreutils sed gawk grep dialog wget cryptsetup e2fsprogs util-linux glibc || true
      install_packages zenity yad || true
      ;;
    zypper)
      install_packages curl gpg tar xz coreutils sed gawk grep dialog wget cryptsetup e2fsprogs util-linux glibc-locale || true
      install_packages zenity yad || true
      ;;
    apk)
      install_packages curl gnupg tar xz busybox-suid sed gawk grep dialog wget cryptsetup e2fsprogs util-linux musl-locales || true
      install_packages zenity || true
      ;;
    *)
      info "Unknown package manager; attempting best-effort but you may need to install helpers manually (curl, gpg, xz, tar, cryptsetup, dialog/zenity/yad, e2fsprogs)."
      ;;
  esac

  # Re-detect GUI now that installers attempted
  detect_gui
  if [[ -z "$GUI_CMD" ]]; then
    info "No GUI helper found after installation attempts; will use text prompts."
  else
    info "Using GUI helper: $GUI_CMD"
  fi
}

# ------------------------
# UI flow
# ------------------------
main_ui() {
  detect_gui

  # If no GUI helper present, ask user to allow installing helpers
  if [[ -z "$GUI_CMD" ]]; then
    info "Graphical helpers (zenity/yad/dialog) not found."
    prompt_confirm "Do you want the installer to attempt installing GUI and helper packages now? (requires network and root privileges)" || true
    install_host_helpers
  fi

  # After helpers ensured, detect again
  detect_gui

  # Ensure critical commands exist for rest of script
  ensure_command awk awk
  ensure_command sed sed
  ensure_command grep grep
  ensure_command curl curl
  ensure_command gpg gpg
  ensure_command tar tar
  ensure_command xz xz

  # Offer options
  local install_guix="yes" enable_daemon="yes" configure_system="no"
  local create_user="yes" enable_luks="no" target_disk="" username="guixuser" hostname="guix-host"

  if [[ "$GUI_CMD" == "zenity" ]]; then
    local choices
    choices=$(zenity --list --checklist --title="Guix Installer" \
      --column="Choose" --column="Option" \
      TRUE "Install Guix" TRUE "Enable guix-daemon" FALSE "Configure Guix System generation" TRUE "Create user" FALSE "Enable LUKS encryption" \
      --separator="|")
    if [[ -z "$choices" ]]; then fatal "No options chosen; aborting."; fi
    install_guix=$([[ "$choices" == *"Install Guix"* ]] && echo yes || echo no)
    enable_daemon=$([[ "$choices" == *"Enable guix-daemon"* ]] && echo yes || echo no)
    configure_system=$([[ "$choices" == *"Configure Guix System generation"* ]] && echo yes || echo no)
    create_user=$([[ "$choices" == *"Create user"* ]] && echo yes || echo no)
    enable_luks=$([[ "$choices" == *"Enable LUKS encryption"* ]] && echo yes || echo no)
    username=$(ask_gui "Enter username" "$username")
    hostname=$(ask_gui "Enter hostname" "$hostname")
    target_disk=$(ask_gui "Target device for installation (e.g. /dev/sda). Leave empty to skip disk ops" "")
  elif [[ "$GUI_CMD" == "yad" ]]; then
    local out
    out=$(yad --form --title="Guix Installer" \
      --field="Install Guix:CHK" TRUE \
      --field="Enable guix-daemon:CHK" TRUE \
      --field="Configure Guix System:CHK" FALSE \
      --field="Create user:CHK" TRUE \
      --field="Enable LUKS:CHK" FALSE \
      --field="Username" "$username" \
      --field="Hostname" "$hostname" \
      --field="Target device (e.g. /dev/sda)" "")
    IFS="|" read -r install_guix enable_daemon configure_system create_user enable_luks username hostname target_disk <<<"$out"
    install_guix=$([[ "$install_guix" == "TRUE" ]] && echo yes || echo no)
    enable_daemon=$([[ "$enable_daemon" == "TRUE" ]] && echo yes || echo no)
    configure_system=$([[ "$configure_system" == "TRUE" ]] && echo yes || echo no)
    create_user=$([[ "$create_user" == "TRUE" ]] && echo yes || echo no)
    enable_luks=$([[ "$enable_luks" == "TRUE" ]] && echo yes || echo no)
  elif [[ "$GUI_CMD" == "dialog" ]]; then
    local tmpf; tmpf="$(mktemp)"
    dialog --title "Guix Installer" --checklist "Select options" 15 60 6 \
      1 "Install Guix" on \
      2 "Enable guix-daemon" on \
      3 "Configure Guix System generation" off \
      4 "Create user" on \
      5 "Enable LUKS encryption" off 2> "$tmpf"
    local sel; sel=$(tr -d '\n' < "$tmpf"); rm -f "$tmpf"
    install_guix=$([[ "$sel" == *1* ]] && echo yes || echo no)
    enable_daemon=$([[ "$sel" == *2* ]] && echo yes || echo no)
    configure_system=$([[ "$sel" == *3* ]] && echo yes || echo no)
    create_user=$([[ "$sel" == *4* ]] && echo yes || echo no)
    enable_luks=$([[ "$sel" == *5* ]] && echo yes || echo no)
    username=$(ask_gui "Enter username" "$username")
    hostname=$(ask_gui "Enter hostname" "$hostname")
    target_disk=$(ask_gui "Target device for installation (e.g. /dev/sda). Leave empty to skip disk ops" "")
  else
    read -r -p "Install Guix? [Y/n]: " r; install_guix=${r:-y}
    read -r -p "Enable guix-daemon? [Y/n]: " r; enable_daemon=${r:-y}
    read -r -p "Configure Guix System generation? [y/N]: " r; configure_system=${r:-n}
    read -r -p "Create user? [Y/n]: " r; create_user=${r:-y}
    read -r -p "Enable LUKS encryption? [y/N]: " r; enable_luks=${r:-n}
    username=$(ask_gui "Enter username" "$username")
    hostname=$(ask_gui "Enter hostname" "$hostname")
    read -r -p "Target device for installation (e.g. /dev/sda) [leave empty to skip disk ops]: " target_disk
  fi

  # Normalize to lowercase
  install_guix=$(echo "$install_guix" | awk '{print tolower($0)}')
  enable_daemon=$(echo "$enable_daemon" | awk '{print tolower($0)}')
  configure_system=$(echo "$configure_system" | awk '{print tolower($0)}')
  create_user=$(echo "$create_user" | awk '{print tolower($0)}')
  enable_luks=$(echo "$enable_luks" | awk '{print tolower($0)}')

  # Locale/keyboard defaults (US)
  locale=$(ask_gui "Locale (default ${DEFAULT_LOCALE})" "$DEFAULT_LOCALE")
  keymap=$(ask_gui "Keyboard layout (default ${DEFAULT_KEYMAP})" "$DEFAULT_KEYMAP")
  lang=$(ask_gui "Language (default ${DEFAULT_LANG})" "$DEFAULT_LANG")

  # Password for created user (if requested)
  userpw=""
  if [[ "$create_user" == "y" || "$create_user" == "yes" ]]; then
    userpw=$(ask_password "Enter password for ${username}")
    if [[ -z "$userpw" ]]; then fatal "Empty password; aborting."; fi
  fi

  if [[ "$enable_luks" == "y" || "$enable_luks" == "yes" ]]; then
    if [[ -z "$target_disk" ]]; then fatal "LUKS requested but no target device provided; aborting."; fi
    prompt_confirm "You chose LUKS on ${target_disk}. This will erase the device. Continue?" || fatal "User aborted LUKS operation."
  fi

  INSTALL_CHOICES=(
    install_guix="$install_guix"
    enable_daemon="$enable_daemon"
    configure_system="$configure_system"
    create_user="$create_user"
    enable_luks="$enable_luks"
    target_disk="$target_disk"
    username="$username"
    userpw="(hidden)"
    hostname="$hostname"
    locale="$locale"
    keymap="$keymap"
    lang="$lang"
  )

  for kv in "${INSTALL_CHOICES[@]}"; do info "$kv"; done

  prompt_confirm "Proceed with the installation using the chosen options?" || fatal "Aborted by user."

  # Export variables for main flow
  export install_guix enable_daemon configure_system create_user enable_luks target_disk username userpw hostname locale keymap lang
}

# ------------------------
# LUKS operations
# ------------------------
setup_luks() {
  local device="$1"
  local luks_name="cryptroot"
  ensure_command cryptsetup cryptsetup
  ensure_command wipefs wipefs
  ensure_command mkfs.ext4 mkfs.ext4
  info "Wiping filesystem signatures on $device"
  wipefs -a "$device" || info "wipefs returned non-zero, continuing cautiously"

  local pass
  pass=$(ask_password "Enter passphrase for LUKS on ${device}")
  if [[ -z "$pass" ]]; then fatal "Empty passphrase; aborting."; fi

  info "Formatting $device with LUKS2"
  printf '%s' "$pass" | cryptsetup luksFormat --type luks2 "$device" - || fatal "luksFormat failed"

  info "Opening LUKS device as /dev/mapper/${luks_name}"
  printf '%s' "$pass" | cryptsetup open "$device" "$luks_name" - || fatal "cryptsetup open failed"

  info "Creating ext4 filesystem on /dev/mapper/${luks_name}"
  mkfs.ext4 -L guixroot "/dev/mapper/${luks_name}" || fatal "mkfs.ext4 failed"

  mkdir -p /mnt/guix
  mount "/dev/mapper/${luks_name}" /mnt/guix || fatal "Mount failed"
  info "LUKS device formatted and mounted at /mnt/guix"

  # Record destructive action for cleanup
  DESTRUCTIVE_ACTIONS+=("cryptsetup close ${luks_name}")
}

# ------------------------
# Guix bootstrap and host integration
# ------------------------
bootstrap_guix() {
  ensure_command curl curl
  ensure_command gpg gpg
  ensure_command tar tar
  ensure_command xz xz
  info "Downloading official Guix install script"
  # Try guix.gnu.org first
  curl -fsSLO "https://guix.gnu.org/root/guix-install.sh" || true
  if [[ ! -f guix-install.sh ]]; then
    # try savannah raw file location as fallback
    curl -fsSLO "https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh" || true
  fi
  if [[ -f guix-install.sh ]]; then
    chmod +x guix-install.sh
    ./guix-install.sh || fatal "Guix installation script failed"
  else
    fatal "Could not download Guix installer. Please install Guix manually and re-run."
  fi
  info "Guix bootstrap attempted."
}

install_guix_packages_in_host() {
  local en_daemon="$1" en_luks="$2"
  if [[ "$en_luks" == "yes" || "$en_luks" == "y" ]]; then
    ensure_command cryptsetup cryptsetup
  fi
  if ! command -v guix >/dev/null 2>&1; then
    if [[ "$install_guix" == "yes" || "$install_guix" == "y" ]]; then
      info "Bootstrapping Guix now (network required)."
      bootstrap_guix
    else
      info "Guix not installed and user chose not to install it. Continuing without Guix."
    fi
  fi
  if [[ "$en_daemon" == "yes" || "$en_daemon" == "y" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      info "Attempting to enable and start guix-daemon with systemd"
      systemctl enable --now guix-daemon || info "Could not enable/start guix-daemon via systemd"
    else
      info "No systemd detected; please enable guix-daemon using your init system if needed."
    fi
  fi
}

# ------------------------
# Full Guix System configuration template
# ------------------------
# This template contains many use-modules, package and service definitions,
# example desktop packages, kernel and bootloader settings, encrypted swap,
# and hooks for cryptsetup integration.
write_full_guix_system_config() {
  local outdir="${1:-/mnt/guix/etc/guix-system-config}"
  local locale="$2" keymap="$3" hostname="$4" user="$5"
  info "Writing complete Guix system configuration template to ${outdir}/system.scm"
  mkdir -p "$outdir"
  cat > "$outdir/system.scm" <<'SCM'
(use-modules (gnu)
             (gnu packages)
             (gnu packages linux)
             (gnu packages gnupg)
             (gnu packages gcc)
             (gnu packages python)
             (gnu packages rust)
             (gnu packages go)
             (gnu packages perl)
             (gnu packages emacs)
             (gnu packages shell)
             (gnu services)
             (gnu services xorg)
             (gnu services desktop)
             (gnu services networking)
             (gnu system)
             (gnu system linux)
             (srfi srfi-1))

;; -----------------------
;; User-editable configuration
;; -----------------------
(let* ((username "USERNAME")
       (host "HOSTNAME")
       (locale "LOCALE")
       (keymap "KEYMAP")
       ;; Basic package selection: add or remove packages here
       (my-packages (list
                     ;; Essentials
                     coreutils
                     findutils
                     file
                     grep
                     sed
                     gawk
                     util-linux
                     e2fsprogs
                     ;; Networking
                     openssh
                     wget
                     curl
                     ;; Development
                     gcc
                     glibc-locales
                     python
                     rust
                     go
                     ;; Editors
                     emacs
                     vim
                     nano
                     ;; GUI
                     xorg-server
                     xf86-video-intel
                     xfce
                     network-manager-applet
                     ;; Browser
                     firefox
                     ;; Cryptography
                     gnupg
                     cryptsetup
                     ;; Misc
                     htop
                     unzip
                     zip
                     ))
       ;; Desktop services: example: enable NetworkManager, display manager
       (my-services (cons*
                     (service network-manager-service-type)
                     (service elogind-service-type)
                     (service dbus-service-type)
                     %desktop-services))
       ;; Kernel and bootloader
       (my-kernel linux-libre)
       ;; Filesystems: expecting /dev/disk/by-label/guixroot for root
       (my-file-systems
        (list (file-system
               (mount-point "/")
               (device "/dev/disk/by-label/guixroot")
               (type "ext4"))
              ;; optional /boot on separate partition
              ))
       ;; Bootloader configuration (grub)
       (my-bootloader (bootloader-configuration
                       (bootloader grub-bootloader)
                       (target "/boot")))
       ;; Users
       (my-users (cons
                 (user-account
                   (name username)
                   (comment "Guix user")
                   (home-directory (string-append "/home/" username))
                   (groups '("wheel" "network" "audio" "video"))
                   (shell (which "bash")))
                 %base-user-accounts)))
  ;; Operating system
  (operating-system
    (host-name host)
    (timezone "UTC")
    (locale locale)
    (keyboard-layout (list (keyboard-configuration keymap)))
    (bootloader my-bootloader)
    (file-systems my-file-systems)
    (kernel my-kernel)
    (users my-users)
    (services (append my-services
                      ;; Example: enable sshd
                      (list (service openssh-service-type))))
    (packages (append my-packages %base-packages))
    (system-post-installation
     (lambda ()
       ;; post-installation hooks here
       (begin
         (trace "Running system post-installation hooks")
         #t)))
    ;; Extra FHS-like directories to ensure
    (extra-substituters '())
    ;; Add cryptsetup to system closure so initramfs can use it if needed
    (package-management
     (cons* cryptsetup %default-package-management))))
SCM

  # Replace placeholders
  sed -i "s|USERNAME|$user|g" "$outdir/system.scm"
  sed -i "s|HOSTNAME|$hostname|g" "$outdir/system.scm"
  sed -i "s|LOCALE|$locale|g" "$outdir/system.scm"
  sed -i "s|KEYMAP|$keymap|g" "$outdir/system.scm"

  info "Complete template written to ${outdir}/system.scm"
  info "Edit that file to adjust packages, services, kernels, and encryption settings before running: guix system init ${outdir}/system.scm /"
}

# ------------------------
# Main flow
# ------------------------
main() {
  if [[ $EUID -ne 0 ]]; then fatal "This installer requires root privileges. Re-run as root."; fi

  # Ensure basic host helpers and GUI if requested
  install_host_helpers

  # UI & collect choices
  main_ui

  # Use exported variables from main_ui (safe defaults if missing)
  install_guix=${install_guix:-no}
  enable_daemon=${enable_daemon:-no}
  configure_system=${configure_system:-no}
  create_user=${create_user:-no}
  enable_luks=${enable_luks:-no}
  target_disk=${target_disk:-}
  username=${username:-guixuser}
  userpw=${userpw:-}
  hostname=${hostname:-guix-host}
  locale=${locale:-$DEFAULT_LOCALE}
  keymap=${keymap:-$DEFAULT_KEYMAP}
  lang=${lang:-$DEFAULT_LANG}

  # Try to ensure host-level packages required for disk ops and LUKS
  if [[ "$enable_luks" == "y" || "$enable_luks" == "yes" ]]; then
    ensure_command cryptsetup cryptsetup
    ensure_command wipefs wipefs
    ensure_command mkfs.ext4 mkfs.ext4
  fi

  # Install Guix if requested
  install_guix_packages_in_host "$enable_daemon" "$enable_luks"

  # LUKS handling
  if [[ "$enable_luks" == "y" || "$enable_luks" == "yes" ]]; then
    setup_luks "$target_disk"
    # ensure e2label exists and apply label for template reference
    if command -v e2label >/dev/null 2>&1; then
      e2label /dev/mapper/cryptroot guixroot || info "Could not set e2label; you may need to set it manually."
    fi
  fi

  # Create user on host if requested
  if [[ "$create_user" == "y" || "$create_user" == "yes" ]]; then
    if id -u "$username" >/dev/null 2>&1; then
      info "User $username already exists; skipping creation."
    else
      info "Creating user $username on host"
      useradd -m -G wheel -s /bin/bash "$username"
      if [[ -n "$userpw" ]]; then
        echo "${username}:${userpw}" | chpasswd
      else
        info "No password provided; user has no password set."
      fi
      info "User $username created."
    fi
  fi

  # Write the complete Guix System configuration template
  if [[ "$configure_system" == "y" || "$configure_system" == "yes" ]]; then
    if [[ -d /mnt/guix ]]; then
      write_full_guix_system_config "/mnt/guix/etc/guix-system-config" "$locale" "$keymap" "$hostname" "$username"
      show_info_box "Guix system configuration template written to /mnt/guix/etc/guix-system-config/system.scm. Edit then run: guix system init /mnt/guix/etc/guix-system-config/system.scm /mnt/guix (or adapt to your layout)."
    else
      write_full_guix_system_config "/root/guix-system-config" "$locale" "$keymap" "$hostname" "$username"
      show_info_box "Guix system configuration template written to /root/guix-system-config/system.scm"
    fi
  fi

  show_info_box "Installer actions finished. Review messages above."

  if [[ "${#DESTRUCTIVE_ACTIONS[@]}" -gt 0 ]]; then
    printf "\nTo undo temporary mappings run:\n"
    for a in "${DESTRUCTIVE_ACTIONS[@]}"; do printf "  %s\n" "$a"; done
  fi
}

# Run
main "$@"
