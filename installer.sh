#!/usr/bin/env bash
# GNU GUIX - UNIVERSAL INSTALLER
set -euo pipefail

# -------------------------
# Configuration defaults
# -------------------------
REPO_RAW_BASE="https://codeberg.org/berkeley/guix-install/raw/branch/main"
DEFAULT_CHANNEL_REMOTE="${REPO_RAW_BASE}/channels.scm"
ALT_CHANNEL_REMOTE="${REPO_RAW_BASE}/channel.scm"
TMPDIR="$(mktemp -d /tmp/guix-installer.XXXXXX)"
INSTALLER_NAME="$(basename "$0")"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

USER_ONLY=0
NO_DAEMON=0
SKIP_DEPS=0
CHANNEL_SOURCE=""   # local path or URL to channels.scm or channel.scm
ASSUME_YES=0
DEBUG=0

CURL_OPTS="-fsSL"
WGET_OPTS="-qO-"

# -------------------------
# Built-in channels content
# -------------------------
# If user does not supply a channels.scm, this content will be written and used.
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

# -------------------------
# Helpers
# -------------------------
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

log()    { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info()   { printf '\033[1;32m::\033[0m %s\n' "$*"; }
warn()   { printf '\033[1;33m--\033[0m %s\n' "$*"; }
err()    { printf '\033[1;31m!!\033[0m %s\n' "$*"; }
dbg()    { if [ "$DEBUG" -eq 1 ]; then printf '\033[1;35mDBG\033[0m %s\n' "$*"; fi; }

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
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

run_cmd() {
  if [ "$DEBUG" -eq 1 ]; then
    printf '+ %s\n' "$*"
  fi
  eval "$@"
}

download_file() {
  local url="$1" dest="$2"
  dbg "download_file: $url -> $dest"
  if command -v curl >/dev/null 2>&1; then
    curl $CURL_OPTS "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget $WGET_OPTS "$url" > "$dest"
  else
    return 1
  fi
}

is_url() {
  case "$1" in https?://*) return 0;; *) return 1;; esac
}

# -------------------------
# Argument parsing
# -------------------------
usage() {
  cat <<EOF
Usage: $INSTALLER_NAME [options]
Options:
  --user-only          Install only for the current user (no system daemon)
  --no-daemon          Do not attempt to install/enable guix-daemon (implies --user-only)
  --skip-deps          Skip installing distro dependencies
  --channels PATH|URL  Use specified channels.scm or channel.scm (local path or URL)
  --yes                Assume yes to all prompts
  --debug              Enable debug output
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user-only) USER_ONLY=1; shift ;;
    --no-daemon) NO_DAEMON=1; USER_ONLY=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --channels) CHANNEL_SOURCE="${2:-}"; shift 2 ;;
    --channels=*) CHANNEL_SOURCE="${1#*=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# -------------------------
# Environment detection
# -------------------------
detect_platform() {
  OS="$(uname -s)"
  case "$OS" in
    Linux) PLATFORM="linux" ;;
    FreeBSD|OpenBSD|NetBSD|DragonFly) PLATFORM="bsd" ;;
    *) PLATFORM="unknown" ;;
  esac

  DISTRO="unknown"
  if [ -f /etc/os-release ]; then
    . /etc/os-release || true
    DISTRO="${ID:-${NAME:-unknown}}"
  fi

  # detect graphical session presence
  if [ -n "${WAYLAND_DISPLAY-}" ] || [ "${XDG_SESSION_TYPE-}" = "wayland" ]; then
    GRAPHICAL="wayland"
  elif [ -n "${DISPLAY-}" ] || [ -n "${XAUTHORITY-}" ]; then
    GRAPHICAL="x11"
  else
    # best-effort check
    if pgrep -x Xorg >/dev/null 2>&1 || pgrep -x Xwayland >/dev/null 2>&1 || pgrep -f wayland >/dev/null 2>&1; then
      GRAPHICAL="detected"
    else
      GRAPHICAL="none"
    fi
  fi
  dbg "Platform=$PLATFORM Distro=$DISTRO Graphical=$GRAPHICAL"
}

# -------------------------
# Dependency installers
# -------------------------
install_minimum_deps() {
  if [ "$SKIP_DEPS" -eq 1 ]; then
    warn "Skipping dependency installation (--skip-deps)"
    return 0
  fi

  # minimal deps needed to download things: curl/wget, ca-certificates, gnupg
  case "$PLATFORM" in
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        PKGS="curl wget ca-certificates gnupg git xz"
        info "Installing dependencies via apt: $PKGS"
        sudo apt-get update -y
        sudo apt-get install -y $PKGS || warn "apt-get install returned non-zero"
      elif command -v dnf >/dev/null 2>&1; then
        PKGS="curl wget ca-certificates gnupg2 git xz"
        info "Installing dependencies via dnf: $PKGS"
        sudo dnf install -y $PKGS || warn "dnf install returned non-zero"
      elif command -v pacman >/dev/null 2>&1; then
        PKGS="curl wget ca-certificates gnupg git xz"
        info "Installing dependencies via pacman: $PKGS"
        sudo pacman -Sy --noconfirm $PKGS || warn "pacman install returned non-zero"
      elif command -v zypper >/dev/null 2>&1; then
        PKGS="curl wget ca-certificates gpg2 git xz"
        info "Installing dependencies via zypper: $PKGS"
        sudo zypper install -y $PKGS || warn "zypper install returned non-zero"
      else
        warn "Could not detect supported package manager to install dependencies. Please ensure curl/wget, ca-certificates and gpg are installed."
      fi
      ;;
    bsd)
      if command -v pkg >/dev/null 2>&1; then
        PKGS="curl wget ca_root_nss gnupg git xz"
        info "Installing dependencies via pkg: $PKGS"
        sudo pkg install -y $PKGS || warn "pkg install returned non-zero"
      else
        warn "BSD package manager not detected. Ensure curl/wget and gpg are installed."
      fi
      ;;
    *)
      warn "Unknown platform; cannot auto-install dependencies."
      ;;
  esac
}

# -------------------------
# Channel file handling
# -------------------------
prepare_channel_file() {
  local dest="$TMPDIR/channels.scm"
  if [ -n "$CHANNEL_SOURCE" ]; then
    info "Using provided channels source: $CHANNEL_SOURCE"
    if [ -f "$CHANNEL_SOURCE" ]; then
      cp "$CHANNEL_SOURCE" "$dest"
    elif is_url "$CHANNEL_SOURCE"; then
      download_file "$CHANNEL_SOURCE" "$dest"
    else
      # try relative to repo raw
      if download_file "${REPO_RAW_BASE}/${CHANNEL_SOURCE}" "$dest" 2>/dev/null; then
        dbg "Fetched channel relative to repo: ${REPO_RAW_BASE}/${CHANNEL_SOURCE}"
      else
        err "Failed to obtain channels from $CHANNEL_SOURCE"; return 1;
      fi
    fi
  else
    info "No channels source provided; writing built-in channels.scm (includes guix, nonguix, and CI substitutes)"
    printf "%s\n" "$BUILTIN_CHANNELS" > "$dest"
  fi

  # quick sanity: must contain 'channel' or 'channels' text
  if ! grep -E "channel|channels" "$dest" >/dev/null 2>&1; then
    warn "Prepared channels file does not contain obvious channel declarations; saving anyway"
  fi

  CHANNEL_FILE="$dest"
  info "Prepared channel file at $CHANNEL_FILE"
}

# -------------------------
# User-level setup
# -------------------------
backup_existing() {
  local target="$1"
  if [ -e "$target" ]; then
    local bak="${target}.bak.${TIMESTAMP}"
    info "Backing up existing $target -> $bak"
    mv "$target" "$bak"
  fi
}

user_setup() {
  info "Performing user-level Guix setup"
  mkdir -p "$HOME/.config/guix"
  if [ -f "$HOME/.config/guix/channels.scm" ]; then
    backup_existing "$HOME/.config/guix/channels.scm"
  fi
  cp -f "$CHANNEL_FILE" "$HOME/.config/guix/channels.scm"
  info "Copied channels to $HOME/.config/guix/channels.scm"

  # write minimal config.scm if missing
  local cfg="$HOME/.config/guix/config.scm"
  if [ ! -f "$cfg" ]; then
    cat > "$cfg" <<'SCM'
;; Minimal Guix config placed by installer
;; Edit this file to customize Guix behavior (substitutes, daemon address, etc.)
;; Example daemon-address:
;; (operating-system
;;  ...
;;  (services
;;    (append (list
;;      (service guix-daemon-service-type)) %default-services)))
SCM
    info "Wrote minimal $cfg"
  else
    dbg "$cfg already exists; preserved"
  fi

  # Inform about shell integration
  add_profile_loader
}

add_profile_loader() {
  local profile_snippet
  profile_snippet=$(cat <<'SNIP'
# Guix profile loader (added by guix installer)
if [ -f "$HOME/.guix-profile/etc/profile" ]; then
  . "$HOME/.guix-profile/etc/profile"
fi
SNIP
)
  # Put snippet in ~/.profile if not present
  if [ ! -f "$HOME/.profile" ]; then
    printf "%s\n" "$profile_snippet" > "$HOME/.profile"
    info "Created ~/.profile and added Guix profile loader"
  elif ! grep -Fq "Guix profile loader (added by guix installer)" "$HOME/.profile" 2>/dev/null; then
    printf "\n%s\n" "$profile_snippet" >> "$HOME/.profile"
    info "Appended Guix profile loader to ~/.profile"
  else
    dbg "~/.profile already contains Guix loader snippet"
  fi
}

# -------------------------
# System daemon setup
# -------------------------
attempt_daemon_install() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root; skipping system guix-daemon setup"
    return 1
  fi
  if [ "$NO_DAEMON" -eq 1 ]; then
    warn "--no-daemon set; skipping guix-daemon setup"
    return 1
  fi

  info "Attempting system-wide guix-daemon install/enable"

  # If guix-daemon exists, try enabling via systemd or init scripts
  if command -v guix-daemon >/dev/null 2>&1; then
    info "guix-daemon binary found"
  else
    # Try to install a packaged guix if available
    if command -v apt-get >/dev/null 2>&1 && apt-cache policy guix >/dev/null 2>&1; then
      info "Installing guix via apt"
      apt-get update -y
      apt-get install -y guix || warn "apt-get guix install failed"
    fi
    # If still not present, do not attempt to build from source here
  fi

  if command -v guix-daemon >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      run_cmd "systemctl enable --now guix-daemon.service || true"
      info "Tried enabling guix-daemon via systemd"
    elif [ -d /etc/init.d ] && [ -x /etc/init.d/guix-daemon ]; then
      run_cmd "/etc/init.d/guix-daemon start || true"
      info "Tried starting /etc/init.d/guix-daemon"
    else
      # fallback: start daemon manually (best-effort)
      run_cmd "guix-daemon --build-users-group=guixbuild &" || warn "Could not start guix-daemon manually"
      info "Attempted manual guix-daemon launch (check logs)"
    fi
    return 0
  else
    warn "guix-daemon not available after attempted package install. You can install Guix from your distribution packages or build Guix manually."
    return 1
  fi
}

# -------------------------
# Register channels with guix (if guix available)
# -------------------------
register_channels() {
  if ! command -v guix >/dev/null 2>&1; then
    warn "guix command not found; skipping 'guix pull' channel registration"
    return 1
  fi

  info "Running: guix pull --channels=$HOME/.config/guix/channels.scm"
  if guix pull --channels="$HOME/.config/guix/channels.scm"; then
    info "guix pull completed"
  else
    warn "guix pull failed; you can retry manually: guix pull --channels=~/.config/guix/channels.scm"
  fi
}

# -------------------------
# Final user guidance
# -------------------------
post_install_note() {
  cat <<EOF

Installation complete (summary):

 - channels saved to: $HOME/.config/guix/channels.scm
 - guix config:       $HOME/.config/guix/config.scm
 - Profile loader appended to: $HOME/.profile

Next steps (recommended):

 - If the 'guix' command is not available, log out and log back in (or source ~/.profile).
 - If you have root and want system-wide guix management, ensure guix-daemon is running.
 - To update channels and pull package metadata:
     guix pull --channels=\$HOME/.config/guix/channels.scm
 - Install a package example:
     guix package -i hello

EOF
}

# -------------------------
# Main flow
# -------------------------
main() {
  detect_platform
  log "Starting Guix installer (time: $TIMESTAMP)"
  dbg "TMPDIR = $TMPDIR"

  if [ "$NO_DAEMON" -eq 1 ]; then USER_ONLY=1; fi

  # If not root and user asked for system installation, warn and offer user-only
  if [ "$(id -u)" -ne 0 ] && [ "$USER_ONLY" -eq 0 ]; then
    warn "System-wide installation requires root"
    if confirm "Proceed with user-only installation instead?"; then
      USER_ONLY=1
    else
      err "Aborting per user choice"
      exit 1
    fi
  fi

  install_minimum_deps || warn "Dependency installation step returned non-zero"

  prepare_channel_file || { err "Channel preparation failed"; exit 1; }

  # If running as root and user didn't force user-only, offer daemon install
  if [ "$(id -u)" -eq 0 ] && [ "$USER_ONLY" -eq 0 ]; then
    if confirm "Attempt system-wide guix-daemon installation and enable it?"; then
      attempt_daemon_install || warn "guix-daemon setup failed or incomplete"
    else
      warn "Skipping system guix-daemon setup per user choice; switching to user-only"
      USER_ONLY=1
    fi
  fi

  # Always ensure user-level config exists for current user
  user_setup

  # If guix present, register channels
  register_channels || dbg "Channel registration deferred"

  post_install_note

  info "Installer finished successfully"
}

main "$@"
