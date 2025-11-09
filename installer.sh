#!/usr/bin/env bash
# WARNING DO NOT USE.
# TESTING ONLY!
# GNU GUIX UNIVERSAL INSTALLER
set -euo pipefail

# -------------------------
# Defaults & built-ins
# -------------------------
REPO_RAW_BASE="https://codeberg.org/berkeley/guix-install/raw/branch/main"
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

# Template variables (can be overridden via CLI)
TEMPLATE_LOCALE="en_US.UTF-8"
TEMPLATE_TZ="UTC"
TEMPLATE_KB="us"
TEMPLATE_HOST="guix-host"
TEMPLATE_USER="guix"
TEMPLATE_MAPPED="()"
TEMPLATE_ROOT_DEVICE="\"/dev/disk/by-label/root\""

# Bootstrapping fallback (may be adjusted by user)
BOOTSTRAP_GUIX_TARBALL_URL="https://ci.guix.gnu.org/nar/nar-info/guix-bootstrapped.tar.xz" # placeholder

# Built-in channels content (used if --channels not provided)
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

# Built-in minimal config.scm template (will have variables replaced)
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

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '\033[1;32m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m--\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m!!\033[0m %s\n' "$*"; }
dbg() { if [ "$DEBUG" -eq 1 ]; then printf '\033[1;35mDBG\033[0m %s\n' "$*"; fi; }

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  local prompt="${1:-Continue?}"
  local default="${2:-y}"
  if [ "$default" = "y" ]; then
    read -r -p "$prompt [Y/n]: " ans || exit 1
    case "${ans:-y}" in [Yy]|"") return 0;; *) return 1;; esac
  else
    read -r -p "$prompt [y/N]: " ans || exit 1
    case "${ans:-n}" in [Yy]) return 0;; *) return 1;; esac
  fi
}

is_url() {
  case "$1" in https?://*) return 0;; *) return 1;; esac
}

download() {
  local url="$1" dest="$2"
  dbg "download: $url -> $dest"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    return 1
  fi
}

# -------------------------
# Argument parsing
# -------------------------
usage() {
  cat <<EOF
Usage: $INSTALLER_NAME [options]

Options:
  --device DEVICE         Target raw block device (e.g. /dev/sda). Script will offer
                          to partition and format this device.
  --target MOUNTPOINT     Target mount point (e.g. /mnt/guix).
  --channels PATH|URL     Path or URL to channels.scm (default: built-in channels)
  --config PATH           Path or URL to a full config.scm (if provided, template is ignored)
  --locale LOCALE         Locale for config.scm (default: ${TEMPLATE_LOCALE})
  --tz TZ                 Timezone for config.scm (default: ${TEMPLATE_TZ})
  --keyboard LAYOUT       Keyboard layout for config.scm (default: ${TEMPLATE_KB})
  --host HOSTNAME         Hostname for config.scm (default: ${TEMPLATE_HOST})
  --username USERNAME     Primary username for config.scm (default: ${TEMPLATE_USER})
  --mapped MAPPED_EXPR    Mapped devices expression to insert in config.scm (default: empty)
  --root-device DEVICE    Root device expression to insert in config.scm (e.g. /dev/disk/by-label/root)
  --yes                   Assume yes to prompts (non-interactive)
  --skip-deps             Do not attempt to install distro bootstrap packages
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
    --root-device) TEMPLATE_ROOT_DEVICE="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

# -------------------------
# Environment detection
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

# -------------------------
# Bootstrap helpers
# -------------------------
install_minimum_deps() {
  if [ "$SKIP_DEPS" -eq 1 ]; then
    warn "Skipping distro dependency installation (--skip-deps)"
    return 0
  fi

  log "Installing minimal bootstrap dependencies (curl/wget, gnupg, tar, xz, gawk, git)"

  case "$PLATFORM" in
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y curl wget gnupg tar xz-utils gawk git parted util-linux findmnt || warn "apt install non-fatal"
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y curl wget gnupg2 tar xz gawk git parted util-linux findmnt || warn "dnf install non-fatal"
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm curl wget gnupg tar xz gawk git parted util-linux findmnt || warn "pacman non-fatal"
      elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y curl wget gpg2 tar xz gawk git parted util-linux findmnt || warn "zypper non-fatal"
      else
        warn "Unknown package manager; ensure required tools are installed manually"
      fi
      ;;
    bsd)
      if command -v pkg >/dev/null 2>&1; then
        sudo pkg install -y curl wget gnupg tar xz gawk git parted findmnt || warn "pkg non-fatal"
      else
        warn "BSD package manager not detected; ensure required tools are installed"
      fi
      ;;
    *)
      warn "Unknown platform; skipping dependency installation"
      ;;
  esac
}

ensure_guix_available() {
  if command -v guix >/dev/null 2>&1; then
    info "guix command is already available in the live environment"
    return 0
  fi

  log "Trying to install Guix from distribution packages (if available)"
  case "$PLATFORM" in
    linux)
      if command -v apt-get >/dev/null 2>&1 && apt-cache policy guix >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y guix && return 0 || warn "apt guix install failed"
      fi
      if command -v dnf >/dev/null 2>&1 && dnf list guix >/dev/null 2>&1; then
        sudo dnf install -y guix && return 0 || warn "dnf guix install failed"
      fi
      if command -v pacman >/dev/null 2>&1 && pacman -Ss guix >/dev/null 2>&1; then
        sudo pacman -S --noconfirm guix && return 0 || warn "pacman guix install failed"
      fi
      ;;
    bsd)
      if command -v pkg >/dev/null 2>&1 && pkg search guix >/dev/null 2>&1; then
        sudo pkg install -y guix && return 0 || warn "pkg guix install failed"
      fi
      ;;
  esac

  warn "Distribution Guix package not available or install failed. Attempting to bootstrap a temporary Guix from tarball."
  bootstrap_guix_from_tarball
}

bootstrap_guix_from_tarball() {
  local tarball="$TMPDIR/guix-bootstrap.tar.xz"
  info "Downloading Guix bootstrap tarball (may be slow)"
  if ! download "$BOOTSTRAP_GUIX_TARBALL_URL" "$tarball"; then
    warn "Failed to download bootstrap tarball from $BOOTSTRAP_GUIX_TARBALL_URL"
    return 1
  fi

  mkdir -p "$TMPDIR/guix-bootstrap"
  info "Extracting bootstrap tarball"
  tar -xJf "$tarball" -C "$TMPDIR/guix-bootstrap"
  if [ -d "$TMPDIR/guix-bootstrap/bin" ]; then
    export PATH="$TMPDIR/guix-bootstrap/bin:$PATH"
    info "Temporary guix added to PATH from bootstrap archive"
    if command -v guix >/dev/null 2>&1; then
      return 0
    fi
  fi
  warn "Bootstrap tarball did not provide a usable guix binary"
  return 1
}

# -------------------------
# Target preparation
# -------------------------
ensure_target_mount() {
  if [ -n "$TARGET_DEVICE" ]; then
    if [ "$TARGET_IS_DEVICE" -ne 1 ]; then TARGET_IS_DEVICE=1; fi
    if [ ! -b "$TARGET_DEVICE" ]; then
      err "Target device $TARGET_DEVICE is not a block device"
      exit 1
    fi

    info "Target device: $TARGET_DEVICE"
    if confirm "Partition and format $TARGET_DEVICE (will erase all data)?" "n"; then
      partition_and_format_device "$TARGET_DEVICE"
      mount_target_after_partition "$TARGET_DEVICE"
    else
      if [ -z "$TARGET_MOUNT" ]; then
        read -r -p "Enter mountpoint for existing target filesystem (e.g. /mnt/guix): " TARGET_MOUNT
      fi
      if [ ! -d "$TARGET_MOUNT" ]; then err "Mountpoint $TARGET_MOUNT does not exist"; exit 1; fi
      if ! mount | grep -qF "$TARGET_MOUNT"; then
        warn "$TARGET_MOUNT does not appear mounted; please mount and re-run"
        exit 1
      fi
    fi
  else
    if [ -z "$TARGET_MOUNT" ]; then
      err "No --device or --target provided. Please supply a target device or mountpoint."
      usage
      exit 1
    fi
    if [ ! -d "$TARGET_MOUNT" ]; then
      mkdir -p "$TARGET_MOUNT"
    fi
  fi

  if [ -z "$TARGET_MOUNT" ]; then
    TARGET_MOUNT="$(findmnt -n -o TARGET "$TARGET_DEVICE" 2>/dev/null || true)"
    if [ -z "$TARGET_MOUNT" ]; then
      warn "Could not determine mountpoint for $TARGET_DEVICE; please mount and re-run"
      exit 1
    fi
  fi
  info "Using target mountpoint: $TARGET_MOUNT"
}

partition_and_format_device() {
  local dev="$1"
  warn "This will destroy all data on $dev"
  if ! confirm "Proceed to partition and format $dev?"; then
    err "User aborted partitioning"
    exit 1
  fi

  if command -v parted >/dev/null 2>&1; then
    sudo parted -s "$dev" mklabel gpt
    sudo parted -s -a optimal "$dev" mkpart primary fat32 1MiB 512MiB
    sudo parted -s -a optimal "$dev" mkpart primary ext4 512MiB 100%
    sudo partprobe "$dev" || true
    # assume first partition is EFI, second is root
    local efipart="${dev}1"
    local rootpart="${dev}2"
    if [ ! -b "$rootpart" ] && [ -b "${dev}p2" ]; then rootpart="${dev}p2"; fi
    if [ ! -b "$efipart" ] && [ -b "${dev}p1" ]; then efipart="${dev}p1"; fi
    sudo mkfs.vfat -F32 -n EFI "$efipart"
    sudo mkfs.ext4 -F -L root "$rootpart"
    TARGET_MOUNT="${TARGET_MOUNT:-/mnt/guix}"
    mkdir -p "$TARGET_MOUNT"
    sudo mount "$rootpart" "$TARGET_MOUNT"
    mkdir -p "$TARGET_MOUNT/boot/efi"
    sudo mount "$efipart" "$TARGET_MOUNT/boot/efi"
    info "Created partitions and mounted root ($rootpart) at $TARGET_MOUNT and EFI ($efipart) at $TARGET_MOUNT/boot/efi"
  elif command -v sfdisk >/dev/null 2>&1; then
    echo "label: gpt" | sudo sfdisk "$dev"
    echo ",512M,U" | sudo sfdisk -a "$dev"
    echo ",,L" | sudo sfdisk -a "$dev"
    sudo partprobe "$dev" || true
    local rootpart="${dev}2"
    if [ ! -b "$rootpart" ] && [ -b "${dev}p2" ]; then rootpart="${dev}p2"; fi
    sudo mkfs.ext4 -F -L root "$rootpart"
    TARGET_MOUNT="${TARGET_MOUNT:-/mnt/guix}"
    mkdir -p "$TARGET_MOUNT"
    sudo mount "$rootpart" "$TARGET_MOUNT"
    info "Partitioned and mounted $rootpart at $TARGET_MOUNT"
  else
    err "No partitioning tool found (parted or sfdisk). Aborting."
    exit 1
  fi
}

mount_target_after_partition() {
  local dev="$1"
  local part="${dev}2"
  if [ ! -b "$part" ] && [ -b "${dev}p2" ]; then part="${dev}p2"; fi
  if [ ! -b "$part" ]; then err "Could not detect partition to mount for device $dev"; exit 1; fi
  TARGET_MOUNT="${TARGET_MOUNT:-/mnt/guix}"
  mkdir -p "$TARGET_MOUNT"
  sudo mount "$part" "$TARGET_MOUNT"
  info "Mounted $part at $TARGET_MOUNT"
}

# -------------------------
# Channel & config handling
# -------------------------
prepare_channels_and_config() {
  # channels
  if [ -n "$CHANNEL_SOURCE" ]; then
    if [ -f "$CHANNEL_SOURCE" ]; then
      CHANNEL_FILE="$CHANNEL_SOURCE"
      info "Using provided channels.scm: $CHANNEL_FILE"
    elif is_url "$CHANNEL_SOURCE"; then
      CHANNEL_FILE="$TMPDIR/channels.scm"
      download "$CHANNEL_SOURCE" "$CHANNEL_FILE" || { err "Failed to download channels.scm"; exit 1; }
      info "Downloaded channels.scm to $CHANNEL_FILE"
    else
      err "Channels source $CHANNEL_SOURCE not found or not a URL"
      exit 1
    fi
  else
    CHANNEL_FILE="$TMPDIR/channels.scm"
    printf "%s\n" "$BUILTIN_CHANNELS" > "$CHANNEL_FILE"
    info "Using builtin channels.scm"
  fi

  # config: if user provided a full config.scm, use it directly; otherwise, render template
  if [ -n "$CONFIG_SOURCE" ]; then
    if [ -f "$CONFIG_SOURCE" ]; then
      CONFIG_FILE="$CONFIG_SOURCE"
      info "Using provided config.scm: $CONFIG_FILE"
    elif is_url "$CONFIG_SOURCE"; then
      CONFIG_FILE="$TMPDIR/config.scm"
      download "$CONFIG_SOURCE" "$CONFIG_FILE" || { err "Failed to download config.scm"; exit 1; }
      info "Downloaded config.scm to $CONFIG_FILE"
    else
      err "Config source $CONFIG_SOURCE not found or not a URL"
      exit 1
    fi
  else
    CONFIG_FILE="$TMPDIR/config.scm"
    # Replace template placeholders safely. Ensure that ROOT_DEVICE is properly quoted in template when user passed a raw device
    # If TEMPLATE_ROOT_DEVICE looks like /dev/... and not quoted, wrap it in (file-system-label \"...\") won't be used; user provided expected expression.
    rendered="$BUILTIN_CONFIG_TEMPLATE"
    rendered="${rendered//\$LOCALE/${TEMPLATE_LOCALE}}"
    rendered="${rendered//\$TZ/${TEMPLATE_TZ}}"
    rendered="${rendered//\$KB/${TEMPLATE_KB}}"
    rendered="${rendered//\$HOST/${TEMPLATE_HOST}}"
    rendered="${rendered//\$USER/${TEMPLATE_USER}}"
    # MAPPED: insert raw expression (user must provide valid Scheme expression; default empty list)
    rendered="${rendered//\$MAPPED/${TEMPLATE_MAPPED}}"
    # ROOT_DEVICE: if TEMPLATE_ROOT_DEVICE is unquoted path like /dev/..., try to embed as (file-system-label "NAME") or raw; user can instead pass "\"/dev/disk/by-label/root\"" or similar.
    rendered="${rendered//\$ROOT_DEVICE/${TEMPLATE_ROOT_DEVICE}}"
    printf "%s\n" "$rendered" > "$CONFIG_FILE"
    info "Rendered config.scm to $CONFIG_FILE"
  fi

  # copy channels/config into target's /etc/guix and /root/.config/guix
  sudo mkdir -p "$TARGET_MOUNT/etc/guix" "$TARGET_MOUNT/root/.config/guix"
  sudo cp -f "$CHANNEL_FILE" "$TARGET_MOUNT/etc/guix/channels.scm"
  sudo cp -f "$CONFIG_FILE" "$TARGET_MOUNT/etc/guix/config.scm"
  sudo cp -f "$CHANNEL_FILE" "$TARGET_MOUNT/root/.config/guix/channels.scm"
  sudo cp -f "$CONFIG_FILE" "$TARGET_MOUNT/root/.config/guix/config.scm"
  info "Placed channels.scm and config.scm into target at /etc/guix and /root/.config/guix"
}

# -------------------------
# Prepare chroot / container
# -------------------------
prepare_and_run_init() {
  info "Preparing to run guix system init inside the target"

  ensure_guix_available || { err "guix is required; aborting"; exit 1; }

  sudo mkdir -p "$TARGET_MOUNT"/{proc,sys,dev,run,tmp}
  sudo mount --bind /dev "$TARGET_MOUNT/dev"
  sudo mount --bind /run "$TARGET_MOUNT/run" || true
  sudo mount -t proc proc "$TARGET_MOUNT/proc" || true
  sudo mount -t sysfs sys "$TARGET_MOUNT/sys" || true
  sudo mount --bind /tmp "$TARGET_MOUNT/tmp" || true

  if [ -f /etc/resolv.conf ]; then
    sudo cp -L /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"
  fi
  if [ -f /etc/hosts ]; then
    sudo cp -L /etc/hosts "$TARGET_MOUNT/etc/hosts"
  fi

  TMP_SCRIPT="$TMPDIR/run-guix-init.sh"
  cat > "$TMP_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONFIG="/etc/guix/config.scm"
CHANNELS="/etc/guix/channels.scm"
if [ -f /root/.config/guix/config.scm ]; then CONFIG="/root/.config/guix/config.scm"; fi
if [ -f /root/.config/guix/channels.scm ]; then CHANNELS="/root/.config/guix/channels.scm"; fi
echo "Inside target: guix pull --channels=$CHANNELS"
if command -v guix >/dev/null 2>&1; then
  guix pull --channels="$CHANNELS" || { echo "guix pull failed; continuing"; }
else
  echo "guix not found inside environment; initialization requires guix"
  exit 1
fi
echo "Running guix system init with config: $CONFIG"
guix system init "$CONFIG" /boot || { echo "guix system init failed"; exit 1; }
SH
  chmod +x "$TMP_SCRIPT"
  sudo cp "$TMP_SCRIPT" "$TARGET_MOUNT/root/run-guix-init.sh"
  sudo chown root:root "$TARGET_MOUNT/root/run-guix-init.sh"

  info "Starting guix system init inside target. This operation may take a long time."

  if command -v systemd-nspawn >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    info "Using systemd-nspawn to run initialization"
    sudo systemd-nspawn -D "$TARGET_MOUNT" /root/run-guix-init.sh || {
      warn "systemd-nspawn failed; falling back to chroot"
      sudo chroot "$TARGET_MOUNT" /root/run-guix-init.sh
    }
  else
    if [ "$(id -u)" -ne 0 ]; then
      warn "Not root; attempting sudo chroot (may fail)"
      sudo chroot "$TARGET_MOUNT" /root/run-guix-init.sh
    else
      chroot "$TARGET_MOUNT" /root/run-guix-init.sh
    fi
  fi

  info "guix system init finished (or attempted). Inspect output above for success or errors."
}

# -------------------------
# Post-installation steps
# -------------------------
finalize() {
  info "Cleaning up mounts"
  for mp in "$TARGET_MOUNT/tmp" "$TARGET_MOUNT/run" "$TARGET_MOUNT/proc" "$TARGET_MOUNT/sys" "$TARGET_MOUNT/dev"; do
    if mountpoint -q "$mp"; then
      sudo umount -l "$mp" || warn "Failed to unmount $mp"
    fi
  done

  info "Installation flow completed"
  if confirm "Reboot now into the installed system?"; then
    sudo reboot
  else
    info "Finish: unmount target and reboot later to boot into Guix System"
  fi
}

# -------------------------
# Main flow
# -------------------------
detect_env
log "Guix System universal installer (template-enabled) started at $TIMESTAMP"

if [ "$TARGET_IS_DEVICE" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  err "Device operations require root. Re-run with sudo"
  exit 1
fi

install_minimum_deps || warn "Dependency installation returned non-zero"
ensure_guix_available || warn "guix may not be available; guix is required for system init"

ensure_target_mount
prepare_channels_and_config
prepare_and_run_init
finalize

exit 0
