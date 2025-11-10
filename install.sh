#!/usr/bin/env bash
# install-interactive.sh — Interactive Guix System installer helper
# Usage: run as root from live ISO while installation is paused
set -euo pipefail

LOG="/tmp/guix-install.log"
exec > >(tee -a "$LOG") 2>&1

# Defaults
DEFAULT_TARGET="/mnt"
HOST_CHANNELS_URL="https://short.securityops.co/channels"
TMP_CHANNELS="/tmp/channels.scm"

# Helpers
info(){ printf "\n[+] %s\n" "$1"; }
err(){ printf "\n[ERROR] %s\n" "$1" >&2; }
confirm(){ local ans; read -rp "$1 [y/N]: " ans; [[ "$ans" = "y" || "$ans" = "Y" ]]; }

check_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root."
    exit 3
  fi
}

check_cmds(){
  local miss=0
  for c in wget sed chroot guix; do
    if ! command -v "$c" >/dev/null 2>&1; then
      printf " - missing: %s\n" "$c"
      miss=1
    fi
  done
  if [ "$miss" -eq 1 ]; then
    err "Install required packages (wget, sed, guix). Aborting."
    exit 1
  fi
}

backup_if_exists(){
  local f="$1"
  if [ -f "$f" ]; then
    local b="${f}.$(date -u +%Y%m%dT%H%M%SZ).bak"
    cp -a "$f" "$b"
    info "Backed up $f -> $b"
  fi
}

validate_config(){
  local cfg="$1"
  if ! guix system build "$cfg" >/dev/null 2>&1; then
    err "guix system build failed for $cfg (syntax or modules)."
    return 1
  fi
  return 0
}

show_menu(){
  cat <<'MENU'

Interactive Guix Installer
1) Set target mount (current: TARGET)
2) Download and install channels.scm into target
3) Edit /mnt/etc/config.scm (opens $EDITOR)
4) Fix common config.scm issues (auto edits)
5) Validate config.scm (guix system build)
6) Choose install method: chroot or time-machine
7) Run installation (init)
8) Dry-run (no changes)
9) Rollback last backup of /etc/config.scm or channels.scm
0) Exit

MENU
}

# Initialize variables (can be changed via menu)
TARGET="${DEFAULT_TARGET}"
INSTALL_METHOD="time-machine"  # or "chroot"
DRY_RUN=0

# Main loop
check_root
check_cmds

while true; do
  echo
  printf "Target: %s  Method: %s  Dry-run: %s\n" "$TARGET" "$INSTALL_METHOD" "$([ "$DRY_RUN" -eq 1 ] && echo on || echo off)"
  echo "Log: $LOG"
  echo
  show_menu | sed "s/TARGET/$TARGET/"
  read -rp "Select option: " opt || exit 0

  case "$opt" in
    1)
      read -rp "Enter target mount point (default $TARGET): " tmp
      TARGET="${tmp:-$TARGET}"
      [ -d "$TARGET" ] || err "Warning: $TARGET does not exist (will still accept)."
      ;;
    2)
      info "Downloading channels from $HOST_CHANNELS_URL -> $TMP_CHANNELS"
      if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] wget skipped"
      else
        wget -q "$HOST_CHANNELS_URL" -O "$TMP_CHANNELS" || { err "Failed to download channels.scm"; continue; }
        mkdir -p "$TARGET/etc/guix" "$TARGET/root/.config/guix"
        backup_if_exists "$TARGET/etc/guix/channels.scm"
        cp -a "$TMP_CHANNELS" "$TARGET/etc/guix/channels.scm"
        cp -a "$TMP_CHANNELS" "$TARGET/root/.config/guix/channels.scm"
        chmod 644 "$TARGET/etc/guix/channels.scm" "$TARGET/root/.config/guix/channels.scm"
        chown -R 0:0 "$TARGET/etc/guix" "$TARGET/root/.config/guix"
        info "channels.scm installed into $TARGET/etc/guix/"
      fi
      ;;
    3)
      # Open editor for manual edits
      cfg="$TARGET/etc/config.scm"
      if [ ! -f "$cfg" ]; then
        err "$cfg not found. Create or mount it before editing."
        continue
      fi
      export EDITOR="${EDITOR:-vi}"
      info "Opening $cfg with $EDITOR"
      if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] editor skipped"
      else
        $EDITOR "$cfg"
      fi
      ;;
    4)
      cfg="$TARGET/etc/config.scm"
      if [ ! -f "$cfg" ]; then
        err "$cfg not found. Aborting auto-fix."
        continue
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] auto-fix skipped"
      else
        backup_if_exists "$cfg"
        info "Fixing (gnu)) -> (gnu)"
        sed -i 's/(gnu))/\(gnu\)/g' "$cfg" || true
        info "Inserting nongnu modules after (use-modules (gnu)"
        sed -i "/(use-modules (gnu)/a\\
  (nongnu packages linux)\\
  (nongnu system linux-initrd)" "$cfg" || true
        info "Inserting kernel, firmware, initrd under (operating-system"
        sed -i "/(operating-system/ a\\
  (kernel linux)\\
  (firmware (list linux-firmware))\\
  (initrd microcode-initrd)" "$cfg" || true
        info "Auto-fix completed"
      fi
      ;;
    5)
      cfg="$TARGET/etc/config.scm"
      if [ ! -f "$cfg" ]; then
        err "$cfg not found."
        continue
      fi
      info "Validating $cfg with guix system build (this may take time)"
      if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] validation skipped"
      else
        if validate_config "$cfg"; then
          info "Validation succeeded"
        else
          err "Validation failed. Open the config and fix errors."
        fi
      fi
      ;;
    6)
      echo "Choose install method:"
      echo "1) time-machine (guix time-machine -C channels.scm -- system init ...)"
      echo "2) chroot + guix pull + guix system init"
      read -rp "Method [1/2]: " m
      if [ "$m" = "1" ]; then INSTALL_METHOD="time-machine"; else INSTALL_METHOD="chroot"; fi
      ;;
    7)
      cfg="$TARGET/etc/config.scm"
      ch_channels="$TARGET/etc/guix/channels.scm"
      if [ ! -f "$cfg" ]; then err "$cfg missing. Aborting."; continue; fi
      if [ ! -f "$ch_channels" ]; then err "$ch_channels missing. Aborting."; continue; fi

      if ! confirm "Proceed with installation to $TARGET using $INSTALL_METHOD?"; then
        info "Installation aborted by user."
        continue
      fi

      if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] installation skipped"
        continue
      fi

      if [ "$INSTALL_METHOD" = "time-machine" ]; then
        info "Making channels writable"
        chmod +w "$ch_channels" || true
        info "Running guix time-machine -C $ch_channels -- system init $cfg $TARGET"
        guix time-machine -C "$ch_channels" -- system init "$cfg" "$TARGET" || { err "guix time-machine / system init failed"; continue; }
        info "System init completed via time-machine."
      else
        # chroot path
        info "Binding /dev /proc /sys /run into $TARGET"
        for d in dev proc sys run; do mount --bind "/$d" "$TARGET/$d"; done
        # create run script
        RUN_SCRIPT="$TARGET/tmp/.run-guix-init.sh"
        cat > "$RUN_SCRIPT" <<'EOF'
#!/bin/sh
set -e
CHANNELS="/etc/guix/channels.scm"
CONFIG="/etc/config.scm"
guix pull --channels="$CHANNELS"
guix system init "$CONFIG" /
EOF
        chmod 700 "$RUN_SCRIPT"
        chown 0:0 "$RUN_SCRIPT"
        info "Entering chroot and running guix pull + system init"
        chroot "$TARGET" /bin/sh -c "/tmp/.run-guix-init.sh" || { err "chrooted guix system init failed"; for d in run sys proc dev; do umount "$TARGET/$d" || true; done; continue; }
        info "Unmounting binds"
        for d in run sys proc dev; do umount "$TARGET/$d"; done
        info "Chroot installation finished"
      fi
      ;;
    8)
      DRY_RUN=1
      info "Dry-run enabled (no destructive operations will be performed)."
      ;;
    9)
      echo "Available backups for /etc/config.scm and /etc/guix/channels.scm under $TARGET:"
      ls -1 "$TARGET/etc/"*.bak* "$TARGET/etc/guix/"*.bak* 2>/dev/null || echo "No backups found."
      read -rp "Enter full path of backup to restore (or blank to cancel): " bfile
      if [ -z "$bfile" ]; then info "Canceling restore"; else
        if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] restore skipped"; else cp -a "$bfile" "$(dirname "$bfile")/../$(basename "$bfile" | sed 's/\.[0-9T:-Z]*\.bak//')"; info "Restored $bfile"; fi
      fi
      ;;
    0)
      info "Exiting interactive installer."
      exit 0
      ;;
    *)
      err "Unknown option"
      ;;
  esac
done
