#!/bin/bash -e

# One-shot, hands-off NAND flash. In a single FEL session u-boot rewrites
# SPL + u-boot to the NAND boot region and then boots the installer
# kernel+initramfs. We then wait for the gadget NIC (matched by its pinned
# MAC), let the host auto-address it via the device's DHCP, and run the
# rootfs install. No serial interaction needed.
#
# Put the CHIP in FEL mode, connect USB, then:
#     ./flash.sh <rootfs.tar[.gz]>
#
# Override any default via env.

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
. ./lib-bootloader.sh

ROOTFS_TAR=${1:?usage: flash.sh <rootfs.tar[.gz]>}

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}
INITRD=${INITRD:-build/initrd.uimage}

# Must match the host_addr pinned in init.
GADGET_HOST_MAC=${GADGET_HOST_MAC:-de:ad:be:ef:53:02}
DEV_IP=${DEV_IP:-192.168.81.1}

# Installer kernel cmdline. Partitions come from the DT fixed-partitions
# node (verified), so mtd4 exists for install-nand.sh without mtdparts=.
BOOTARGS=${BOOTARGS:-'console=ttyS0,115200'}

# zImage + NAND dtb come out of the -chip kernel .deb.
KERNEL_DEB=${KERNEL_DEB:-$(ls -1 ../x-chip-linux-deb/build/linux-image-*-chip_*.deb 2>/dev/null | head -1)}
if [ -z "${ZIMAGE:-}" ] || [ -z "${DTB:-}" ]; then
  [ -n "$KERNEL_DEB" ] || { echo "no -chip kernel .deb found; set ZIMAGE and DTB" >&2; exit 1; }
  rm -rf build/kernel && mkdir -p build/kernel
  dpkg -x "$KERNEL_DEB" build/kernel
fi
ZIMAGE=${ZIMAGE:-$(ls -1 build/kernel/boot/vmlinuz-*-chip | head -1)}
DTB=${DTB:-$(find build/kernel -name sun5i-r8-chip.dtb | head -1)}

# --- 1. build SPL/u-boot NAND images + the combined FEL boot script ------
# boot.scr: rewrite the bootloader, then boot the installer kernel. u-boot's
# bootcmd_fel auto-sources it from 0x43100000 on a FEL boot.
build_bootloader_images build/bootloader
{
  bootloader_write_cmds
  echo "echo == booting installer =="
  echo "setenv bootargs '$BOOTARGS'"
  echo "bootz 0x42000000 0x43300000 0x43000000"
} > build/boot.cmd
mkimage -A arm -O linux -T script -C none \
  -n chip-nand-installer -d build/boot.cmd build/boot.scr

# --- 2. FEL-load everything into DRAM ------------------------------------
echo ">> FEL loading"
sunxi-fel -v -p uboot "$UBOOT" \
  write 0x42000000      "$ZIMAGE" \
  write 0x43000000      "$DTB" \
  write 0x43100000      build/boot.scr \
  write 0x43300000      "$INITRD" \
  write "$SPLNAND_ADDR" "$SPLNAND" \
  write "$UBOOT_ADDR"   "$UBOOTPAD"

# --- 3. wait for the gadget NIC + DHCP connectivity ----------------------
# The device runs dnsmasq, so the host's network manager auto-addresses the
# gadget NIC -- no manual ip/sudo. We just wait for the NIC to appear (by
# its pinned MAC) and for the device to become reachable.
echo -n ">> waiting for gadget NIC ($GADGET_HOST_MAC)"
iface=""
for _ in $(seq 1 120); do
  for a in /sys/class/net/*/address; do
    if [ "$(cat "$a" 2>/dev/null)" = "$GADGET_HOST_MAC" ]; then
      iface=$(basename "$(dirname "$a")"); break
    fi
  done
  [ -n "$iface" ] && break
  echo -n "."; sleep 1
done
[ -n "$iface" ] || { echo " not found"; echo "gadget NIC never appeared" >&2; exit 1; }
echo " $iface"

echo -n ">> waiting for DHCP connectivity to $DEV_IP (host should auto-address $iface)"
until ping -c1 -w1 "$DEV_IP" >/dev/null 2>&1; do echo -n "."; sleep 1; done
echo " ok"

# --- 4. format the SLC UBI volume and stream in the rootfs ---------------
CHIP_ADDR="$DEV_IP" exec ./install-nand.sh "$ROOTFS_TAR"
