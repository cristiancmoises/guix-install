#!/bin/sh
# UNIVERSAL Guix installer – works on GNU/Linux (fresh/reconfigure), BSD (package manager only)
# Graphical interface with dialog for selection
# Supports LUKS encryption, default USA settings, user choices
# Preserves all use-modules, packages from older versions
# Channels with substitutes for fast install
# Run as root: chmod +x installer.sh && ./installer.sh
# Verbose mode for debugging

set -e
echo "Starting Guix installer on $(uname -s)"

# ───── Detect OS & PM ─────
OS=$(uname -s)
echo "OS: $OS"
case $OS in
  Linux) PM="unknown" ;;
  FreeBSD|OpenBSD|DragonFly) PM="bsd" ;;
  *) echo "Unsupported OS"; exit 1 ;;
esac

if [ "$OS" = "Linux" ]; then
  if command -v apt >/dev/null; then PM="apt"; echo "PM: apt"
  elif command -v dnf >/dev/null; then PM="dnf"; echo "PM: dnf"
  elif command -v pacman >/dev/null; then PM="pacman"; echo "PM: pacman"
  elif command -v zypper >/dev/null; then PM="zypper"; echo "PM: zypper"
  elif command -v apk >/dev/null; then PM="apk"; echo "PM: apk"
  elif command -v xbps-install >/dev/null; then PM="xbps"; echo "PM: xbps"
  else echo "No PM found"; exit 1
  fi
fi

# ───── Install pkg function ─────
install_pkg() {
  echo "Installing $@"
  case $PM in
    apt) apt update && apt install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    zypper) zypper install -y "$@" ;;
    apk) apk add "$@" ;;
    xbps) xbps-install -Sy "$@" ;;
    bsd) if [ "$OS" = "FreeBSD" ] || [ "$OS" = "DragonFly" ]; then pkg install -y "$@" ; elif [ "$OS" = "OpenBSD" ]; then pkg_add -I "$@" ; fi ;;
    *) echo "No PM"; return 1 ;;
  esac
}

# ───── Install dialog ─────
if ! command -v dialog >/dev/null; then install_pkg dialog; fi

# ───── Install newgidmap (Linux) ─────
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

# ───── Install Guix ─────
if ! command -v guix >/dev/null; then
  cd /tmp
  wget https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh || fetch https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh
  chmod +x guix-install.sh
  ./guix-install.sh
  . /root/.config/guix/current/etc/profile
fi

# ───── Channels ─────
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
guix pull --substitute-urls="https://ci.guix.gnu.org https://bordeaux.guix.gnu.org"
. /root/.config/guix/current/etc/profile

# ───── Defaults ─────
LANG="English"
KB="us"
LOCALE="en_US.utf8"
TZ="America/New_York"
HOST="guix"
USER="user"

# ───── Interactive ─────
LANG=$(dialog --menu "Language" 12 40 5 "English" "" "Portuguese (Brazil)" "" "Spanish" "" "French" "" "German" "" --stdout) || exit
case $LANG in
  "Portuguese (Brazil)") LOCALE="pt_BR.utf8"; KB="br" ;;
  "Spanish") LOCALE="es_ES.utf8"; KB="es" ;;
  "French") LOCALE="fr_FR.utf8"; KB="fr" ;;
  "German") LOCALE="de_DE.utf8"; KB="de" ;;
esac

KB=$(dialog --inputbox "Keyboard layout" 8 50 "$KB" --stdout) || exit
LOCALE=$(dialog --inputbox "Locale" 8 50 "$LOCALE" --stdout) || exit
HOST=$(dialog --inputbox "Hostname" 8 50 "$HOST" --stdout) || exit
TZ=$(dialog --inputbox "Timezone" 8 60 "$TZ" --stdout) || exit
USER=$(dialog --inputbox "Username" 8 50 "$USER" --stdout) || exit
PASS=$(dialog --passwordbox "Password" 8 50 --stdout) || exit
PASS2=$(dialog --passwordbox "Confirm" 8 50 --stdout) || exit
[ "$PASS" = "$PASS2" ] || { dialog --msgbox "Mismatch!" 6 40; exit 1; }

# ───── BSD: package manager only ─────
if echo "$OS" | grep -q BSD; then
  dialog --msgbox "Guix package manager installed on $OS." 8 50
  exit 0
fi

# ───── Reconfigure if Guix System ─────
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
    dialog --msgbox "Reconfigured!" 6 40
  }
  exit 0
fi

# ───── Fresh install ─────
DISKS=$(lsblk -dpo NAME,SIZE | awk '{print $1 " " $2}')
DISK=$(dialog --menu "Disk" 15 50 10 $DISKS --stdout) || exit

LUKS="no"
dialog --yesno "LUKS encryption?" 5 30 && LUKS="yes"

LUKS_PASS=""
if [ "$LUKS" = "yes" ]; then
  LUKS_PASS=$(dialog --passwordbox "LUKS passphrase" 8 50 --stdout) || exit
  LUKS_PASS2=$(dialog --passwordbox "Confirm" 8 50 --stdout) || exit
  [ "$LUKS_PASS" = "$LUKS_PASS2" ] || exit 1
fi

# ───── Partition ─────
sgdisk -Z $DISK
sgdisk -n 1:0:+550MiB -t 1:ef00 $DISK
sgdisk -n 2:0:0 $DISK

EFI_PART=${DISK}1
ROOT_PART=${DISK}2

mkfs.vfat -F32 -n "EFI" $EFI_PART

if [ "$LUKS" = "yes" ]; then
  echo -n "$LUKS_PASS" | cryptsetup luksFormat $ROOT_PART -
  echo -n "$LUKS_PASS" | cryptsetup open $ROOT_PART encrypted -
  ROOT_DEV=/dev/mapper/encrypted
  LUKS_UUID=$(blkid -s UUID -o value $ROOT_PART)
  MAPPED="(list (mapped-device (source (uuid \"$LUKS_UUID\")) (target \"encrypted\") (type luks-device-mapping)))"
  ROOT_DEVICE="\"/dev/mapper/encrypted\""
else
  ROOT_DEV=$ROOT_PART
  MAPPED="'()"
  ROOT_DEVICE="(uuid \"$(blkid -s UUID -o value $ROOT_DEV)\")"
fi

mkfs.ext4 -L "root" $ROOT_DEV

mount $ROOT_DEV /mnt
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi

# ───── Config with all modules/packages ─────
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
EOF

# ───── Channels ─────
mkdir -p /mnt/etc/guix
cp /root/.config/guix/channels.scm /mnt/etc/guix/

# ───── Init ─────
guix system init /mnt/etc/config.scm /mnt

# ───── Passwords ─────
chroot /mnt /bin/passwd $USER <<EOP
$PASS
$PASS
EOP

# ───── Cleanup ─────
umount -R /mnt
[ "$LUKS" = "yes" ] && cryptsetup close encrypted

dialog --msgbox "Installed! Reboot." 6 40
echo "Completed"
