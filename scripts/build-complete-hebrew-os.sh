#!/bin/bash
set -Eeuo pipefail

PURPLE='\033[0;35m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
WORK=/tmp/hebrew-os-live-iso
ROOT="$WORK/root"
ISO_DIR="$WORK/iso"
ISO_OUTPUT=/tmp/hebrew-os-live-bootable.iso

trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo -e "${RED}[ERROR]${NC} Build failed (exit $rc)."; fi' EXIT

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi
export DEBIAN_FRONTEND=noninteractive

echo -e "${PURPLE}Hebrew OS - Live Bootable ISO Builder${NC}"

apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools isolinux syslinux-efi

rm -rf "$WORK"
mkdir -p "$ROOT" "$ISO_DIR/live" "$ISO_DIR/boot/grub"

echo -e "${BLUE}[2] Creating minimal Ubuntu base...${NC}"
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

cleanup_mounts() {
  set +e
  for p in "$ROOT/run" "$ROOT/sys" "$ROOT/proc" "$ROOT/dev"; do
    if mountpoint -q "$p"; then
      umount -R -lf "$p" 2>/dev/null || true
    fi
  done
}

cleanup_all() {
  cleanup_mounts
  rm -f "$ROOT/usr/sbin/policy-rc.d" 2>/dev/null || true
  rm -f "$ROOT/etc/resolv.conf" 2>/dev/null || true
}

trap cleanup_all EXIT

rm -f "$ROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"

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

grep -qxF 'he_IL.UTF-8 UTF-8' /etc/locale.gen || echo 'he_IL.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen he_IL.UTF-8
update-locale LANG=he_IL.UTF-8 LANGUAGE=he_IL:he LC_ALL=he_IL.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Jerusalem /etc/localtime

if ! id live >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,adm,input,kvm,audio,video live; fi
echo 'live:live' | chpasswd
usermod -aG sudo,audio,video,plugdev,netdev live || true

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

mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-hebrew-os.conf <<'LIGHTDM'
[Seat:*]
autologin-user=live
autologin-user-timeout=0
user-session=xfce
LIGHTDM

mkdir -p /home/live/Desktop /home/live/Documents /home/live/Downloads /home/live/Pictures
cat > /home/live/Desktop/Welcome.txt <<'WELCOME'
Hebrew OS - Live Edition

ברוכים הבאים ל-Hebrew OS!

LOGIN: live / live
HEBREW KEYBOARD: Alt + Shift

המערכת מופעלת ישירות מ-USB ללא התקנה.
WELCOME
chown -R live:live /home/live

apt-get clean
rm -rf /var/lib/apt/lists/*
update-initramfs -c -k all
CHROOT_SCRIPT
chmod +x "$ROOT/tmp/install-live-system.sh"

chroot "$ROOT" /tmp/install-live-system.sh
rm -f "$ROOT/tmp/install-live-system.sh" "$ROOT/usr/sbin/policy-rc.d"

echo -e "${GREEN}[OK]${NC} Hebrew Live system configured"

echo -e "${BLUE}[4] Unmounting virtual filesystems before filesystem packaging...${NC}"
# /proc, /sys, /dev and /run are host/chroot virtual filesystems. They must NEVER
# be traversed by mksquashfs; doing so produces /proc/irq/* read failures and can
# cause the Actions job to be cancelled.
cleanup_mounts

for p in "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run"; do
  if mountpoint -q "$p"; then
    echo -e "${RED}[ERROR]${NC} Virtual filesystem still mounted: $p"
    exit 1
  fi
done

# Replace the mount points with empty directories so the squashfs tree is safe.
rm -rf "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run"
mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run"

# Do not include transient runtime trees in the ISO filesystem.
rm -f "$ISO_DIR/live/filesystem.squashfs"
mksquashfs "$ROOT" "$ISO_DIR/live/filesystem.squashfs" -comp xz \
  -e proc sys dev run tmp

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
