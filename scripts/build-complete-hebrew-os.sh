#!/bin/bash
set -Eeuo pipefail

PURPLE='\033[0;35m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
WORK=/tmp/hebrew-os-live-iso
ROOT="$WORK/root"
ISO_DIR="$WORK/iso"
ISO_OUTPUT=/tmp/hebrew-os-live-bootable.iso

error_handler() { echo -e "${RED}[ERROR]${NC} Build failed at line ${BASH_LINENO[0]} (exit ${?})."; }
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo -e "${RED}[ERROR]${NC} Build failed (exit $rc)."; fi' EXIT

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi
export DEBIAN_FRONTEND=noninteractive

echo -e "${PURPLE}Hebrew OS - Live Bootable ISO Builder${NC}"

REQUIRED_TOOLS=(debootstrap mksquashfs xorriso grub-mkrescue)
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools isolinux syslinux-efi

rm -rf "$WORK"
mkdir -p "$ROOT" "$ISO_DIR/live" "$ISO_DIR/boot/grub"

echo -e "${BLUE}[2] Creating minimal Ubuntu base...${NC}"
# IMPORTANT: debootstrap must remain minimal. Installing XFCE/Firefox/LibreOffice/etc.
# inside debootstrap causes package configuration failures in the bootstrap chroot.
debootstrap --variant=minbase --components=main,universe,restricted,multiverse \
  --include=ca-certificates,apt,locales,sudo \
  jammy "$ROOT" http://archive.ubuntu.com/ubuntu

echo -e "${GREEN}[OK]${NC} Minimal Ubuntu base created"

echo -e "${BLUE}[3] Mounting virtual filesystems...${NC}"
mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run"
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount --rbind /sys "$ROOT/sys"
mount --make-rslave "$ROOT/sys"
mount --bind /run "$ROOT/run"

cleanup() {
  set +e
  for p in "$ROOT/run" "$ROOT/sys" "$ROOT/proc" "$ROOT/dev"; do
    mountpoint -q "$p" && umount -R "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

# Give the chroot working DNS/network access.
rm -f "$ROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"

# Prevent daemons from trying to start while packages are installed in the chroot.
cat > "$ROOT/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod +x "$ROOT/usr/sbin/policy-rc.d"

cat > "$ROOT/etc/apt/sources.list" <<'APT_SOURCES'
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
APT_SOURCES

cat > "$ROOT/tmp/install-live-system.sh" <<'CHROOT_SCRIPT'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  linux-image-generic casper initramfs-tools \
  xfce4 xfce4-terminal xfce4-panel xfce4-session thunar mousepad \
  lightdm xserver-xorg xserver-xorg-video-all \
  network-manager pulseaudio alsa-utils \
  fonts-dejavu fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
  language-pack-he language-pack-gnome-he locales \
  firefox vlc gimp libreoffice-writer libreoffice-calc libreoffice-impress \
  python3 python3-pip git gcc g++ make build-essential \
  curl wget openssh-client htop vim nano less file unzip zip tar gzip \
  imagemagick xclip xsel wmctrl acpi lsb-release

# Hebrew locale and keyboard.
grep -qxF 'he_IL.UTF-8 UTF-8' /etc/locale.gen || echo 'he_IL.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen he_IL.UTF-8
update-locale LANG=he_IL.UTF-8 LANGUAGE=he_IL:he LC_ALL=he_IL.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Jerusalem /etc/localtime

auto_user() {
  if ! id live >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,adm,input,kvm,audio,video live; fi
  echo 'live:live' | chpasswd
  usermod -aG sudo,audio,video,plugdev,netdev live || true
}
auto_user

cat > /etc/default/keyboard <<'KEYBOARD_EOF'
XKBMODEL="pc105"
XKBLAYOUT="us,il"
XKBVARIANT=","
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
KEYBOARD_EOF

echo 'hebrew-os-live' > /etc/hostname
cat > /etc/hosts <<'HOSTS_EOF'
127.0.0.1 localhost
127.0.1.1 hebrew-os-live
::1 localhost ip6-localhost ip6-loopback
HOSTS_EOF

# LightDM automatic login into XFCE.
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-hebrew-os.conf <<'LIGHTDM'
[Seat:*]
autologin-user=live
autologin-user-timeout=0
user-session=xfce
session-setup-script=/etc/lightdm/session-setup.sh
LIGHTDM
cat > /etc/lightdm/session-setup.sh <<'SESSION'
#!/bin/sh
export LANG=he_IL.UTF-8
export LANGUAGE=he_IL:he
SESSION
chmod +x /etc/lightdm/session-setup.sh

mkdir -p /home/live/Desktop /home/live/Documents /home/live/Downloads /home/live/Pictures
cat > /home/live/Desktop/Welcome.txt <<'WELCOME'
Hebrew OS - Live Edition

ברוכים הבאים ל-Hebrew OS!

LOGIN: live / live
HEBREW KEYBOARD: Alt + Shift

המערכת מופעלת ישירות מ-USB ללא התקנה.
WELCOME
chown -R live:live /home/live

# Remove installer-only caches and rebuild initramfs.
apt-get clean
rm -rf /var/lib/apt/lists/*
update-initramfs -c -k all
CHROOT_SCRIPT
chmod +x "$ROOT/tmp/install-live-system.sh"

chroot "$ROOT" /tmp/install-live-system.sh
rm -f "$ROOT/tmp/install-live-system.sh" "$ROOT/usr/sbin/policy-rc.d"

echo -e "${GREEN}[OK]${NC} Hebrew Live system configured"

echo -e "${BLUE}[4] Compressing filesystem...${NC}"
rm -f "$ISO_DIR/live/filesystem.squashfs"
mksquashfs "$ROOT" "$ISO_DIR/live/filesystem.squashfs" -comp xz -e boot

echo -e "${GREEN}[OK]${NC} Filesystem compressed"

echo -e "${BLUE}[5] Copying kernel and initrd...${NC}"
KERNEL=$(find "$ROOT/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort -V | tail -1)
INITRD=$(find "$ROOT/boot" -maxdepth 1 -type f -name 'initrd.img-*' | sort -V | tail -1)
[ -n "$KERNEL" ] && [ -f "$KERNEL" ] || { echo "Kernel missing"; exit 1; }
[ -n "$INITRD" ] && [ -f "$INITRD" ] || { echo "Initrd missing"; exit 1; }
cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd"

echo -e "${BLUE}[6] Creating GRUB boot menu...${NC}"
cat > "$ISO_DIR/boot/grub/grub.cfg" <<'GRUB_CFG'
set default=0
set timeout=8

menuentry "Hebrew OS - Live" {
    linux /live/vmlinuz boot=casper quiet splash ---
    initrd /live/initrd
}

menuentry "Hebrew OS - Live (Safe Mode)" {
    linux /live/vmlinuz boot=casper nomodeset ---
    initrd /live/initrd
}
GRUB_CFG

echo -e "${BLUE}[7] Building bootable ISO...${NC}"
rm -f "$ISO_OUTPUT"
grub-mkrescue --output="$ISO_OUTPUT" --volid=HEBREW-OS "$ISO_DIR"

if [ -s "$ISO_OUTPUT" ]; then
  echo -e "${GREEN}[OK] ISO built successfully: $ISO_OUTPUT ($(du -h "$ISO_OUTPUT" | cut -f1))${NC}"
else
  echo -e "${RED}[ERROR] ISO build failed${NC}"
  exit 1
fi
