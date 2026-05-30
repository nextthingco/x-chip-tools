#!/bin/bash -e

# Write ONLY the SPL + U-Boot to the CHIP's NAND boot partitions, over FEL,
# and leave the rootfs UBI partition untouched. Useful for updating the
# bootloader without reflashing the rootfs. The normal flash.sh already
# rewrites the bootloader on every run; this is the standalone variant.
#
# Run with the CHIP in FEL mode; u-boot's bootcmd_fel auto-runs the script.
# Uses the host's sunxi-nand-image-builder / sunxi-fel / mkimage.

set -x
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
. ./lib-bootloader.sh

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}

WORK=build/bootloader
build_bootloader_images "$WORK"

{
  bootloader_write_cmds
  echo "echo == bootloader written - power-cycle without the FEL jumper =="
} > "$WORK/boot.cmd"
mkimage -A arm -O linux -T script -C none \
  -n chip-bootloader -d "$WORK/boot.cmd" "$WORK/boot.scr"

sunxi-fel -v -p uboot "$UBOOT" \
  write 0x43100000   "$WORK/boot.scr" \
  write "$SPLNAND_ADDR" "$SPLNAND" \
  write "$UBOOT_ADDR"   "$UBOOTPAD"

echo "Loaded. U-Boot will auto-run the bootloader-write script."
