#!/bin/bash -ex

# build the "live image" to install from
# minimal debian with a few things and
# hardcocded ssh keys

HERE=$PWD
ROOT=build/initramfs-root
SUITE=trixie

rm -rf build
mkdir -p build

# minimal rootfs with flashing utilities
debootstrap --arch=armhf --variant=minbase \
  --include=mtd-utils,dropbear-bin,iproute2,dnsmasq-base \
  "$SUITE" "$ROOT" http://deb.debian.org/debian

# bake the committed public key into the initramfs
install -d -m0700 "$ROOT/root/.ssh"
install -m0600 "$HERE/installer_key.pub" "$ROOT/root/.ssh/authorized_keys"
install -d -m0755 "$ROOT/etc/dropbear"

# init that brings up the gadget eth and starts dropbear
install -m0755 "$HERE/init" "$ROOT/init"

# trim unnecessary stuff
rm -rf \
  "$ROOT"/usr/share/doc/* \
  "$ROOT"/usr/share/man/* \
  "$ROOT"/usr/share/locale/* \
  "$ROOT"/usr/share/info/* \
  "$ROOT"/var/lib/apt/lists/* \
  "$ROOT"/var/cache/apt/archives/* \
  "$ROOT"/usr/bin/qemu-*-static

# pack as gzip cpio, then wrap as a uboot ramdisk
( cd "$ROOT" && find . | cpio -o -H newc ) | gzip -9 > build/initramfs.cpio.gz
mkimage -A arm -O linux -T ramdisk -C gzip \
  -n "chip-nand-installer" \
  -d build/initramfs.cpio.gz \
  build/initrd.uimage

# chown build
[ -n "${HOST_UID:-}" ] && chown -R "$HOST_UID:$HOST_GID" "$HERE/build" || true
