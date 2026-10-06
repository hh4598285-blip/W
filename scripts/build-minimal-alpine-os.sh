#!/bin/sh
set -e

echo "=== Minimal Alpine GUI OS Builder (with internet support) ==="

WORK=/tmp/alpine-build
ROOT="$WORK/root"
ISO="$WORK/iso"

rm -rf "$WORK"
mkdir -p "$ROOT" "$ISO/boot/grub" "$ISO/live"

apk update

apk add --no-cache \
    alpine-sdk squashfs-tools xorriso grub grub-efi mtools dosfstools \
    e2fsprogs syslinux

echo "[1] Installing base system + GUI + apps + networking into target root..."

apk add --no-cache --root "$ROOT" --initdb -X http://dl-cdn.alpinelinux.org/alpine/v3.20/main -X http://dl-cdn.alpinelinux.org/alpine/v3.20/community -U --allow-untrusted \
    alpine-base \
    linux-lts linux-firmware-none linux-firmware-brcm linux-firmware-iwlwifi linux-firmware-rtl_nic \
    xorg-server xf86-video-fbdev xf86-video-vesa xf86-input-libinput \
    openbox xterm \
    mpv feh zathura zathura-pdf-mupdf \
    eudev udev-init-scripts mesa-dri-gallium \
    dhcpcd wpa_supplicant iw \
    chromium \
    font-noto font-noto-cjk ttf-dejavu \
    mkinitfs

echo "[2] Hebrew locale + keyboard..."

chroot "$ROOT" /bin/sh -c "
    setup-keymap us il 2>/dev/null || true
    echo 'hebrew-os-live' > /etc/hostname
"

echo "[3] Auto-login + auto-start X on console..."

mkdir -p "$ROOT/etc/profile.d"
cat > "$ROOT/etc/profile.d/autostart-x.sh" << 'EOF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx
fi
EOF

sed -i 's/^tty1::respawn:.*/tty1::respawn:\/sbin\/agetty --autologin root --noclear tty1 38400 linux/' "$ROOT/etc/inittab" 2>/dev/null || true

cat > "$ROOT/root/.xinitrc" << 'EOF'
#!/bin/sh
exec openbox-session
EOF
chmod +x "$ROOT/root/.xinitrc"

echo "[4] Network setup (ethernet auto + WiFi helper script)..."

mkdir -p "$ROOT/usr/local/bin"
cat > "$ROOT/usr/local/bin/connect-wifi" << 'EOF'
#!/bin/sh
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: connect-wifi <WiFi-name> <password>"
    exit 1
fi
IFACE=$(ls /sys/class/net | grep -E '^(wlan|wlp)' | head -n1)
if [ -z "$IFACE" ]; then
    echo "No WiFi adapter detected."
    exit 1
fi
wpa_passphrase "$1" "$2" > /etc/wpa_supplicant.conf
pkill wpa_supplicant 2>/dev/null
wpa_supplicant -B -i "$IFACE" -c /etc/wpa_supplicant.conf
dhcpcd "$IFACE"
echo "Connecting to $1 on $IFACE ..."
EOF
chmod +x "$ROOT/usr/local/bin/connect-wifi"

mkdir -p "$ROOT/root/Desktop"
cat > "$ROOT/root/Desktop/README.txt" << 'EOF'
Minimal Alpine GUI Live OS

INTERNET:
  - Ethernet (cable): works automatically.
  - WiFi: connect-wifi "YourWifiName" "YourPassword"

SOFTWARE (needs internet): apk add <package-name>

APPS: chromium | mpv <file> | feh <file> | zathura <file>
EOF

echo "[5] Enabling networking + udev at boot..."

chroot "$ROOT" /bin/sh -c "
    rc-update add udev sysinit 2>/dev/null || true
    rc-update add udev-trigger sysinit 2>/dev/null || true
    rc-update add dhcpcd default 2>/dev/null || true
    rc-update add networking default 2>/dev/null || true
"

echo "[6] Building initramfs..."

KERNEL_VER=$(chroot "$ROOT" /bin/sh -c "ls /lib/modules" | head -n1)
chroot "$ROOT" /bin/sh -c "mkinitfs -o /boot/initramfs-live $KERNEL_VER" || echo "[WARN] mkinitfs step may need adjustment"

echo "[7] Packing squashfs..."

mksquashfs "$ROOT" "$ISO/live/filesystem.squashfs" -comp xz -e boot

cp "$ROOT"/boot/vmlinuz-lts "$ISO/live/vmlinuz" 2>/dev/null || cp "$ROOT"/boot/vmlinuz-* "$ISO/live/vmlinuz"
cp "$ROOT"/boot/initramfs-live "$ISO/live/initrd" 2>/dev/null || cp "$ROOT"/boot/initramfs-* "$ISO/live/initrd"

echo "[8] GRUB config..."

cat > "$ISO/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=10
menuentry "Minimal Alpine GUI OS - Live" {
    linux /live/vmlinuz modules=loop,squashfs,sd-mod,usb-storage quiet
    initrd /live/initrd
}
EOF

echo "[9] Building ISO..."

grub-mkrescue --output=/tmp/minimal-alpine-os.iso "$ISO/" 2>&1 | tail -10

if [ -f /tmp/minimal-alpine-os.iso ]; then
    ls -lh /tmp/minimal-alpine-os.iso
    echo "=== Build complete ==="
else
    echo "=== ERROR: ISO was not produced ==="
    exit 1
fi