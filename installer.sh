#!/bin/sh
# Works from ANY GNU/Linux distro
# Run as root: chmod +x install.sh && ./install.sh
# EXPERIMENTAL! DO NOT USE ON RUNNING OS - TEST IN VM!
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

# ───── Set custom channels and pull ─────
mkdir -p /root/.config/guix
cat > /root/.config/guix/channels.scm <<'EOF'
;; === YOUR CUSTOM CHANNELS ===
;; (use-modules (guix ci))
(list
  (channel-with-substitutes-available
    %default-guix-channel
    "https://ci.guix.gnu.org")
 (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "4fd32c00abb59b0f275a93c3fef35d5193adbe7a")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA"))))
(list
  (name 'nonguix)
  (url "https://gitlab.com/nonguix/nonguix")
  (introduction
   (make-channel-introduction
    "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
    (openpgp-fingerprint "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5")))))
EOF

dialog --infobox "Pulling Guix with custom channels… this may take time" 5 60
guix pull
. /root/.config/guix/current/etc/profile

# ───── Defaults (USA) ─────
LANG="English (US)"
KB="us"
LOCALE="en_US.utf8"
TZ="America/New_York"
HOST="guix"
USER="user"

# ───── Interactive GUI ─────
LANG=$(dialog --title "Language" --default-item "$LANG" --menu "Choose language" 20 50 12 \
  "English (US)" "" \
  "English (UK)" "" \
  "Portuguese (Brazil)" "" \
  "Portuguese (Portugal)" "" \
  "Spanish (Spain)" "" \
  "Spanish (Latin America)" "" \
  "French" "" \
  "German" "" \
  "Italian" "" \
  "Russian" "" \
  "Chinese (Simplified)" "" \
  "Japanese" "" \
  "Korean" "" --output-fd 1)

case $LANG in
  "English (US)") LOCALE="en_US.utf8"; KB="us" ;;
  "English (UK)") LOCALE="en_GB.utf8"; KB="gb" ;;
  "Portuguese (Brazil)") LOCALE="pt_BR.utf8"; KB="br" ;;
  "Portuguese (Portugal)") LOCALE="pt_PT.utf8"; KB="pt" ;;
  "Spanish (Spain)") LOCALE="es_ES.utf8"; KB="es" ;;
  "Spanish (Latin America)") LOCALE="es_MX.utf8"; KB="latam" ;;
  "French") LOCALE="fr_FR.utf8"; KB="fr" ;;
  "German") LOCALE="de_DE.utf8"; KB="de" ;;
  "Italian") LOCALE="it_IT.utf8"; KB="it" ;;
  "Russian") LOCALE="ru_RU.utf8"; KB="ru" ;;
  "Chinese (Simplified)") LOCALE="zh_CN.utf8"; KB="us" ;;
  "Japanese") LOCALE="ja_JP.utf8"; KB="jp" ;;
  "Korean") LOCALE="ko_KR.utf8"; KB="kr" ;;
esac

KB=$(dialog --inputbox "Keyboard layout" 8 50 "$KB" --output-fd 1)
LOCALE=$(dialog --inputbox "Locale" 8 50 "$LOCALE" --output-fd 1)
HOST=$(dialog --inputbox "Hostname" 8 50 "$HOST" --output-fd 1)

TZ=$(dialog --title "Timezone" --default-item "$TZ" --menu "Choose timezone" 15 50 8 \
  "America/New_York" "US East" \
  "America/Chicago" "US Central" \
  "America/Los_Angeles" "US West" \
  "Europe/London" "UK" \
  "Europe/Paris" "France" \
  "Europe/Berlin" "Germany" \
  "Asia/Tokyo" "Japan" \
  "Asia/Shanghai" "China" --output-fd 1)

USER=$(dialog --inputbox "Username" 8 50 "$USER" --output-fd 1)
PASS=$(dialog --passwordbox "User password" 8 50 --output-fd 1)
PASS2=$(dialog --passwordbox "Confirm password" 8 50 --output-fd 1)
[ "$PASS" = "$PASS2" ] || { dialog --msgbox "Passwords mismatch!" 6 40; exit 1; }

# ───── Disk & LUKS ─────
DISKS=$(lsblk -dpo NAME,SIZE,MODEL | grep -v loop)
DISK=$(dialog --menu "Target disk" 16 70 9 $DISKS --output-fd 1)

LUKS="no"
dialog --defaultno --yesno "Enable LUKS full-disk encryption?" 6 50 && LUKS="yes"

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
mkdir -p /mnt/etc/guix

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
    %base-file-systems)))
EOF

# ───── YOUR channels.scm (non-guix, nonguix, etc.) ─────
cp /root/.config/guix/channels.scm /mnt/etc/guix/channels.scm

# ───── Inject user values into config.scm ─────
sed -i "s|en_US.utf8|$LOCALE|g" /mnt/etc/config.scm
sed -i "s|America/New_York|$TZ|g" /mnt/etc/config.scm
sed -i "s|\"us\"|\"$KB\"|g" /mnt/etc/config.scm
sed -i "s|guix|$HOST|g" /mnt/etc/config.scm
sed -i "s|\"user\"|\"$USER\"|g" /mnt/etc/config.scm
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
guix system init /mnt/etc/config.scm /mnt

# ───── Set passwords ─────
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

dialog --msgbox "GNU Guix System installed!\n\nYour channels.scm is ready.\nReboot now." 9 50
