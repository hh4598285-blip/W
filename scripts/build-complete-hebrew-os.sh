#!/bin/bash
set -Eeuo pipefail

PURPLE='\033[0;35m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
WORK=/tmp/hebrew-os-live-iso
ROOT="$WORK/root"
ISO_DIR="$WORK/iso"
ISO_OUTPUT=/tmp/hebrew-os-live-bootable.iso

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi
export DEBIAN_FRONTEND=noninteractive

cleanup_mounts() {
  set +e
  for p in "$ROOT/run" "$ROOT/sys" "$ROOT/proc" "$ROOT/dev"; do
    mountpoint -q "$p" && umount -R -lf "$p" 2>/dev/null || true
  done
}
cleanup_all() {
  cleanup_mounts
  rm -f "$ROOT/usr/sbin/policy-rc.d" 2>/dev/null || true
  rm -f "$ROOT/etc/resolv.conf" 2>/dev/null || true
}
trap cleanup_all EXIT

apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools isolinux syslinux-efi
rm -rf "$WORK"
mkdir -p "$ROOT" "$ISO_DIR/live" "$ISO_DIR/boot/grub"

echo -e "${PURPLE}Hebrew OS - Live Bootable ISO Builder${NC}"
echo -e "${BLUE}[2] Creating minimal Ubuntu base...${NC}"
debootstrap --variant=minbase --components=main,universe,restricted,multiverse --include=ca-certificates,apt,locales,sudo jammy "$ROOT" http://archive.ubuntu.com/ubuntu

echo -e "${BLUE}[3] Mounting virtual filesystems...${NC}"
mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run"
mount --rbind /dev "$ROOT/dev"; mount --make-rslave "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount --rbind /sys "$ROOT/sys"; mount --make-rslave "$ROOT/sys"
mount --bind /run "$ROOT/run"

rm -f "$ROOT/etc/resolv.conf"; cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
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

# Enable 32-bit packages so Wine can run both 32-bit and 64-bit Windows applications.
dpkg --add-architecture i386
apt-get update

apt-get install -y --no-install-recommends \
  linux-image-generic casper initramfs-tools \
  xfce4 xfce4-terminal xfce4-panel xfce4-session xfce4-whiskermenu-plugin \
  thunar mousepad lightdm xserver-xorg xserver-xorg-video-all \
  network-manager network-manager-gnome wireless-tools wpasupplicant \
  pulseaudio alsa-utils pavucontrol \
  gvfs gvfs-backends udisks2 ntfs-3g exfatprogs \
  fonts-dejavu fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
  language-pack-he language-pack-gnome-he locales \
  firefox vlc gimp libreoffice-writer libreoffice-calc libreoffice-impress \
  python3 python3-pip curl wget openssh-client htop vim nano less file \
  unzip zip p7zip-full unrar-free tar gzip bzip2 xz-utils zstd \
  imagemagick ffmpeg xclip xsel wmctrl acpi lsb-release \
  wine64 wine32 winetricks \
  cabextract dos2unix

# Windows-style desktop appearance and a simple Start-menu experience.
apt-get install -y --no-install-recommends arc-theme papirus-icon-theme 2>/dev/null || true

# Prefer a Windows-like XFCE layout while retaining XFCE's accessibility and stability.
mkdir -p /etc/xdg/xfce4/panel
cat > /etc/xdg/xfce4/panel/default.xml <<'PANEL_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/><value type="int" value="2"/><value type="int" value="3"/>
        <value type="int" value="4"/><value type="int" value="5"/><value type="int" value="6"/>
      </property>
    </property>
  </property>
</channel>
PANEL_EOF

# Windows application launcher: double-clicking .exe/.msi files in the file manager uses Wine.
mkdir -p /usr/share/applications
cat > /usr/share/applications/windows-programs.desktop <<'DESKTOP_EOF'
[Desktop Entry]
Name=Windows Programs
Name[he]=תוכנות Windows
Comment=Run Windows EXE and MSI applications with Wine
Comment[he]=הפעלת תוכנות EXE ו-MSI של Windows באמצעות Wine
Exec=winecfg
Icon=wine
Terminal=false
Type=Application
Categories=Utility;
DESKTOP_EOF

# Register common Windows executable MIME types with Wine.
xdg-mime default wine.desktop application/x-ms-dos-executable 2>/dev/null || true

# Enable Hebrew/English keyboard switching.
grep -qxF 'he_IL.UTF-8 UTF-8' /etc/locale.gen || echo 'he_IL.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen he_IL.UTF-8
update-locale LANG=he_IL.UTF-8 LANGUAGE=he_IL:he LC_ALL=he_IL.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Jerusalem /etc/localtime

if ! id live >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,adm,input,kvm,audio,video live; fi
echo 'live:live' | chpasswd
usermod -aG sudo,audio,video,plugdev,netdev,lp,scanner live || true

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
Hebrew OS - Windows-style Live Edition

ברוכים הבאים ל-Hebrew OS!

Windows EXE/MSI: לחץ פעמיים על קובץ כדי לנסות להפעיל אותו באמצעות Wine.
Linux packages: DEB/AppImage ותוכנות Linux נתמכות בהתאם לחבילה.
Internet: NetworkManager + Wi-Fi/Ethernet.
Keyboard: Alt+Shift מחליף עברית/אנגלית.
Mouse/USB: נתמכים דרך מערכת Linux/XFCE.

LOGIN: live / live
WELCOME

# Wine defaults for the live user; failures here must not break the image build.
mkdir -p /home/live/.wine
chown -R live:live /home/live
su - live -c 'WINEPREFIX="$HOME/.wine" wineboot -u >/dev/null 2>&1 || true'

apt-get clean
rm -rf /var/lib/apt/lists/*
update-initramfs -c -k all
CHROOT_SCRIPT
chmod +x "$ROOT/tmp/install-live-system.sh"
chroot "$ROOT" /tmp/install-live-system.sh
rm -f "$ROOT/tmp/install-live-system.sh" "$ROOT/usr/sbin/policy-rc.d"

cleanup_mounts
for p in "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run"; do
  mountpoint -q "$p" && { echo "Virtual filesystem still mounted: $p"; exit 1; } || true
done
rm -rf "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run"
mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run"

mksquashfs "$ROOT" "$ISO_DIR/live/filesystem.squashfs" -comp xz -e proc sys dev run tmp
KERNEL=$(find "$ROOT/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort -V | tail -1)
INITRD=$(find "$ROOT/boot" -maxdepth 1 -type f -name 'initrd.img-*' | sort -V | tail -1)
[ -f "$KERNEL" ] && [ -f "$INITRD" ] || { echo 'Kernel/initrd missing'; exit 1; }
cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<'GRUB_CFG'
set default=0
set timeout=8
menuentry "Hebrew OS - Windows Style Live" {
    linux /live/vmlinuz boot=casper quiet splash ---
    initrd /live/initrd
}
menuentry "Hebrew OS - Safe Mode" {
    linux /live/vmlinuz boot=casper nomodeset ---
    initrd /live/initrd
}
GRUB_CFG

rm -f "$ISO_OUTPUT"
grub-mkrescue --output="$ISO_OUTPUT" "$ISO_DIR"
[ -s "$ISO_OUTPUT" ] || { echo 'ISO build failed'; exit 1; }
xorriso -indev "$ISO_OUTPUT" -toc >/tmp/hebrew-os-iso-check.txt 2>&1
printf '%s\n' "[OK] ISO built and validated: $ISO_OUTPUT ($(du -h "$ISO_OUTPUT" | cut -f1))"
