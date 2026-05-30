#!/bin/bash
# Shared helpers for writing SPL + U-Boot to the CHIP's NAND boot region.
# Sourced by flash.sh (bootloader + rootfs in one shot) and
# flash-bootloader.sh (bootloader only).

# DRAM staging addresses for the bootloader blobs. Chosen to clear the
# installer payload in flash.sh (zImage 0x42000000, dtb 0x43000000,
# boot.scr 0x43100000, initrd 0x43300000 + ~30MiB) and u-boot's own
# 0x4A000000 load address.
SPLNAND_ADDR=0x46000000
UBOOT_ADDR=0x47000000

# build_bootloader_images <workdir>
# Honors env: UBOOT_DIR, SPL, UBOOT_BIN, SNIB, PAGE, OOB, EB.
# Produces $SPLNAND (BROM-formatted, one erase block of SPL copies) and
# $UBOOTPAD (u-boot padded to one erase block); sets $PAGES_PER_EB.
build_bootloader_images() {
  local work=$1

  : "${UBOOT_DIR:=../x-chip-uboot/build/u-boot}"
  : "${SPL:=$UBOOT_DIR/spl/sunxi-spl.bin}"
  : "${UBOOT_BIN:=$UBOOT_DIR/u-boot-dtb.bin}"
  : "${SNIB:=sunxi-nand-image-builder}"
  # Hynix 8G MLC geometry (this CHIP's NAND). Override for other parts.
  : "${PAGE:=16384}" "${OOB:=1664}" "${EB:=4194304}"

  rm -rf "$work"; mkdir -p "$work"

  # The BROM probes pages 0/64/128/192 of each erase block, so fill a whole
  # erase block with SPL copies, each padded out to 64 pages.
  local one="$work/spl-one.nand"
  SPLNAND="$work/spl.nand"
  $SNIB -c 64/1024 -p "$PAGE" -o "$OOB" -u 1024 -e "$EB" -b -s "$SPL" "$one"
  local one_pages=$(( $(stat -c%s "$one") / (PAGE + OOB) ))
  local pad_pages=$(( 64 - one_pages ))
  local copies=$(( EB / PAGE / 64 ))
  : > "$SPLNAND"
  local i
  for ((i = 0; i < copies; i++)); do
    dd if=/dev/urandom of="$work/pad" bs=1024 count="$pad_pages" status=none
    $SNIB -c 64/1024 -p "$PAGE" -o "$OOB" -u 1024 -e "$EB" -b -s "$work/pad" "$work/pad.nand"
    cat "$one" "$work/pad.nand" >> "$SPLNAND"
  done

  UBOOTPAD="$work/uboot.bin"
  dd if="$UBOOT_BIN" of="$UBOOTPAD" bs="$EB" conv=sync status=none

  PAGES_PER_EB=$(printf '0x%x' $(( EB / PAGE )))
}

# bootloader_write_cmds  ->  u-boot commands that erase the 16MiB boot
# region and write SPL (+ backup) and u-boot, leaving the rootfs UBI
# partition (>= 0x1000000) untouched. Relies on build_bootloader_images
# having set PAGES_PER_EB and the blobs being staged at SPLNAND_ADDR /
# UBOOT_ADDR.
bootloader_write_cmds() {
  cat <<EOF
echo == writing CHIP bootloader to NAND ==
nand erase 0x0 0x1000000
nand write.raw.noverify $SPLNAND_ADDR 0x0 $PAGES_PER_EB
nand write.raw.noverify $SPLNAND_ADDR 0x400000 $PAGES_PER_EB
nand write $UBOOT_ADDR 0x800000 0x400000
EOF
}
