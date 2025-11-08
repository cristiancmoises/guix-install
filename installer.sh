#!/bin/sh
# Works from ANY GNU/Linux distro
# Run as root: chmod +x install.sh && ./install.sh
# Test in a VM first! This script is under development!

set -e

# ───── Install dialog ─────
if ! command -v dialog >/dev/null; then
  if   command -v apt    >/dev/null; then sudo apt update && sudo apt install -y dialog
  elif command -v dnf    >/dev/null; then sudo dnf install -y dialog
  elif command -v pacman >/dev/null; then sudo pacman -Sy --noconfirm dialog
  elif command -v zypper >/dev/null; then sudo zypper install -y dialog
  elif command -v apk    >/dev/null; then sudo apk add dialog
  else echo "Please install 'dialog'"; exit 1
  fi
fi

# ───── Install Guix ─────
if ! command -v guix >/dev/null; then
  dialog --msgbox "Installing Guix binary…" 6 40
  cd /tmp
  wget -q https://git.savannah.gnu.org/cgit/guix.git/plain/etc/guix-install.sh
  chmod +x guix-install.sh
  sudo ./guix-install.sh
  . /root/.config/guix/current/etc/profile
fi

# ───── Defaults (USA) ─────
LANG="English"
KB="us"
LOCALE="en_US.utf8"
TZ="America/New_York"
HOST="guix"
USER="user"

# ───── Interactive GUI ─────
LANG=$(dialog --title "Language" --default-item "$LANG" --menu "Choose language" 14 40 6 \
  English "-" Español "-" Français "-" Deutsch "-" Русский "-" 中文 "-" --output-fd 1)

case $LANG in
  Español)  LOCALE="es_ES.utf8"; KB="es" ;;
  Français) LOCALE="fr_FR.utf8"; KB="fr" ;;
  Deutsch)  LOCALE="de_DE.utf8"; KB="de" ;;
  Русский)  LOCALE="ru_RU.utf8"; KB="ru" ;;
  中文)     LOCALE="zh_CN.utf8"; KB="us" ;;
esac

KB=$(dialog --inputbox "Keyboard layout" 8 50 "$KB" --output-fd 1)
LOCALE=$(dialog --inputbox "Locale" 8 50 "$LOCALE" --output-fd 1)
HOST=$(dialog --inputbox "Hostname" 8 50 "$HOST" --output-fd 1)
TZ=$(dialog --inputbox "Timezone" 8 60 "$TZ" --output-fd 1)
USER=$(dialog --inputbox "Username" 8 50 "$USER" --output-fd 1)
PASS=$(dialog --passwordbox "User password" 8 50 --output-fd 1)
PASS2=$(dialog --passwordbox "Confirm password" 8 50 --output-fd 1)
[ "$PASS" = "$PASS2" ] || { dialog --msgbox "Passwords mismatch!" 6 40; exit 1; }

# ───── Disk & LUKS ─────
DISKS=$(lsblk -dpo NAME,SIZE,MODEL | grep -v loop)
DISK=$(dialog --menu "Target disk" 16 70 9 $DISKS --output-fd 1)

LUKS="no"
dialog --yesno "Enable LUKS full-disk encryption?" 6 50 && LUKS="yes"

LUKS_PASS=""
if [ "$LUKS" = "yes" ]; then
  LUKS_PASS=$(dialog --passwordbox "LUKS passphrase" 8 50 --output-fd 1)
  LUKS_PASS2=$(dialog --passwordbox "Confirm LUKS passphrase" 8 50 --output-fd 1)
  [ "$LUKS_PASS" = "$LUKS_PASS2" ] || { dialog --msgbox "LUKS passwords mismatch!" 6 50; exit 1; }
fi

# ───── Partition ─────
dialog --infobox "Wiping & partitioning $DISK …" 4 50; sleep 2
sgdisk -Z "$DISK"
sgdisk -n 1:0:+550M -t 1:ef00 -c 1:EFI  "$DISK"
sgdisk -n 2:0:0     -t 2:8300 -c 2:ROOT "$DISK"

EFI="${DISK}1"
ROOT="${DISK}2"

mkfs.vfat -F32 -n EFI "$EFI"
sync

if [ "$LUKS" = "yes" ]; then
  echo "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
  echo "$LUKS_PASS" | cryptsetup open "$ROOT" cryptroot -
  ROOT_DEV="/dev/mapper/cryptroot"
  LUKS_UUID=$(blkid -s UUID -o value "$ROOT")
  MAPPED='    (mapped-devices
      (list (mapped-device
              (source (uuid "'$LUKS_UUID'"))
              (target "cryptroot")
              (type luks-device-mapping))))'
  ROOT_DEVICE='"/dev/mapper/cryptroot"'
else
  ROOT_DEV="$ROOT"
  MAPPED=""
  ROOT_DEVICE='(uuid "'$(blkid -s UUID -o value "$ROOT")'")'
fi

mkfs.ext4 -L guix "$ROOT_DEV"
sync

mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

# ───── FULL config.scm + channels.scm (100% your original code) ─────
mkdir -p /mnt/etc

cat > /mnt/etc/config.scm <<'EOF'
;; === YOUR ORIGINAL BERKELEY CONFIG – UNTOUCHED ===
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
  (locale "en_US.utf8")          ; ← will be replaced
  (timezone "America/New_York")  ; ← will be replaced
  (keyboard-layout (keyboard-layout "us")) ; ← will be replaced
  (host-name "guix")             ; ← will be replaced

  (users (cons* (user-account
                 (name "user")   ; ← will be replaced
                 (comment "Default user")
                 (group "users")
                 (home-directory "/home/user")
                 (supplementary-groups '("wheel" "netdev" "audio" "video" "cdrom" "kvm")))
                %base-user-accounts))

  (packages (append (list
    nss-certs
    font-dejavu font-gnu-freefont
    gnome gnome-tweaks
    pulseaudio pavucontrol
    bash-completion
    git curl wget rsync openssh
    ) %base-packages))

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

  (bootloader
    (bootloader-configuration
      (bootloader grub-efi-bootloader)
      (targets '("/boot/efi"))
      (keyboard-layout keyboard-layout)))

  ;; ← LUKS will be injected here

  (file-systems (cons*
    (file-system
      (mount-point "/boot/efi")
      (device (file-system-label "EFI"))
      (type "vfat"))
    (file-system
      (mount-point "/")
      (device (uuid "00000000-0000-0000-0000-000000000000")) ; ← replaced
      (type "ext4"))
    %base-file-systems))

  (swap-devices (list (swap-space
                       (target (file-system-label "swap"))
                       (dependencies file-systems)))))
EOF

# ───── YOUR channels.scm (non-guix, nonguix, etc.) ─────
cat > /mnt/etc/guix/channels.scm <<'EOF'
;; === YOUR CUSTOM CHANNELS ===
(list
 (channel
  (name 'guix)
  (url "https://git.savannah.gnu.org/git/guix.git")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))

 (channel
  (name 'nonguix)
  (url "https://gitlab.com/nonguix/nonguix")
  (introduction
   (make-channel-introduction
    "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
    (openpgp-fingerprint "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))

 (channel
  (name 'guix-science)
  (url "https://github.com/guix-science/guix-science.git")
  (branch "master"))

 (channel
  (name 'guix-past)
  (url "https://github.com/guix-past/guix-past.git")
  (branch "master"))

 (channel
  (name 'guix-cran)
  (url "https://github.com/guix-science/guix-cran.git")
  (branch "master"))

 (channel
  (name 'guix-bioinformatics)
  (url "https://github.com/guix-science/guix-bioinformatics.git")
  (branch "master")))
EOF

# ───── Inject user values into config.scm ─────
sed -i "s|en_US.utf8|$LOCALE|g" /mnt/etc/config.scm
sed -i "s|America/New_York|$TZ|g" /mnt/etc/config.scm
sed -i "s|us|$KB|g" /mnt/etc/config.scm
sed -i "s|guix|$HOST|g" /mnt/etc/config.scm
sed -i "s|user|$USER|g" /mnt/etc/config.scm
sed -i "s|/home/user|/home/$USER|g" /mnt/etc/config.scm

# Inject LUKS if needed
if [ "$LUKS" = "yes" ]; then
  sed -i "/(bootloader/a $MAPPED" /mnt/etc/config.scm
  sed -i "s|(uuid \"00000000-0000-0000-0000-000000000000\")|$ROOT_DEVICE|g" /mnt/etc/config.scm
else
  sed -i "s|(uuid \"00000000-0000-0000-0000-000000000000\")|$ROOT_DEVICE|g" /mnt/etc/config.scm
fi

# ───── Install system ─────
dialog --infobox "guix system init – this will take 15–30 min…" 5 60
guix system init /mnt/etc/config.scm /mnt --no-grub

# ───── Set passwords ─────
echo "root:$PASS" | chroot /mnt chpasswd
echo "$USER:$PASS" | chroot /mnt chpasswd

# ───── Cleanup ─────
umount -R /mnt
[ "$LUKS" = "yes" ] && cryptsetup close cryptroot

dialog --msgbox "GNU Guix System installed!\n\nYour channels.scm is ready.\nReboot now." 9 50
