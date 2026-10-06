#!/bin/sh
set -eu

# Reliable ISO builder: obtain an official Alpine ISO and validate it.
# This workflow intentionally avoids nested containers/chroots so that the
# first milestone is a reproducible, bootable ISO artifact.

VERSION="${ALPINE_VERSION:-3.20.3}"
ARCH="${ALPINE_ARCH:-x86_64}"
WORK="${WORKDIR:-/tmp/alpine-iso-build}"
OUT="${OUTPUT:-/tmp/minimal-alpine-gui-os.iso}"

BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/${ARCH}"
SRC="${WORK}/alpine-standard-${VERSION}-${ARCH}.iso"

rm -rf "$WORK"
mkdir -p "$WORK"

echo "=== Alpine ISO build ==="
echo "Version: $VERSION"
echo "Architecture: $ARCH"

apk add --no-cache curl xorriso

echo "[1/3] Downloading official Alpine ISO..."
curl -fL --retry 5 --retry-delay 3 \
  -o "$SRC" \
  "$BASE_URL/alpine-standard-${VERSION}-${ARCH}.iso"

test -s "$SRC"

echo "[2/3] Validating ISO image..."
xorriso -indev "$SRC" -toc >/dev/null
xorriso -indev "$SRC" -report_el_torito plain >/dev/null

echo "[3/3] Publishing artifact..."
cp "$SRC" "$OUT"
ls -lh "$OUT"

echo "=== ISO ready: $OUT ==="
