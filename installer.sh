#!/usr/bin/env bash
# Universal Guix System installer for live environments
#
set -euo pipefail

# -------------------------
# Defaults / built-ins
# -------------------------
TMPDIR="$(mktemp -d /tmp/guix-installer.XXXXXX)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
INSTALLER_NAME="$(basename "$0")"

TARGET_DEVICE=""
TARGET_MOUNT=""
TARGET_IS_DEVICE=0
CHANNEL_SOURCE=""
CONFIG_SOURCE=""
ASSUME_YES=0
SKIP_DEPS=0
DEBUG=0
FORCE_NOGUI=0

# Template defaults (overridden automatically when device chosen)
TEMPLATE_LOCALE="en_US.UTF-8"
TEMPLATE_TZ="UTC"
TEMPLATE_KB="us"
TEMPLATE_HOST="guix-host"
TEMPLATE_USER="guix"
TEMPLATE_MAPPED="()"
# Default root device expression (if user did not select a device and did not provide custom config)
TEMPLATE_ROOT_DEVICE="\"/dev/disk/by-label/root\""

BOOTSTRAP_GUIX_TARBALL_URL="https://ci.guix.gnu.org/nar/nar-info/guix-bootstrapped.tar.xz"

read -r -d '' BUILTIN_CHANNELS <<'SCM' || true
(use-modules (guix ci))
(list
  (channel-with-substitutes-available
    %default-guix-channel
    "https://ci.guix.gnu.org")
  (channel
    (name 'guix)
    (url "https://codeberg.org/guix/guix.git")
    (branch "master"))
  (channel
    (name 'nonguix)
    (url "https://gitlab.com/nonguix/nonguix")
    (branch "master")))
SCM

read -r -d '' BUILTIN_CONFIG_TEMPLATE <<'SCM' || true
(use-modules (gnu)
             (gnu services)
             (gnu services base)
             (gnu services desktop)
             (gnu services networking)
             (gnu services xorg)
             (gnu packages)
             (gnu packages certs)
             (gnu packages fonts)
             (gnu packages gnome)
             (gnu packages gtk)
             (gnu packages pulseaudio)
             (gnu packages audio)
             (gnu packages linux)
             (guix channels)
             (guix packages)
             (gnu packages disk)
             (gnu packages gnuzilla)
             (nongnu packages linux)
             (nongnu system linux-initrd)
             (guix build-system gnu))

(use-package-modules
  certs fonts gnome gtk pulseaudio audio linux
  bash coreutils findutils grep sed gawk tar xz
  curl wget git openssh rsync
  nss-certs)

(use-service-modules
  desktop xorg networking ssh avahi
  dbus dbus-root)

(operating-system
 (kernel linux kernel)
 (firmware (list linux-firmware))
 (initrd microcode-initrd)
 (locale "$LOCALE")
 (timezone "$TZ")
 (keyboard-layout (keyboard-layout "$KB"))
 (host-name "$HOST")
 (users (cons* (user-account
                 (name "$USER")
                 (group "users")
                 (supplementary-groups '("wheel" "netdev" "audio" "video")))
                %base-users))
 (packages (append (list nss-certs font-dejavu
                         icecat font-gnu-freefont lf
                         gnome gnome-tweaks pulseaudio pavucontrol
                         bash-completion git curl wget rsync openssh)
                   %base-packages))
 (services (append (list (service gnome-desktop-service-type)
                         (service gdm-service-type)
                         (service network-manager-service-type)
                         (service wpa-supplicant-service-type)
                         (service avahi-service-type)
                         (service openssh-service-type)
                         (service bluetooth-service-type)
                         (service thermald-service-type)
                         (service tlp-service-type))
                   %desktop-services))
 (bootloader (bootloader-configuration (bootloader grub-efi-bootloader) (targets '("/boot/efi"))))
 (mapped-devices $MAPPED)
 (file-systems (cons* (file-system (mount-point "/boot/efi") (device (file-system-label "EFI")) (type "vfat"))
                      (file-system (mount-point "/") (device $ROOT_DEVICE) (type "ext4")) %base-file-systems)))
SCM

# -------------------------
# Helpers
# -------------------------
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '\033[1;32m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m--\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m!!\033[0m %s\n' "$*"; }
dbg()  { [ "${DEBUG:-0}" -eq 1 ] && printf '\033[1;35mDBG\033[0m %s\n' "$*"; }

is_url() { case "$1" in https?://*) return 0;; *) return 1;; esac; }

download() {
  local url="$1" dest="$2"
  dbg "download: $url -> $dest"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$dest" "$url"
  else return 1; fi
}

detect_mountpoint_for_device() {
  local dev="$1"
  [ -e "$dev" ] && dev="$(readlink -f "$dev")" || true
  if [ -f /proc/mounts ]; then
    while read -r devnode mp rest; do
      [ "$devnode" = "$dev" ] && { printf '%s' "$mp"; return 0; }
    done < /proc/mounts
  fi
  if command -v lsblk >/dev/null 2>&1; then
    while IFS= read -r line; do
      eval "declare -A kv"
      for kvpair in $line; do
        key=${kvpair%%=*}
        val=${kvpair#*=}
        val=${val#\"}; val=${val%\"}
        kv[$key]="$val"
      done
      [ -n "${kv[NAME]-}" ] || continue
      for candidate in "/dev/${kv[NAME]}" "/dev/mapper/${kv[NAME]}"; do
        [ "$candidate" = "$dev" ] && [ -n "${kv[MOUNTPOINT]-}" ] && { printf '%s' "${kv[MOUNTPOINT]}"; return 0; }
      done
    done < <(lsblk -P -o NAME,MOUNTPOINT 2>/dev/null || true)
  fi
  return 1
}

# -------------------------
# GUI helpers (zenity/yad) with fallback
# -------------------------
gui_cmd=""
use_gui() {
  [ "${FORCE_NOGUI:-0}" -eq 1 ] && return 1
  [ -n "$gui_cmd" ] && return 0
  if command -v zenity >/dev/null 2>&1; then gui_cmd=zenity; return 0; fi
  if command -v yad >/dev/null 2>&1; then gui_cmd=yad; return 0; fi
  return 1
}

gui_info() {
  local msg="$1" title="${2:-Installer}"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then zenity --info --no-wrap --title="$title" --text="$msg"; else yad --title="$title" --text="$msg" --button=OK:0; fi
  else info "$msg"; fi
}

gui_yesno() {
  local prompt="$1"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then zenity --question --title="Confirm" --text="$prompt"; return $?; else yad --question --title="Confirm" --text="$prompt"; return $?; fi
  fi
  return 1
}

gui_entry() {
  local prompt="$1" default="${2:-}" title="${3:-Input}"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then zenity --entry --title="$title" --text="$prompt" --entry-text="$default" || true; else yad --entry --title="$title" --text="$prompt" --entry="$default" || true; fi
  else
    read -r -p "$prompt [$default]: " val
    printf '%s' "${val:-$default}"
  fi
}

gui_filechooserdialog() {
  local typ="${1:-file}" title="${2:-Choose file}"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then
      if [ "$typ" = "file" ]; then zenity --file-selection --title="$title" || true; else zenity --file-selection --directory --title="$title" || true; fi
    else
      if [ "$typ" = "file" ]; then yad --file --title="$title" || true; else yad --directory --title="$title" || true; fi
    fi
  else
    echo ""
  fi
}

gui_list_select() {
  local title="$1" text="$2" items="$3"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then
      echo -e "$items" | zenity --list --title="$title" --text="$text" --column=Option --height=300 --width=500 --print-column=1 2>/dev/null || true
    else
      echo -e "$items" | yad --list --title="$title" --text="$text" --column=Option --height=300 --width=500 --print-preview 2>/dev/null || true
    fi
  else
    local i=0; IFS=$'\n'
    for it in $items; do i=$((i+1)); printf '%3d) %s\n' "$i" "$it"; done
    unset IFS
    read -r -p "Choose number: " choice
    printf '%s\n' "$(echo -e "$items" | sed -n "${choice}p")"
  fi
}

# -------------------------
# Argument parsing
# -------------------------
usage() {
  cat <<EOF
Usage: $INSTALLER_NAME [options]

Options:
  --device DEVICE       Target block device (e.g. /dev/sda)
  --target MOUNTPOINT   Target mountpoint (e.g. /mnt/guix)
  --channels PATH|URL   Path or URL to channels.scm (preserved if provided)
  --config PATH|URL     Path or URL to full config.scm (preserved if provided)
  --nogui               Force non-graphical mode
  --yes                 Assume yes to prompts
  --skip-deps           Skip installing distro dependencies
  --debug               Enable debug output
  -h, --help            Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) TARGET_DEVICE="$2"; TARGET_IS_DEVICE=1; shift 2 ;;
    --target) TARGET_MOUNT="$2"; shift 2 ;;
    --channels) CHANNEL_SOURCE="$2"; shift 2 ;;
    --channels=*) CHANNEL_SOURCE="${1#*=}"; shift ;;
    --config) CONFIG_SOURCE="$2"; shift 2 ;;
    --config=*) CONFIG_SOURCE="${1#*=}"; shift ;;
    --nogui) FORCE_NOGUI=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# -------------------------
# Environment detection & bootstrap helpers
# -------------------------
detect_env() {
  OS="$(uname -s)"
  case "$OS" in Linux) PLATFORM="linux" ;; FreeBSD|OpenBSD|NetBSD|DragonFly) PLATFORM="bsd" ;; *) PLATFORM="unknown" ;; esac
  dbg "Platform: $PLATFORM"
}

install_minimum_deps() {
  [ "${SKIP_DEPS:-0}" -eq 1 ] && { warn "Skipping distro dependency installation"; return 0; }
  log "Installing minimum dependencies (may vary by live image)"
  case "$PLATFORM" in
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y curl wget gnupg tar xz-utils gawk git parted util-linux || warn "apt returned non-zero"
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y curl wget gnupg2 tar xz gawk git parted util-linux || warn "dnf returned non-zero"
      fi
      ;;
  esac
}

ensure_guix_available() {
  if command -v guix >/dev/null 2>&1; then info "guix available"; return 0; fi
  warn "guix not found in environment; attempting distro install (may not exist) or bootstrap"
  case "$PLATFORM" in
    linux)
      if command -v apt-get >/dev/null 2>&1 && apt-cache policy guix >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y guix && return 0 || warn "apt guix failed"
      fi
      ;;
  esac
  bootstrap_guix_from_tarball
}

bootstrap_guix_from_tarball() {
  local tarball="$TMPDIR/guix-bootstrap.tar.xz"
  info "Downloading Guix bootstrap tarball (may be slow)"
  if ! download "$BOOTSTRAP_GUIX_TARBALL_URL" "$tarball"; then warn "Failed to download bootstrap tarball"; return 1; fi
  mkdir -p "$TMPDIR/guix-bootstrap"
  tar -xJf "$tarball" -C "$TMPDIR/guix-bootstrap"
  if [ -d "$TMPDIR/guix-bootstrap/bin" ]; then
    export PATH="$TMPDIR/guix-bootstrap/bin:$PATH"
    info "Temporary guix added to PATH"
    command -v guix >/dev/null 2>&1 && return 0
  fi
  return 1
}

# -------------------------
# Partition / mount helpers
# -------------------------
ensure_target_mount() {
  if [ -n "$TARGET_DEVICE" ]; then
    [ -b "$TARGET_DEVICE" ] || { err "Target device $TARGET_DEVICE not found"; exit 1; }
    info "Target device: $TARGET_DEVICE"
    if [ "${ASSUME_YES:-0}" -eq 0 ]; then
      if use_gui; then gui_yesno "Partition and format $TARGET_DEVICE (will erase all data)?" || { info "User cancelled"; exit 1; }; else
        read -r -p "Partition and format $TARGET_DEVICE (will erase all data)? [y/N]: " yn; case "${yn,,}" in y|yes) : ;; *) info "User cancelled"; exit 1 ;; esac
      fi
    fi
    partition_and_format_device "$TARGET_DEVICE"
    mount_target_after_partition "$TARGET_DEVICE"
    # After partitioning & formatting we automatically set the root-device expression
    # Use Scheme expression that resolves by filesystem label "root"
    TEMPLATE_ROOT_DEVICE='(file-system-label "root")'
    info "Automatically set Root Device expression to: $TEMPLATE_ROOT_DEVICE"
  else
    if [ -z "$TARGET_MOUNT" ]; then
      if use_gui; then
        TARGET_MOUNT="$(gui_filechooserdialog dir "Target mount")"
      fi
      if [ -z "$TARGET_MOUNT" ]; then err "No --device or --target provided"; usage; exit 1; fi
    fi
    [ -d "$TARGET_MOUNT" ] || mkdir -p "$TARGET_MOUNT"
  fi

  if [ -z "$TARGET_MOUNT" ] && [ -n "$TARGET_DEVICE" ]; then
    TARGET_MOUNT="$(detect_mountpoint_for_device "$TARGET_DEVICE" || true)"
    [ -n "$TARGET_MOUNT" ] || { err "Could not determine mountpoint for device; please mount and re-run"; exit 1; }
  fi

  info "Using target mountpoint: $TARGET_MOUNT"
}

partition_and_format_device() {
  local dev="$1"
  warn "This will destroy all data on $dev"
  if [ "${ASSUME_YES:-0}" -eq 0 ]; then
    read -r -p "Do you really want to partition and format $dev? [y/N]: " yn
    case "${yn,,}" in y|yes) : ;; *) echo "Aborted"; exit 1 ;; esac
  fi

  if command -v parted >/dev/null 2>&1; then
    sudo parted -s "$dev" mklabel gpt
    sudo parted -s -a optimal "$dev" mkpart primary fat32 1MiB 512MiB
    sudo parted -s -a optimal "$dev" mkpart primary ext4 512MiB 100%
    sudo partprobe "$dev" || true
    local efipart="${dev}1" rootpart="${dev}2"
    [ -b "$rootpart" ] || [ -b "${dev}p2" ] && { [ -b "${dev}p2" ] && rootpart="${dev}p2"; } || true
    if [ -b "${dev}p1" ]; then efipart="${dev}p1"; fi
    [ -b "$rootpart" ] || { err "Root partition not found after partitioning"; exit 1; }
    if [ -b "$efipart" ]; then sudo mkfs.vfat -F32 -n EFI "$efipart"; fi
    sudo mkfs.ext4 -F -L root "$rootpart"
    TARGET_MOUNT="${TARGET_MOUNT:-/mnt/guix}"
    mkdir -p "$TARGET_MOUNT"
    sudo mount "$rootpart" "$TARGET_MOUNT"
    if [ -b "$efipart" ]; then sudo mkdir -p "$TARGET_MOUNT/boot/efi"; sudo mount "$efipart" "$TARGET_MOUNT/boot/efi"; fi
  elif command -v sfdisk >/dev/null 2>&1; then
    echo "label: gpt" | sudo sfdisk "$dev"
    printf ",512M,U\n,,L\n" | sudo sfdisk "$dev"
    sudo partprobe "$dev" || true
    local rootpart="${dev}2"
    if [ -b "${dev}p2" ]; then rootpart="${dev}p2"; fi
    [ -b "$rootpart" ] || { err "Root partition not found after sfdisk"; exit 1; }
    sudo mkfs.ext4 -F -L root "$rootpart"
    TARGET_MOUNT="${TARGET_MOUNT:-/mnt/guix}"
    mkdir -p "$TARGET_MOUNT"
    sudo mount "$rootpart" "$TARGET_MOUNT"
  else
    err "No partitioning tool available (parted or sfdisk required)"
    exit 1
  fi
  info "Partition and format complete; root mounted at $TARGET_MOUNT"
}

mount_target_after_partition() {
  local dev="$1"
  local part="${dev}2"
  if [ ! -b "$part" ] && [ -b "${dev}p2" ]; then part="${dev}p2"; fi
  [ -b "$part" ] || { err "Partition not found for $dev"; exit 1; }
  TARGET_MOUNT="${TARGET_MOUNT:-/mnt/guix}"
  mkdir -p "$TARGET_MOUNT"
  sudo mount "$part" "$TARGET_MOUNT"
  info "Mounted $part at $TARGET_MOUNT"
}

# -------------------------
# Channels & config handling
# -------------------------
prepare_channels_and_config() {
  # channels: preserve user-provided file if supplied
  if [ -n "$CHANNEL_SOURCE" ]; then
    if [ -f "$CHANNEL_SOURCE" ]; then CHANNEL_FILE="$CHANNEL_SOURCE"
    elif is_url "$CHANNEL_SOURCE"; then CHANNEL_FILE="$TMPDIR/channels.scm"; download "$CHANNEL_SOURCE" "$CHANNEL_FILE"; else err "channels.scm source not found"; exit 1; fi
  else
    CHANNEL_FILE="$TMPDIR/channels.scm"; printf "%s\n" "$BUILTIN_CHANNELS" > "$CHANNEL_FILE"
  fi

  # config: preserve user-supplied full config if provided, otherwise render the template
  if [ -n "$CONFIG_SOURCE" ]; then
    if [ -f "$CONFIG_SOURCE" ]; then CONFIG_FILE="$CONFIG_SOURCE"
    elif is_url "$CONFIG_SOURCE"; then CONFIG_FILE="$TMPDIR/config.scm"; download "$CONFIG_SOURCE" "$CONFIG_FILE"; else err "config.scm source not found"; exit 1; fi
  else
    CONFIG_FILE="$TMPDIR/config.scm"
    rendered="$BUILTIN_CONFIG_TEMPLATE"
    rendered="${rendered//\$LOCALE/${TEMPLATE_LOCALE}}"
    rendered="${rendered//\$TZ/${TEMPLATE_TZ}}"
    rendered="${rendered//\$KB/${TEMPLATE_KB}}"
    rendered="${rendered//\$HOST/${TEMPLATE_HOST}}"
    rendered="${rendered//\$USER/${TEMPLATE_USER}}"
    # MAPPED is inserted raw (user must supply valid Scheme expression if used)
    rendered="${rendered//\$MAPPED/${TEMPLATE_MAPPED}}"
    # ROOT_DEVICE should be a Scheme expression; keep as-is (we set TEMPLATE_ROOT_DEVICE above when partitioning)
    rendered="${rendered//\$ROOT_DEVICE/${TEMPLATE_ROOT_DEVICE}}"
    printf "%s\n" "$rendered" > "$CONFIG_FILE"
    info "Rendered config.scm to $CONFIG_FILE"
  fi

  sudo mkdir -p "$TARGET_MOUNT/etc/guix" "$TARGET_MOUNT/root/.config/guix"
  sudo cp -f "$CHANNEL_FILE" "$TARGET_MOUNT/etc/guix/channels.scm"
  sudo cp -f "$CONFIG_FILE" "$TARGET_MOUNT/etc/guix/config.scm"
  sudo cp -f "$CHANNEL_FILE" "$TARGET_MOUNT/root/.config/guix/channels.scm"
  sudo cp -f "$CONFIG_FILE" "$TARGET_MOUNT/root/.config/guix/config.scm"
  info "Placed channels.scm and config.scm into target"
}

# -------------------------
# Run guix system init inside the target
# -------------------------
prepare_and_run_init() {
  info "Preparing environment for guix system init"

  ensure_guix_available || { err "guix is required; aborting"; exit 1; }

  sudo mkdir -p "$TARGET_MOUNT"/{proc,sys,dev,run,tmp}
  sudo mount --bind /dev "$TARGET_MOUNT/dev"
  sudo mount --bind /run "$TARGET_MOUNT/run" || true
  sudo mount -t proc proc "$TARGET_MOUNT/proc" || true
  sudo mount -t sysfs sys "$TARGET_MOUNT/sys" || true
  sudo mount --bind /tmp "$TARGET_MOUNT/tmp" || true

  [ -f /etc/resolv.conf ] && sudo cp -L /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"
  [ -f /etc/hosts ] && sudo cp -L /etc/hosts "$TARGET_MOUNT/etc/hosts"

  TMP_SCRIPT="$TMPDIR/run-guix-init.sh"
  cat > "$TMP_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONFIG="/etc/guix/config.scm"
CHANNELS="/etc/guix/channels.scm"
if [ -f /root/.config/guix/config.scm ]; then CONFIG="/root/.config/guix/config.scm"; fi
if [ -f /root/.config/guix/channels.scm ]; then CHANNELS="/root/.config/guix/channels.scm"; fi
echo "Running guix pull --channels=$CHANNELS"
if command -v guix >/dev/null 2>&1; then
  guix pull --channels="$CHANNELS" || echo "guix pull failed; continuing"
else
  echo "guix not found; aborting" >&2; exit 1
fi
echo "Running guix system init with config: $CONFIG"
guix system init "$CONFIG" /boot || { echo "guix system init failed"; exit 1; }
SH
  chmod +x "$TMP_SCRIPT"
  sudo cp "$TMP_SCRIPT" "$TARGET_MOUNT/root/run-guix-init.sh"
  sudo chown root:root "$TARGET_MOUNT/root/run-guix-init.sh"

  info "Starting guix system init inside target (may take long)"
  if command -v systemd-nspawn >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    sudo systemd-nspawn -D "$TARGET_MOUNT" /root/run-guix-init.sh || { warn "systemd-nspawn failed; falling back to chroot"; sudo chroot "$TARGET_MOUNT" /root/run-guix-init.sh; }
  else
    if [ "$(id -u)" -ne 0 ]; then
      warn "Not root; attempting sudo chroot (may fail)"
      sudo chroot "$TARGET_MOUNT" /root/run-guix-init.sh
    else
      chroot "$TARGET_MOUNT" /root/run-guix-init.sh
    fi
  fi

  info "guix system init finished (or attempted)."
}

# -------------------------
# Cleanup & final steps
# -------------------------
finalize() {
  info "Unmounting temporary binds"
  for mp in "$TARGET_MOUNT/tmp" "$TARGET_MOUNT/run" "$TARGET_MOUNT/proc" "$TARGET_MOUNT/sys" "$TARGET_MOUNT/dev"; do
    if awk '{print $2}' /proc/mounts | grep -Fxq "$mp"; then
      sudo umount -l "$mp" || warn "Failed to unmount $mp"
    fi
  done
  info "Install finished"
  if use_gui; then
    gui_yesno "Reboot now into the installed system?" && sudo reboot || info "Reboot skipped"
  else
    read -r -p "Reboot now? [y/N]: " yn
    case "${yn,,}" in y|yes) sudo reboot ;; *) info "Reboot skipped" ;; esac
  fi
}

# -------------------------
# Main interactive flow
# -------------------------
detect_env
log "Guix installer started at $TIMESTAMP"

# enforce nogui if requested
[ "${FORCE_NOGUI:-0}" -eq 1 ] && gui_cmd=""

if ! use_gui; then info "GUI not available; using text prompts"; fi

# GUI guided input or text fallback
if use_gui; then
  gui_info "Welcome to the Guix System installer. The wizard will guide you."

  if gui_yesno "Select a custom channels.scm file?"; then
    sel="$(gui_filechooserdialog file "Select channels.scm")"
    [ -n "$sel" ] && CHANNEL_SOURCE="$sel"
  fi

  if gui_yesno "Select a full custom config.scm file? (Cancel to use template)"; then
    sel="$(gui_filechooserdialog file "Select config.scm")"
    [ -n "$sel" ] && CONFIG_SOURCE="$sel"
  fi

  if gui_yesno "Install to a raw device (partition & format) instead of using an existing mountpoint?"; then
    # list devices
    if command -v lsblk >/dev/null 2>&1; then
      items="$(lsblk -dn -o NAME,SIZE,MODEL | awk '{printf "/dev/%s  %s  %s\n", $1,$2,$3}')"
      sel="$(gui_list_select "Select device" "Choose the block device" "$items")"
      [ -n "$sel" ] && TARGET_DEVICE="$sel" && TARGET_IS_DEVICE=1
    else
      TARGET_DEVICE="$(gui_entry "Device node (e.g. /dev/sda)" "/dev/sda" "Device")"
      TARGET_IS_DEVICE=1
    fi
  else
    sel="$(gui_filechooserdialog dir "Select or create mountpoint directory")"
    if [ -n "$sel" ]; then TARGET_MOUNT="$sel"; else TARGET_MOUNT="$(gui_entry "Enter target mountpoint" "/mnt/guix" "Mountpoint")"; fi
  fi

  TEMPLATE_HOST="$(gui_entry "Hostname for the new system" "$TEMPLATE_HOST" "Hostname")"
  TEMPLATE_USER="$(gui_entry "Primary username" "$TEMPLATE_USER" "Username")"
  TEMPLATE_LOCALE="$(gui_entry "Locale (eg en_US.UTF-8)" "$TEMPLATE_LOCALE" "Locale")"
  TEMPLATE_TZ="$(gui_entry "Timezone (eg America/Sao_Paulo)" "$TEMPLATE_TZ" "Timezone")"
  TEMPLATE_KB="$(gui_entry "Keyboard layout (eg br)" "$TEMPLATE_KB" "Keyboard")"
  # No need to ask for root device if we will set it automatically after partitioning

  if [ -n "$TARGET_DEVICE" ]; then
    gui_yesno "Target device: $TARGET_DEVICE. This will erase all data. Continue?" || { err "Aborted by user"; exit 1; }
  fi

else
  # text prompts
  if [ -z "$TARGET_DEVICE" ] && [ -z "$TARGET_MOUNT" ]; then
    read -r -p "Install to device or mountpoint? (device/mount) [mount]: " choice
    choice="${choice:-mount}"
    if [ "${choice,,}" = "device" ]; then
      read -r -p "Device node (eg /dev/sda): " TARGET_DEVICE
      TARGET_IS_DEVICE=1
    else
      read -r -p "Mountpoint (eg /mnt/guix): " TARGET_MOUNT
    fi
  fi

  read -r -p "Hostname [$TEMPLATE_HOST]: " in; TEMPLATE_HOST="${in:-$TEMPLATE_HOST}"
  read -r -p "Username [$TEMPLATE_USER]: " in; TEMPLATE_USER="${in:-$TEMPLATE_USER}"
  read -r -p "Locale [$TEMPLATE_LOCALE]: " in; TEMPLATE_LOCALE="${in:-$TEMPLATE_LOCALE}"
  read -r -p "Timezone [$TEMPLATE_TZ]: " in; TEMPLATE_TZ="${in:-$TEMPLATE_TZ}"
  read -r -p "Keyboard layout [$TEMPLATE_KB]: " in; TEMPLATE_KB="${in:-$TEMPLATE_KB}"

  if [ -n "$TARGET_DEVICE" ]; then
    read -r -p "Target device $TARGET_DEVICE will be erased. Continue? [y/N]: " yn
    case "${yn,,}" in y|yes) : ;; *) echo "Aborted"; exit 1 ;; esac
  fi
fi

# require root for device operations
if [ "${TARGET_IS_DEVICE:-0}" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  err "Device operations require root. Re-run with sudo."
  exit 1
fi

# install deps, ensure guix, prepare target, copy config & channels, run guix init
detect_env
install_minimum_deps || warn "Dependency step returned non-zero"
ensure_guix_available || warn "guix not available; guix required for system init"

ensure_target_mount
prepare_channels_and_config
prepare_and_run_init
finalize

exit 0
