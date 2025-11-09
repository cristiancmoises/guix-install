#!/bin/sh
# UNIVERSAL Guix installer – works on:
# • Any GNU/Linux distro (fresh install Guix System)
# • Guix System (reconfigure)
# • FreeBSD / OpenBSD / DragonFly BSD (install Guix package manager only)
# Run as root: chmod +x install.sh && ./install.sh
# SCRIPT AT DEVELOPMENT... USE AT YOUR OWN RISK!
set -e

# ───── Detect OS & package manager ─────
OS=$(uname -s)
case $OS in
  Linux)   PM="unknown" ;;
  FreeBSD|OpenBSD|DragonFly) PM="bsd" ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

if [ "$OS" = "Linux" ]; then
  if   command -v apt    >/dev/null; then PM="apt"
  elif command -v dnf    >/dev/null; then PM="dnf"
  elif command -v pacman >/dev/null; then PM="pacman"
  elif command -v zypper >/dev/null; then PM="zypper"
  elif command -v apk    >/dev/null; then PM="apk"
  elif command -v xbps-install >/dev/null; then PM="xbps"
  fi
fi

# ───── Install package ─────
install_pkg() {
  case $PM in
    apt)    apt update && apt install -y "$@" ;;
    dnf)    dnf install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    zypper) zypper install -y "$@" ;;
    apk)    apk add "$@" ;;
    xbps)   xbps-install -Sy "$@" ;;
    bsd)    if [ "$OS" = "FreeBSD" ] || [ "$OS" = "DragonFly" ]; then pkg install -y "$@"; elif [ "$OS" = "OpenBSD" ]; then pkg_add -I "$@"; fi ;;
    *) echo "No PM"; exit 1 ;;
  esac
}

# ───── Install dialog ─────
if ! command -v dialog >/dev/null; then install_pkg dialog; fi

# ───── Install newgidmap (Linux only) ─────
if [ "$OS" = "Linux" ] && ! command -v newgidmap >/dev/null; then
  case $PM in
    apt) install_pkg uidmap ;;
    dnf) install_pkg shadow-utils ;;
    pacman) install_pkg shadow ;;
    zypper) install_pkg shadow ;;
    apk) install_pkg shadow ;;
    xbps) install_pkg shadow ;;
  esac
fi

# ───── Install Guix if missing ─────
if ! command -v guix >/dev/null; then
  dialog --msgbox "Installing Guix binary…" 6 40
  cd /tmp
  wget https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh || fetch https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh
  chmod +x guix-install.sh
  ./guix-install.sh
  . /root/.config/guix/current/etc/profile || . /var/guix/profiles/per-user/root/current-guix/etc/profile
fi

# ───── channels.scm ─────
mkdir -p /root/.config/guix
cat > /root/.config/guix/channels.scm <<'EOF'
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

# ───── Pull ─────
dialog --infobox "Pulling Guix with custom channels…" 5 60
guix pull --substitute-urls="https://ci.guix.gnu.org https://bordeaux.guix.gnu.org"
. /root/.config/guix/current/etc/profile || . /var/guix/profiles/per-user/root/current-guix/etc/profile

# ───── Defaults ─────
LANG="English"
KB="us"
LOCALE="en_US.utf8"
TZ="America/New_York"
HOST="guix"
USER="user"

# ───── Interactive ─────
LANG=$(dialog --default-item "$LANG" --menu "Language" 12 40 5 \
  "English" "" "Portuguese (Brazil)" "" "Spanish" "" "French" "" "German" "" --output-fd 1)
case $LANG in
  "Portuguese (Brazil)") LOCALE="pt_BR.utf8"; KB="br" ;;
  "Spanish") LOCALE="es_ES.utf8"; KB="es" ;;
  "French") LOCALE="fr_FR.utf8"; KB="fr" ;;
  "German") LOCALE="de_DE.utf8"; KB="de" ;;
esac

KB=$(dialog --inputbox "Keyboard layout" 8 50 "$KB" --output-fd 1)
LOCALE=$(dialog --inputbox "Locale" 8 50 "$LOCALE" --output-fd 1)
HOST=$(dialog --inputbox "Hostname" 8 50 "$HOST" --output-fd 1)
TZ=$(dialog --inputbox "Timezone" 8 60 "$TZ" --output-fd 1)
USER=$(dialog --inputbox "Username" 8 50 "$USER" --output-fd 1)
PASS=$(dialog --passwordbox "Password" 8 50 --output-fd 1)
PASS2=$(dialog --passwordbox "Confirm" 8 50 --output-fd 1)
[ "$PASS" = "$PASS2" ] || { dialog --msgbox "Mismatch!" 6 40; exit 1; }

# ───── BSD: only package manager ─────
if echo "$OS" | grep -q BSD; then
  dialog --msgbox "Guix package manager installed on $OS.\nUse 'guix package -i pkg' to install packages." 8 50
  exit 0
fi

# ───── Guix System reconfigure ─────
if [ -f /etc/config.scm ]; then
  dialog --yesno "Reconfigure Guix System?" 6 50 && {
    sed -i "s/locale .*/locale \"$LOCALE\")/" /etc/config.scm
    sed -i "s/timezone .*/timezone \"$TZ\")/" /etc/config.scm
    sed -i "s/keyboard-layout .*/keyboard-layout (keyboard-layout \"$KB\"))/" /etc/config.scm
    sed -i "s/host-name .*/host-name \"$HOST\")/" /etc/config.scm
    sed -i "s/name .*/name \"$USER\")/" /etc/config.scm
    sed -i "s/home-directory .*/home-directory \"/home/$USER\")/" /etc/config.scm
    guix system reconfigure /etc/config.scm
    printf "%s\n%s\n" "$PASS" "$PASS" | passwd "$USER"
    dialog --msgbox "Reconfigured! Reboot?" 6 40
  }
  exit 0
fi

# ───── Linux fresh install ─────
DISKS=$(lsblk -dpo NAME,SIZE,MODEL | grep -v loop)
DISK=$(dialog --menu "Target disk" 16 70 9 $DISKS --output-fd 1)

LUKS="no"
dialog --defaultno --yesno "Enable LUKS?" 6 50 && LUKS="yes"

LUKS_PASS=""
if [ "$LUKS" = "yes" ]; then
  LUKS_PASS=$(dialog --passwordbox "LUKS passphrase" 8 50 --output-fd 1)
  LUKS_PASS2=$(dialog --passwordbox "Confirm" 8 50 --output-fd 1)
  [ "$LUKS_PASS" = "$LUKS_PASS2" ] || { dialog --msgbox "Mismatch!" 6 50; exit 1; }
fi

# ───── Partition ─────
dialog --infobox "Partitioning $DISK…" 4 50
sgdisk -Z "$DISK"
sgdisk -n 1:0:+550M -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:ROOT "$DISK"

EFI="${DISK}1"
ROOT="${DISK}2"

mkfs.vfat -F32 -n EFI "$EFI"

if [ "$LUKS" = "yes" ]; then
  echo "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
  echo "$LUKS_PASS" | cryptsetup open "$ROOT" cryptroot -
  ROOT_DEV="/dev/mapper/cryptroot"
  LUKS_UUID=$(blkid -s UUID -o value "$ROOT")
  MAPPED="(mapped-devices
      (list (mapped-device
              (source (uuid \"$LUKS_UUID\"))
              (target \"cryptroot\")
              (type luks-device-mapping))))"
  ROOT_DEVICE="\"/dev/mapper/cryptroot\""
else
  ROOT_DEV="$ROOT"
  MAPPED=""
  ROOT_DEVICE="(uuid \"$(blkid -s UUID -o value "$ROOT")\")"
fi

mkfs.ext4 -L guix "$ROOT_DEV"

mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

# ───── FULL config.scm with ALL packages/modules ─────
cat > /mnt/etc/config.scm <<EOF
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
  (locale "$LOCALE")
  (timezone "$TZ")
  (keyboard-layout (keyboard-layout "$KB"))
  (host-name "$HOST")
  (users (cons* (user-account
                 (name "$USER")
                 (comment "Default user")
                 (group "users")
                 (home-directory "/home/$USER")
                 (supplementary-groups '("wheel" "netdev" "audio" "video" "cdrom" "kvm")))
                %base-user-accounts))
  (packages (append (list nss-certs
                          font-dejavu font-gnu-freefont
                          gnome gnome-tweaks
                          pulseaudio pavucontrol
                          bash-completion
                          git curl wget rsync openssh)
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
  $MAPPED
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

# ───── channels.scm ─────
mkdir -p /mnt/etc/guix
cp /root/.config/guix/channels.scm /mnt/etc/guix/

# ───── Install ─────
dialog --infobox "guix system init…" 5 60
guix system init /mnt/etc/config.scm /mnt --substitute-urls="https://ci.guix.gnu.org https://bordeaux.guix.gnu.org"

# ───── Passwords ─────
chroot /mnt /bin/passwd root <<EOP
$PASS
$PASS
EOP
chroot /mnt /bin/passwd $USER <<EOP
$PASS
$PASS
EOP

# ───── Cleanup ─────
umount -R /mnt
[ "$LUKS" = "yes" ] && cryptsetup close cryptroot

dialog --msgbox "Installed! Reboot." 6 40
