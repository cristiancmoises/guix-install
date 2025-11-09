#!/usr/bin/env bash
# DO NOT INSTALL THIS.
#
set -euo pipefail

# -------------------------
# Defaults and built-in content
# -------------------------
REPO_RAW_BASE="https://codeberg.org/berkeley/guix-install/raw/branch/main"
TMPDIR="$(mktemp -d /tmp/guix-installer.XXXXXX)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
INSTALLER_NAME="$(basename "$0")"

# State / options
TARGET_DEVICE=""
TARGET_MOUNT=""
TARGET_IS_DEVICE=0
CHANNEL_SOURCE=""
CONFIG_SOURCE=""
ASSUME_YES=0
SKIP_DEPS=0
DEBUG=0
FORCE_NOGUI=0

# Template defaults (overridable)
TEMPLATE_LOCALE="en_US.UTF-8"
TEMPLATE_TZ="UTC"
TEMPLATE_KB="us"
TEMPLATE_HOST="guix-host"
TEMPLATE_USER="guix"
TEMPLATE_MAPPED="()"
# Keep default string-based expression for cases where user doesn't pick a device.
# This will be overridden automatically when we partition a selected disk.
TEMPLATE_ROOT_DEVICE="\"/dev/disk/by-label/root\""

# Optional bootstrap tarball (user may edit)
BOOTSTRAP_GUIX_TARBALL_URL="https://ci.guix.gnu.org/nar/nar-info/guix-bootstrapped.tar.xz"

# Built-in channels (used when --channels not provided)
read -r -d '' BUILTIN_CHANNELS <<'SCM' || true
(use-modules (guix ci))
(list
  (channel-with-substitutes-available
    %default-guix-channel
    "https://ci.guix.gnu.org")
  (channel
    (name 'guix)
    (url "https://codeberg.org/guix/guix.git")
    (branch "master")
    (introduction
      (make-channel-introduction
        "9edb3f66fd807b096b48283debdcddccfea34bad"
        (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA"))))
  (channel
    (name 'nonguix)
    (url "https://gitlab.com/nonguix/nonguix")
    (branch "master")
    (commit "f9a27a679bd02fcebae69833b14ef54dff82ccf1")
    (introduction
      (make-channel-introduction
        "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
        (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5")))))
SCM

# Built-in config template (variables will be replaced)
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
# Logging & cleanup
# -------------------------
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '\033[1;32m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m--\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m!!\033[0m %s\n' "$*"; }
dbg()  { if [ "${DEBUG:-0}" -eq 1 ]; then printf '\033[1;35mDBG\033[0m %s\n' "$*"; fi; }

confirm_text() {
  if [ "${ASSUME_YES:-0}" -eq 1 ]; then return 0; fi
  read -r -p "$1 [y/N]: " ans || exit 1
  case "${ans,,}" in y|yes) return 0;; *) return 1;; esac
}

# -------------------------
# GUI helpers (zenity/yad) and fallback
# -------------------------
gui_cmd=""
use_gui() {
  if [ "${FORCE_NOGUI:-0}" -eq 1 ]; then return 1; fi
  if [ -n "$gui_cmd" ]; then return 0; fi
  if command -v zenity >/dev/null 2>&1; then gui_cmd=zenity; return 0; fi
  if command -v yad >/dev/null 2>&1; then gui_cmd=yad; return 0; fi
  return 1
}

gui_info() {
  local msg="$1"; local title="${2:-Installer}"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then zenity --info --no-wrap --title="$title" --text="$msg"; else yad --title="$title" --text="$msg" --button=OK:0; fi
  else
    info "$msg"
  fi
}

gui_error() {
  local msg="$1"; local title="${2:-Error}"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then zenity --error --title="$title" --text="$msg"; else yad --title="$title" --text="$msg" --button=OK:1; fi
  else
    err "$msg"
  fi
}

gui_yesno() {
  local prompt="$1"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then zenity --question --title="Confirm" --text="$prompt"; return $?; else yad --question --title="Confirm" --text="$prompt"; return $?; fi
  fi
  return 1
}

gui_entry() {
  local prompt="${1:-Input}" default="${2:-}" title="${3:-Input}"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then zenity --entry --title="$title" --text="$prompt" --entry-text="$default" || true; else yad --entry --title="$title" --text="$prompt" --entry="$default" || true; fi
  else
    read -r -p "$prompt [$default]: " val
    printf '%s' "${val:-$default}"
  fi
}

gui_filechooserdialog() {
  local prompt="$1" typ="${2:-file}" title="${3:-Choose file}"
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
  local title="$1"; local text="$2"; local items="$3"
  if use_gui; then
    if [ "$gui_cmd" = "zenity" ]; then
      echo -e "$items" | tr '\n' '|' | tr '|' '\n' | zenity --list --title="$title" --text="$text" --column=Option --height=300 --width=500 --print-column=1 2>/dev/null || true
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
# Utilities (download, mount detection)
# -------------------------
is_url() { case "$1" in https?://*) return 0;; *) return 1;; esac; }

download() {
  local url="$1" dest="$2"
  dbg "download: $url -> $dest"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$dest"; return $?; fi
  if command -v wget >/dev/null 2>&1; then wget -qO "$dest" "$url"; return $?; fi
  return 1
}

detect_mountpoint_for_device() {
  local dev="$1"
  [ -e "$dev" ] && dev="$(readlink -f "$dev")" || true
  if [ -f /proc/mounts ]; then
    while read -r devnode mp rest; do
      if [ "$devnode" = "$dev" ]; then printf '%s' "$mp"; return 0; fi
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
      if [ -n "${kv[NAME]-}" ]; then
        for candidate in "/dev/${kv[NAME]}" "/dev/mapper/${kv[NAME]}"; do
          if [ "$candidate" = "$dev" ] && [ -n "${kv[MOUNTPOINT]-}" ]; then printf '%s' "${kv[MOUNTPOINT]}"; return 0; fi
        done
      fi
    done < <(lsblk -P -o NAME,MOUNTPOINT 2>/dev/null || true)
  fi
  return 1
}

# -------------------------
# Argument parsing
# -------------------------
usage() {
  cat <<EOF
Usage: $INSTALLER_NAME [options]

Options:
  --device DEVICE         Target block device (e.g. /dev/sda) - will partition & format.
  --target MOUNTPOINT     Target mountpoint (e.g. /mnt/guix).
  --channels PATH|URL     Path or URL to channels.scm (preserved if provided).
  --config PATH|URL       Path or URL to full config.scm (preserved if provided).
  --locale LOCALE         Locale for template (default: $TEMPLATE_LOCALE)
  --tz TZ                 Timezone for template (default: $TEMPLATE_TZ)
  --keyboard LAYOUT       Keyboard layout for template (default: $TEMPLATE_KB)
  --host HOSTNAME         Hostname for template (default: $TEMPLATE_HOST)
  --username USERNAME     Primary username for template (default: $TEMPLATE_USER)
  --mapped MAPPED_EXPR    Mapped devices Scheme expression to insert in template
  --nogui                 Force non-graphical mode
  --yes                   Assume yes to prompts
  --skip-deps             Skip installing distro dependencies
  --debug                 Enable debug output
  -h, --help              Show this help
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
    --locale) TEMPLATE_LOCALE="$2"; shift 2 ;;
    --tz) TEMPLATE_TZ="$2"; shift 2 ;;
    --keyboard) TEMPLATE_KB="$2"; shift 2 ;;
    --host) TEMPLATE_HOST="$2"; shift 2 ;;
    --username) TEMPLATE_USER="$2"; shift 2 ;;
    --mapped) TEMPLATE_MAPPED="$2"; shift 2 ;;
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
  case "$OS" in
    Linux) PLATFORM="linux" ;;
    FreeBSD|OpenBSD|NetBSD|DragonFly) PLATFORM="bsd" ;;
    *) PLATFORM="unknown" ;;
  esac
  dbg "Platform: $PLATFORM"
}

install_minimum_deps() {
  if [ "$SKIP_DEPS" -eq 1 ]; then warn "Skipping distro dependency installation"; return 0; fi
  log "Installing minimum dependencies: curl wget gnupg tar xz-utils gawk git parted util-linux"
  case "$PLATFORM" in
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y curl wget gnupg tar xz-utils gawk git parted util-linux || warn "apt install non-fatal"
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y curl wget gnupg2 tar xz gawk git parted util-linux || warn "dnf install non-fatal"
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm curl wget gnupg tar xz gawk git parted util-linux || warn "pacman non-fatal"
      else
        warn "Unknown package manager; ensure tools are present"
      fi
      ;;
    bsd)
      if command -v pkg >/dev/null 2>&1; then
        sudo pkg install -y curl wget gnupg tar xz gawk git parted || warn "pkg non-fatal"
      else
        warn "BSD package manager not detected"
      fi
      ;;
  esac
}

ensure_guix_available() {
  if command -v guix >/dev/null 2>&1; then info "guix available"; return 0; fi
  log "Trying to install guix from distro packages"
  case "$PLATFORM" in
    linux)
      if command -v apt-get >/dev/null 2>&1 && apt-cache policy guix >/dev/null 2>&1; then sudo apt-get update -y; sudo apt-get install -y guix && return 0 || warn "apt guix failed"; fi
      if command -v dnf >/dev/null 2>&1 && dnf list guix >/dev/null 2>&1; then sudo dnf install -y guix && return 0 || warn "dnf guix failed"; fi
      if command -v pacman >/dev/null 2>&1 && pacman -Qs guix >/dev/null 2>&1; then sudo pacman -S --noconfirm guix && return 0 || warn "pacman guix failed"; fi
      ;;
    bsd)
      if command -v pkg >/dev/null 2>&1 && pkg search guix >/dev/null 2>&1; then sudo pkg install -y guix && return 0 || warn "pkg guix failed"; fi
      ;;
  esac
  warn "Distro guix not available or failed; attempting bootstrap tarball"
  bootstrap_guix_from_tarball
}

bootstrap_guix_from_tarball() {
  local tarball="$TMPDIR/guix-bootstrap.tar.xz"
  info "Downloading bootstrap tarball (may be large)"
  if ! download "$BOOTSTRAP_GUIX_TARBALL_URL" "$tarball"; then warn "Failed download"; return 1; fi
  mkdir -p "$TMPDIR/guix-bootstrap"
  info "Extracting bootstrap tarball"
  tar -xJf "$tarball" -C "$TMPDIR/guix-bootstrap"
  if [ -d "$TMPDIR/guix-bootstrap/bin" ]; then
    export PATH="$TMPDIR/guix-bootstrap/bin:$PATH"
    info "Temporary guix added to PATH"
    command -v guix >/dev/null 2>&1 && return 0 || warn "guix not in bootstrap"
  fi
  return 1
}

# -------------------------
# Target preparation and mount detection
# -------------------------
ensure_target_mount() {
  if [ -n "$TARGET_DEVICE" ]; then
    [ -b "$TARGET_DEVICE" ] || { err "Target device $TARGET_DEVICE not found"; exit 1; }
    info "Target device: $TARGET_DEVICE"
    if use_gui && gui_yesno "Partition and format $TARGET_DEVICE (will erase all data)?"; then
      true
    else
      if ! use_gui && ! confirm_text "Partition and format $TARGET_DEVICE (will erase all data)?"; then
        :
      fi
    fi
    if [ "$ASSUME_YES" -eq 0 ]; then
      if use_gui; gui_yesno "Proceed to partition and format $TARGET_DEVICE?" || { info "User cancelled"; exit 1; }; else confirm_text "Proceed to partition and format $TARGET_DEVICE?" || { info "User cancelled"; exit 1; }; fi
    fi
    partition_and_format_device "$TARGET_DEVICE"
    mount_target_after_partition "$TARGET_DEVICE"
  else
    if [ -z "$TARGET_MOUNT" ]; then
      if use_gui; TARGET_MOUNT="$(gui_filechooserdialog "Select or create a target directory to install into" "dir" "Target mount")"; fi
      if [ -z "$TARGET_MOUNT" ]; then err "No --device or --target provided"; usage; exit 1; fi
    fi
    [ -d "$TARGET_MOUNT" ] || mkdir -p "$TARGET_MOUNT"
  fi
  # try to detect mountpoint if user gave device but didn't mount
  if [ -z "$TARGET_MOUNT" ] && [ -n "$TARGET_DEVICE" ]; then
    TARGET_MOUNT="$(detect_mountpoint_for_device "$TARGET_DEVICE" || true)"
    [ -n "$TARGET_MOUNT" ] || { err "Could not determine mountpoint for device; please mount and re-run"; exit 1; }
  fi
  info "Using target mountpoint: $TARGET_MOUNT"
}

partition_and_format_device() {
  local dev="$1"
  warn "This will destroy all data on $dev"
  if [ "$ASSUME_YES" -eq 0 ]; then
    if use_gui; gui_yesno "Do you really want to partition and format $dev?"; else confirm_text "Do you really want to partition and format $dev?"; fi
  fi
  if command -v parted >/dev/null 2>&1; then
    sudo parted -s "$dev" mklabel gpt
    sudo parted -s -a optimal "$dev" mkpart primary fat32 1MiB 512MiB
    sudo parted -s -a optimal "$dev" mkpart primary ext4 512MiB 100%
    sudo partprobe "$dev" || true
    local efipart="${dev}1" rootpart="${dev}2"
    if [ ! -b "$rootpart" ] && [ -b "${dev}p2" ]; then rootpart="${dev}p2"; fi
    if [ ! -b "$efipart" ] && [ -b "${dev}p1" ]; then efipart="${dev}p1"; fi
    [ -b "$rootpart" ] || { err "Root partition not found after partitioning"; exit 1; }
    if [ -b "$efipart" ]; then sudo mkfs.vfat -F32 -n EFI "$efipart"; info "Formatted EFI $efipart"; fi
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
    if [ ! -b "$rootpart" ] && [ -b "${dev}p2" ]; then rootpart="${dev}p2"; fi
    [ -b "$rootpart" ] || { err "Root partition not found after sfdisk"; exit 1; }
    sudo mkfs.ext4 -F -L root "$rootpart"
    TARGET_MOUNT="${TARGET_MOUNT:-/mnt/guix}"
    mkdir -p "$TARGET_MOUNT"
    sudo mount "$rootpart" "$TARGET_MOUNT"
  else
    err "No partitioning tool (parted or sfdisk) available"
    exit 1
  fi

  # Automatically set the Root Device expression to the scheme expression that
  # resolves by label "root" so users do not need to enter it manually.
  TEMPLATE_ROOT_DEVICE='(file-system-label "root")'
  info "Automatically set Root Device expression to: $TEMPLATE_ROOT_DEVICE"

  info "Partitioning and formatting done; mounted root at $TARGET_MOUNT"
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
# Channels and config handling
# -------------------------
prepare_channels_and_config() {
  # channels
  if [ -n "$CHANNEL_SOURCE" ]; then
    if [ -f "$CHANNEL_SOURCE" ]; then CHANNEL_FILE="$CHANNEL_SOURCE"; info "Using user channels.scm: $CHANNEL_FILE"
    elif is_url "$CHANNEL_SOURCE"; then CHANNEL_FILE="$TMPDIR/channels.scm"; download "$CHANNEL_SOURCE" "$CHANNEL_FILE" || { err "Failed to download channels.scm"; exit 1; }; info "Downloaded channels.scm"
    else err "channels.scm source not found"; exit 1; fi
  else
    CHANNEL_FILE="$TMPDIR/channels.scm"; printf "%s\n" "$BUILTIN_CHANNELS" > "$CHANNEL_FILE"; info "Using built-in channels.scm"
  fi

  # config
  if [ -n "$CONFIG_SOURCE" ]; then
    if [ -f "$CONFIG_SOURCE" ]; then CONFIG_FILE="$CONFIG_SOURCE"; info "Using user config.scm: $CONFIG_FILE"
    elif is_url "$CONFIG_SOURCE"; then CONFIG_FILE="$TMPDIR/config.scm"; download "$CONFIG_SOURCE" "$CONFIG_FILE" || { err "Failed to download config.scm"; exit 1; }; info "Downloaded config.scm"
    else err "config.scm source not found"; exit 1; fi
  else
    CONFIG_FILE="$TMPDIR/config.scm"
    rendered="$BUILTIN_CONFIG_TEMPLATE"
    rendered="${rendered//\$LOCALE/${TEMPLATE_LOCALE}}"
    rendered="${rendered//\$TZ/${TEMPLATE_TZ}}"
    rendered="${rendered//\$KB/${TEMPLATE_KB}}"
    rendered="${rendered//\$HOST/${TEMPLATE_HOST}}"
    rendered="${rendered//\$USER/${TEMPLATE_USER}}"
    rendered="${rendered//\$MAPPED/${TEMPLATE_MAPPED}}"
    rendered="${rendered//\$ROOT_DEVICE/${TEMPLATE_ROOT_DEVICE}}"
    printf "%s\n" "$rendered" > "$CONFIG_FILE"
    info "Rendered config.scm (template) to $CONFIG_FILE"
  fi

  sudo mkdir -p "$TARGET_MOUNT/etc/guix" "$TARGET_MOUNT/root/.config/guix"
  sudo cp -f "$CHANNEL_FILE" "$TARGET_MOUNT/etc/guix/channels.scm"
  sudo cp -f "$CONFIG_FILE" "$TARGET_MOUNT/etc/guix/config.scm"
  sudo cp -f "$CHANNEL_FILE" "$TARGET_MOUNT/root/.config/guix/channels.scm"
  sudo cp -f "$CONFIG_FILE" "$TARGET_MOUNT/root/.config/guix/config.scm"
  info "Copied channels.scm and config.scm into target"
}

# -------------------------
# Run guix system init inside target
# -------------------------
prepare_and_run_init() {
  info "Preparing to run guix system init inside target"

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
  guix pull --channels="$CHANNELS" || echo "guix pull failed but continuing"
else
  echo "guix not found inside environment; aborting" >&2; exit 1
fi
echo "Running guix system init with config: $CONFIG"
guix system init "$CONFIG" /boot || { echo "guix system init failed"; exit 1; }
SH
  chmod +x "$TMP_SCRIPT"
  sudo cp "$TMP_SCRIPT" "$TARGET_MOUNT/root/run-guix-init.sh"
  sudo chown root:root "$TARGET_MOUNT/root/run-guix-init.sh"

  info "Executing guix system init inside target (may take long)"
  if command -v systemd-nspawn >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    sudo systemd-nspawn -D "$TARGET_MOUNT" /root/run-guix-init.sh || { warn "systemd-nspawn failed; falling back to chroot"; sudo chroot "$TARGET_MOUNT" /root/run-guix-init.sh; }
  else
    if [ "$(id -u)" -ne 0 ]; then warn "Not root; attempting sudo chroot (may fail)"; sudo chroot "$TARGET_MOUNT" /root/run-guix-init.sh; else chroot "$TARGET_MOUNT" /root/run-guix-init.sh; fi
  fi

  info "guix system init completed or attempted; check output for errors"
}

# -------------------------
# Final cleanup
# -------------------------
finalize() {
  info "Cleaning up mounts"
  for mp in "$TARGET_MOUNT/tmp" "$TARGET_MOUNT/run" "$TARGET_MOUNT/proc" "$TARGET_MOUNT/sys" "$TARGET_MOUNT/dev"; do
    if awk '{print $2}' /proc/mounts | grep -Fxq "$mp"; then sudo umount -l "$mp" || warn "Failed to unmount $mp"; fi
  done
  info "Installation finished"
  if use_gui && gui_yesno "Reboot now into the installed system?"; then sudo reboot; else if ! use_gui && confirm_text "Reboot now into the installed system?"; then sudo reboot; else info "Remember to unmount the target before rebooting elsewhere"; fi
}

# -------------------------
# Main flow with GUI prompts
# -------------------------
detect_env
log "Guix System installer started at $TIMESTAMP"

# Force nogui if requested
if [ "$FORCE_NOGUI" -eq 1 ]; then gui_cmd=""; fi

# Inform about GUI availability
if ! use_gui; then info "GUI dialog tools (zenity/yad) not found or disabled; using text prompts"; fi

# Guided GUI flow or text prompts to collect inputs
if use_gui; then
  gui_info "Welcome to the Guix System installer. This wizard will help you install Guix System onto a target device or mountpoint."
  # Channels selection
  if gui_yesno "Do you want to select a custom channels.scm file?"; then
    sel="$(gui_filechooserdialog "Select channels.scm file (Cancel to skip)" "file" "Select channels.scm")"
    [ -n "$sel" ] && CHANNEL_SOURCE="$sel"
  fi
  # Config selection
  if gui_yesno "Do you want to select a full custom config.scm file? (Cancel to use template)"; then
    sel="$(gui_filechooserdialog "Select config.scm file (Cancel to use template)" "file" "Select config.scm")"
    [ -n "$sel" ] && CONFIG_SOURCE="$sel"
  fi
  # Device or mountpoint
  if gui_yesno "Install to a raw device (partition & format)?"; then
    # list devices via lsblk for selection
    if command -v lsblk >/dev/null 2>&1; then
      items="$(lsblk -dn -o NAME,SIZE,MODEL | sed 's/^/\/dev\//')"
      sel="$(gui_list_select "Select device" "Choose the block device to partition and format" "$items")"
      if [ -n "$sel" ]; then TARGET_DEVICE="$sel"; TARGET_IS_DEVICE=1; fi
    else
      TARGET_DEVICE="$(gui_entry "Enter device node (e.g. /dev/sda)" "/dev/sda" "Device")"; TARGET_IS_DEVICE=1
    fi
  else
    sel="$(gui_filechooserdialog "Select or create a mountpoint directory to install into" "dir" "Target mount")"
    if [ -n "$sel" ]; then TARGET_MOUNT="$sel"; else TARGET_MOUNT="$(gui_entry "Enter target mountpoint (e.g. /mnt/guix)" "/mnt/guix" "Mountpoint")"; fi
  fi
  # Template variables
  TEMPLATE_HOST="$(gui_entry "Hostname for the new system" "$TEMPLATE_HOST" "Hostname")"
  TEMPLATE_USER="$(gui_entry "Primary username" "$TEMPLATE_USER" "Username")"
  TEMPLATE_LOCALE="$(gui_entry "Locale (e.g. en_US.UTF-8)" "$TEMPLATE_LOCALE" "Locale")"
  TEMPLATE_TZ="$(gui_entry "Timezone (e.g. America/Sao_Paulo)" "$TEMPLATE_TZ" "Timezone")"
  TEMPLATE_KB="$(gui_entry "Keyboard layout (e.g. br, us)" "$TEMPLATE_KB" "Keyboard")"
  # Root Device prompt removed entirely; it will be set automatically if the user selects a device.

  # Confirm destructive operation if device
  if [ -n "$TARGET_DEVICE" ]; then gui_yesno "Target device: $TARGET_DEVICE. This will erase all data. Continue?" || { gui_error "Aborted by user"; exit 1; }; fi
else
  # Text mode prompts
  if [ -z "$TARGET_DEVICE" ] && [ -z "$TARGET_MOUNT" ]; then
    read -r -p "Install to device or mountpoint? (device/mount) [mount]: " choice
    choice="${choice:-mount}"
    if [ "${choice,,}" = "device" ]; then read -r -p "Device node (e.g. /dev/sda): " TARGET_DEVICE; TARGET_IS_DEVICE=1; else read -r -p "Mountpoint (e.g. /mnt/guix): " TARGET_MOUNT; fi
  fi
  read -r -p "Hostname [$TEMPLATE_HOST]: " in; TEMPLATE_HOST="${in:-$TEMPLATE_HOST}"
  read -r -p "Username [$TEMPLATE_USER]: " in; TEMPLATE_USER="${in:-$TEMPLATE_USER}"
  read -r -p "Locale [$TEMPLATE_LOCALE]: " in; TEMPLATE_LOCALE="${in:-$TEMPLATE_LOCALE}"
  read -r -p "Timezone [$TEMPLATE_TZ]: " in; TEMPLATE_TZ="${in:-$TEMPLATE_TZ}"
  read -r -p "Keyboard [$TEMPLATE_KB]: " in; TEMPLATE_KB="${in:-$TEMPLATE_KB}"
  # Root Device prompt removed entirely.
  if [ -n "$TARGET_DEVICE" ]; then confirm_text "Target device $TARGET_DEVICE will be erased. Continue?" || { echo "Aborted"; exit 1; }; fi
fi

# Ensure root when device ops requested
if [ "$TARGET_IS_DEVICE" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  gui_error "Device operations require root. Re-run with sudo." "Need root"
  exit 1
fi

# Run main steps
detect_env
install_minimum_deps || warn "Dependency step returned non-zero"
ensure_guix_available || warn "guix may not be available; required for system init"

ensure_target_mount
prepare_channels_and_config
prepare_and_run_init
finalize

exit 0
