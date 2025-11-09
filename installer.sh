#!/bin/sh

set -euo pipefail

# ───── Constants ─────
TMPDIR="$(mktemp -d /tmp/guix-installer.XXXXXX)"
INSTALLER_NAME="$(basename "$0")"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

USER_ONLY=0
NO_DAEMON=0
SKIP_DEPS=0
ASSUME_YES=0
DEBUG=0

# ───── Helpers ─────
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '\033[1;32m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m--\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m!!\033[0m %s\n' "$*"; exit 1; }
dbg() { [ "$DEBUG" -eq 1 ] && printf '\033[1;35mDBG\033[0m %s\n' "$*"; }

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  local prompt="${1:-Continue?}" default="${2:-y}"
  if [ "$default" = "y" ]; then
    read -r -p "$prompt [Y/n]: " ans
    case "${ans:-y}" in [Yy]|"") return 0;; *) return 1;; esac
  else
    read -r -p "$prompt [y/N]: " ans
    case "${ans:-n}" in [Yy]) return 0;; *) return 1;; esac
  fi
}

run_cmd() {
  dbg "+ $*"
  eval "$@" || err "Command failed: $*"
}

download_file() {
  local url="$1" dest="$2"
  dbg "Download: $url -> $dest"
  if command -v curl >/dev/null; then
    curl -fsSL "$url" -o "$dest" && return 0
  elif command -v wget >/dev/null; then
    wget -q -O "$dest" "$url" && return 0
  fi
  err "No curl/wget"
}

# ───── Arguments ─────
usage() {
  cat <<EOF
Usage: $INSTALLER_NAME [options]
Options:
  --user-only    User-only install (no daemon)
  --no-daemon    Skip daemon (implies --user-only)
  --skip-deps    Skip dependencies
  --yes          Assume yes
  --debug        Debug mode
  -h, --help     Help
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user-only) USER_ONLY=1; shift ;;
    --no-daemon) NO_DAEMON=1; USER_ONLY=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage ;;
    *) warn "Unknown: $1"; shift ;;
  esac
done

# ───── Platform ─────
detect_platform() {
  OS="$(uname -s)"
  case "$OS" in
    Linux) PLATFORM="linux" ;;
    *BSD*) PLATFORM="bsd" ;;
    *) err "Unsupported OS" ;;
  esac

  DISTRO="unknown"
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="${ID:-$NAME}"
  fi

  dbg "Platform=$PLATFORM Distro=$DISTRO"
}

# ───── Dependencies ─────
install_deps() {
  if [ "$SKIP_DEPS" -eq 1 ]; then warn "Skipping deps"; return; fi

  PKGS="curl wget ca-certificates gnupg git xz-utils dialog"
  case "$PLATFORM" in
    linux)
      case "$DISTRO" in
        ubuntu|debian) run_cmd "apt update && apt install -y $PKGS" ;;
        fedora) run_cmd "dnf install -y $PKGS" ;;
        arch) run_cmd "pacman -Sy --noconfirm $PKGS" ;;
        opensuse*) run_cmd "zypper install -y $PKGS" ;;
        alpine) run_cmd "apk add $PKGS" ;;
        void) run_cmd "xbps-install -Sy $PKGS" ;;
        *) warn "Unknown distro; install manually: $PKGS" ;;
      esac
      ;;
    bsd)
      case "$OS" in
        FreeBSD|DragonFly) run_cmd "pkg install -y $PKGS" ;;
        OpenBSD) run_cmd "pkg_add $PKGS" ;;
      esac
      ;;
  esac
}

# ───── Channels ─────
prepare_channels() {
  CHANNEL_FILE="$TMPDIR/channels.scm"
  info "Embedding channels.scm"
  cat > "$CHANNEL_FILE" <<'EOF'
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
    (name 'guix-xlibre)
    (url "https://gitlab.vulnix.sh/spacecadet/guix-xlibre.git")
    (branch "master"))
  (channel
    (name 'small-guix)
    (url "https://codeberg.org/fishinthecalculator/small-guix.git")
    (branch "main")
    (introduction
     (make-channel-introduction
      "f260da13666cd41ae3202270784e61e062a3999c"
      (openpgp-fingerprint
       "8D10 60B9 6BB8 292E 829B 7249 AED4 1CC1 93B7 01E2"))))
  (channel
   (name 'saayix)
   (branch "main")
   (url "https://codeberg.org/look/saayix")
   (introduction
    (make-channel-introduction
     "12540f593092e9a177eb8a974a57bb4892327752"
     (openpgp-fingerprint
      "3FFA 7335 973E 0A49 47FC 0A8C 38D5 96BE 07D3 34AB"))))
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
EOF
}

# ───── User setup ─────
backup_existing() {
  local target="$1"
  if [ -e "$target" ]; then
    mv "$target" "${target}.bak.${TIMESTAMP}"
    info "Backed up $target"
  fi
}

user_setup() {
  info "User setup"
  mkdir -p "$HOME/.config/guix"
  backup_existing "$HOME/.config/guix/channels.scm"
  cp "$CHANNEL_FILE" "$HOME/.config/guix/channels.scm"

  cfg="$HOME/.config/guix/config.scm"
  if [ ! -f "$cfg" ]; then
    cat > "$cfg" <<EOF
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
             (guix build-system gnu)
             (nongnu packages linux)
             (nongnu system linux-initrd))

(use-package-modules
  certs fonts gnome gtk pulseaudio audio linux
  bash coreutils findutils grep sed gawk tar xz
  curl wget git openssh rsync
  nss-certs)

(use-service-modules
  desktop xorg networking ssh avahi
  dbus dbus-root)

(operating-system
  (kernel linux)
  (firmware (list linux-firmware))
  (initrd microcode-initrd)
  (locale "$LOCALE")
  (timezone "$TZ")
  (keyboard-layout (keyboard-layout "$KB"))
  (host-name "$HOST")
  (users (cons* (user-account
                 (name "$USER")
                 (group "users")
                 (supplementary-groups '("wheel" "netdev" "audio" "video" "cdrom" "kvm")))
                %base-user-accounts))
  (packages (append (list nss-certs font-dejavu font-gnu-freefont
                          gnome gnome-tweaks pulseaudio pavucontrol
                          bash-completion git curl wget rsync openssh)
                    %base-packages))
  (services
   (append
     (list
       (service gnome-desktop-service-type)
       (service gdm-service-type)
       (service network-manager-service-type)
       (service wpa-supplicant-service-type)
       (service avahi-service-type)
       (service openssh-service-type
                (openssh-configuration
                  (openssh openssh)
                  (port-number 22)))
       (service bluetooth-service-type)
       (service thermald-service-type)
       (service tlp-service-type)
       (service docker-service-type))
     %desktop-services))
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets '("/boot/efi"))
                (keyboard-layout keyboard-layout)))
  (mapped-devices $MAPPED)
  (file-systems (cons*
                 (file-system
                   (mount-point "/boot/efi")
                   (device (file-system-label "EFI"))
                   (type "vfat"))
                 (file-system
                   (mount-point "/")
                   (device $ROOT_DEVICE)
                   (type "ext4"))
                 %base-file-systems)))
EOF
    info "Wrote $cfg"
  fi

  add_profile_snippet
}

add_profile_snippet() {
  snippet='
# Guix profile
GUIX_PROFILE="$HOME/.guix-profile"
[ -f "$GUIX_PROFILE/etc/profile" ] && . "$GUIX_PROFILE/etc/profile"
'
  if ! grep -q "Guix profile" "$HOME/.profile" 2>/dev/null; then
    echo "$snippet" >> "$HOME/.profile"
    info "Added to ~/.profile"
  fi
}

# ───── Daemon ─────
daemon_setup() {
  if [ "$NO_DAEMON" -eq 1 ] || [ "$(id -u)" -ne 0 ]; then return; fi

  if command -v guix-daemon >/dev/null; then
    if command -v systemctl >/dev/null; then
      run_cmd "systemctl enable --now guix-daemon"
    elif [ -d /etc/init.d ]; then
      run_cmd "/etc/init.d/guix-daemon start"
    fi
  else
    warn "guix-daemon not found"
  fi
}

# ───── Pull channels ─────
pull_channels() {
  if command -v guix >/dev/null; then
    guix pull --channels="$HOME/.config/guix/channels.scm"
  else
    warn "guix not found; pull later"
  fi
}

# ───── Post note ─────
post_note() {
  cat <<EOF
Done!
Channels: $HOME/.config/guix/channels.scm
Config: $HOME/.config/guix/config.scm
Source ~/.profile
To pull: guix pull --channels=~/.config/guix/channels.scm
Install example: guix install hello
EOF
}

# ───── Main ─────
main() {
  detect_platform
  install_deps
  prepare_channels
  if [ "$OS" != "Linux" ]; then post_note; exit 0; fi
  if [ -f /etc/config.scm ]; then
    if confirm "Reconfigure system?"; then
      guix system reconfigure /etc/config.scm
      post_note
    fi
    exit 0
  fi
  user_setup
  daemon_setup
  pull_channels
  post_note
}

main
