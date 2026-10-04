#!/bin/bash
set -Eeuo pipefail

PURPLE='\033[0;35m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_error() { echo -e "${RED}[ERROR]${NC} Build failed at line ${BASH_LINENO[0]}."; }
trap log_error ERR

echo -e "${PURPLE}Hebrew OS - Live Bootable ISO Builder${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}[*] Needs sudo - re-running...${NC}"
    exec sudo "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

REQUIRED_TOOLS=("debootstrap" "mksquashfs" "xorriso" "grub-mkrescue")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Installing $tool...${NC}"
        apt-get update
        apt-get install -y "$tool"
    fi
done

WORK=/tmp/hebrew-os-live-iso
rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/iso/live" "$WORK/iso/boot/grub"

cleanup_mounts() {
    set +e
    for target in "$WORK/root/run" "$WORK/root/sys" "$WORK/root/proc" "$WORK/root/dev"; do
        if mountpoint -q "$target"; then
            umount -R "$target" 2>/dev/null || umount "$target" 2>/dev/null || true
        fi
    done
}
trap cleanup_mounts EXIT

echo -e "${BLUE}[2] Building Live System (this may take 20-30 minutes)...${NC}"

# Ubuntu Focal uses universe for several desktop utilities.
# firefox-esr is a Debian package; Ubuntu uses firefox.
PACKAGES="linux-image-generic,grub-pc-bin,grub-efi-amd64-bin"
PACKAGES="$PACKAGES,xfce4,xfce4-terminal,mousepad,thunar,xfce4-panel,xfce4-session"
PACKAGES="$PACKAGES,firefox,vlc,gimp"
PACKAGES="$PACKAGES,libreoffice-writer,libreoffice-calc,libreoffice-impress"
PACKAGES="$PACKAGES,python3,python3-pip,git,gcc,g++,make,build-essential"
PACKAGES="$PACKAGES,curl,wget,openssh-client"
PACKAGES="$PACKAGES,htop,neofetch,vim,nano,less,file,unzip,zip,tar,gzip"
PACKAGES="$PACKAGES,fonts-liberation,fonts-dejavu,fonts-noto-cjk"
PACKAGES="$PACKAGES,network-manager,pulseaudio,alsa-utils,xorg"
PACKAGES="$PACKAGES,gpicview,imagemagick"
PACKAGES="$PACKAGES,xclip,xsel,wmctrl"
PACKAGES="$PACKAGES,acpi,lsb-release"

# Enable all Ubuntu components needed by the desktop package set.
debootstrap \
    --components=main,universe,restricted,multiverse \
    --include="$PACKAGES" \
    focal "$WORK/root" http://archive.ubuntu.com/ubuntu

echo -e "${GREEN}[OK]${NC} System built"
echo -e "${BLUE}[3] Adding Hebrew support...${NC}"

# Always create mount points before mounting them.
mkdir -p "$WORK/root/dev" "$WORK/root/proc" "$WORK/root/sys" "$WORK/root/run"

mount --rbind /dev "$WORK/root/dev"
mount --make-rslave "$WORK/root/dev"
mount -t proc /proc "$WORK/root/proc"
mount --rbind /sys "$WORK/root/sys"
mount --make-rslave "$WORK/root/sys"
mount --bind /run "$WORK/root/run"

chroot "$WORK/root" /bin/bash << 'HEBREW_SETUP'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

ln -sf /usr/share/zoneinfo/Asia/Jerusalem /etc/localtime
grep -qxF 'he_IL.UTF-8 UTF-8' /etc/locale.gen || echo 'he_IL.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen he_IL.UTF-8
update-locale LANG=he_IL.UTF-8

cat > /etc/default/keyboard << 'KEYBOARD_EOF'
XKBMODEL="pc105"
XKBLAYOUT="us,il"
XKBVARIANT=","
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
KEYBOARD_EOF

echo 'hebrew-os-live' > /etc/hostname
cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1       localhost
127.0.1.1       hebrew-os-live
::1             localhost ip6-localhost ip6-loopback
HOSTS_EOF

if ! id live >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,adm,input,kvm,disk live
fi
echo 'live:live' | chpasswd
usermod -aG sudo live

mkdir -p /home/live/{Desktop,Documents,Downloads,Pictures}
chown -R live:live /home/live

apt-get clean
apt-get autoclean
update-initramfs -u -k all

echo "[OK] Hebrew configured"
HEBREW_SETUP

cleanup_mounts
trap - EXIT

echo -e "${GREEN}[OK]${NC} Hebrew setup done"
echo -e "${BLUE}[4] Adding welcome content...${NC}"

mkdir -p "$WORK/root/home/live/Desktop"
cat > "$WORK/root/home/live/Desktop/Welcome.txt" << 'WELCOME_EOF'
Hebrew OS - Live Edition
No installation needed - this boots directly from USB!

LOGIN: live / live
HEBREW KEYBOARD: Alt + Shift to toggle
WELCOME_EOF
chown live:live "$WORK/root/home/live/Desktop/Welcome.txt"

echo -e "${BLUE}[5] Compressing filesystem (this may take 15 minutes)...${NC}"
mksquashfs "$WORK/root" "$WORK/iso/live/filesystem.squashfs" -comp xz -e boot

echo -e "${GREEN}[OK]${NC} Filesystem compressed"
echo -e "${BLUE}[6] Copying kernel...${NC}"

KERNEL=$(find "$WORK/root/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort -V | tail -1 || true)
INITRD=$(find "$WORK/root/boot" -maxdepth 1 -type f -name 'initrd.img-*' | sort -V | tail -1 || true)
if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
    echo -e "${RED}[ERROR]${NC} Kernel or initrd was not created."
    exit 1
fi
cp "$KERNEL" "$WORK/iso/live/vmlinuz"
cp "$INITRD" "$WORK/iso/live/initrd"

echo -e "${BLUE}[7] Configuring GRUB...${NC}"
mkdir -p "$WORK/iso/boot/grub"
cat > "$WORK/iso/boot/grub/grub.cfg" << 'GRUB_CFG'
set default=0
set timeout=10

menuentry "Hebrew OS - Live" {
    search --no-floppy --label HEBREW-OS --set root
    linux /live/vmlinuz boot=live live-media-path=/live toram quiet splash
    initrd /live/initrd
}

menuentry "Hebrew OS - Live (Safe Mode)" {
    search --no-floppy --label HEBREW-OS --set root
    linux /live/vmlinuz boot=live live-media-path=/live nomodeset quiet splash
    initrd /live/initrd
}
GRUB_CFG

echo -e "${BLUE}[8] Building ISO...${NC}"
ISO_OUTPUT="/tmp/hebrew-os-live-bootable.iso"
rm -f "$ISO_OUTPUT"
grub-mkrescue --output="$ISO_OUTPUT" --volid=HEBREW-OS "$WORK/iso/"

if [ -s "$ISO_OUTPUT" ]; then
    ISO_SIZE=$(du -h "$ISO_OUTPUT" | cut -f1)
    echo -e "${GREEN}[OK] ISO built successfully: $ISO_OUTPUT ($ISO_SIZE)${NC}"
else
    echo -e "${RED}[ERROR] ISO build failed${NC}"
    exit 1
fi
