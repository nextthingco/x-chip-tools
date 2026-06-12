#!/bin/bash -e

# NAND flash over FEL + USB fastboot. Unlike flash-ubi.sh this is NOT DRAM-capped:
# fastboot streams the image in <=32 MiB sparse chunks (CONFIG_FASTBOOT_BUF_SIZE),
# so even the GUI rootfs fits -- without the live-installer initramfs.
# Builds a full UBI image (ubinize) from the rootfs tar on the host, FEL-boots
# u-boot to write SPL/u-boot + enter fastboot, then `fastboot flash` the UBI image
# into the rootfs MTD partition.
#   ./flash-fastboot.sh <rootfs.tar[.gz]>
#
# Modeled on NTC's chip-fel-flash.sh -u. Our u-boot's fb_nand writes RAW to the
# named MTD partition (no UBI-volume awareness -- verified in fb_nand.c), so the
# image must be a complete ubinize'd UBI device (volume table included), NOT a
# bare ubifs and NOT a pre-created volume. Needs root for the rootfs extract +
# mkfs.ubifs (to preserve ownership/setuid/device nodes).
#
# Host deps: sunxi-fel, ubinize + mkfs.ubifs (mtd-utils), fastboot
# (android-tools-fastboot). img2simg (android-sdk-libsparse-utils) is optional --
# without it the raw .ubi is flashed and modern fastboot sparses it itself.

HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
source "$HERE/lib-nand.sh"

ROOTFS_TAR=${1:?usage: flash-fastboot.sh <rootfs.tar[.gz]>}

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}

# Gadget IDs our u-boot advertises (CONFIG_USB_GADGET_VENDOR_NUM/PRODUCT_NUM).
FB_VID=${FB_VID:-0x1f3a}
FB=(fastboot -i "$FB_VID")
FB_PART=${FB_PART:-rootfs}        # we pass this; the host appends the slot suffix

# u-boot v2022.01's getvar_current_slot() is hardcoded to report current-slot="a"
# (even with CONFIG_ANDROID_AB off), so the host fastboot flashes 'rootfs_a'. We
# expose exactly that name at flash time -- same offsets + slc flag as the baked
# CONFIG_MTDPARTS_DEFAULT, only the leaf renamed rootfs->rootfs_a. It's RAM-only
# (no saveenv), so after reset u-boot/kernel see the default 'rootfs' again.
# (Proper fix is a u-boot patch making current-slot report unsupported.)
FB_MTDPARTS=${FB_MTDPARTS:-'mtdparts=nand0:4m(SPL),4m(SPL.backup),4m(U-Boot),4m(U-Boot.backup),-(rootfs_a)slc'}

# boot.scr staging addr -- past the fastboot download buffer (0x42000000 +
# 0x2000000 = 0x44000000), so fastboot transfers can't clobber the live script.
SCRIPT_ADDR=${SCRIPT_ADDR:-0x44100000}

# On-NAND rootfs UBI geometry (SLC-on-MLC): 2 MiB PEB (half the 4 MiB MLC erase
# block), 16 KiB min-io/page, LEB = PEB - 2*page. Matches flash-ubi.sh + the DTS.
PAGE=${PAGE:-16384}
PEB=${PEB:-2097152}                            # 0x200000 SLC eraseblock
UBIFS_LEB=${UBIFS_LEB:-$(( PEB - 2 * PAGE ))}   # 2064384
UBIFS_MAX_LEB=${UBIFS_MAX_LEB:-4096}

need_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# Build build/rootfs.ubi (full UBI image); sets FB_IMG to it (or a sparse copy).
build_ubi() {
  # /sbin doesn't show up in this
  # command -v ubinize >/dev/null || { echo "need ubinize (mtd-utils)" >&2; exit 1; }
  local z=; case "$ROOTFS_TAR" in *.gz) z=z ;; esac
  local root="build/ubifs-root" cfg="build/ubi.cfg" ubifs="build/rootfs.ubifs"
  UBI_IMG="build/rootfs.ubi"
  mkdir -p build
  need_root rm -rf "$root"; rm -f "$ubifs" "$UBI_IMG" "$UBI_IMG.sparse"
  mkdir -p "$root"

  echo ">> extracting rootfs (root, to preserve ownership)"
  need_root tar -C "$root" "-x${z}f" "$ROOTFS_TAR"

  # Default LZO compressor: u-boot reads it (it ubifsload's kernel/dtb from this
  # volume after boot); it has no zstd decompressor.
  echo ">> building UBIFS (LEB=$UBIFS_LEB min-io=$PAGE, lzo)"
  need_root mkfs.ubifs -m "$PAGE" -e "$UBIFS_LEB" -c "$UBIFS_MAX_LEB" -d "$root" -o "$ubifs"
  need_root rm -rf "$root"

  # autoresize: UBI grows the volume to fill the rootfs partition on first attach
  # (works for both Hynix 8G and Toshiba 4G parts, halved in SLC).
  cat > "$cfg" <<CFG
[rootfs]
mode=ubi
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_alignment=1
vol_flags=autoresize
image=$ubifs
CFG

  echo ">> ubinize -> UBI image (PEB=$PEB)"
  need_root ubinize -o "$UBI_IMG" -p "$PEB" -m "$PAGE" -s "$PAGE" "$cfg"
  need_root chown "$(id -u):$(id -g)" "$UBI_IMG"
  rm -f "$ubifs" "$cfg"

  if command -v img2simg >/dev/null 2>&1; then
    echo ">> img2simg -> sparse"
    img2simg "$UBI_IMG" "$UBI_IMG.sparse" "$PEB"
    FB_IMG="$UBI_IMG.sparse"
  else
    echo ">> img2simg not found; flashing raw (fastboot will sparse it)"
    FB_IMG="$UBI_IMG"
  fi
  echo ">> UBI image: $(stat -c%s "$UBI_IMG") bytes"
}

wait_for_fel() {
  echo "# connect CHIP with the FEL pin pulled low (jumper FEL to GND)"
  until sunxi-fel ver >/dev/null 2>&1; do sleep 0.5; done
}

wait_for_fastboot() {
  command -v fastboot >/dev/null || { echo "need fastboot (android-tools-fastboot)" >&2; exit 1; }
  echo -n "# waiting for fastboot device ($FB_VID)"
  until [ -n "$("${FB[@]}" devices 2>/dev/null)" ]; do echo -n "."; sleep 0.5; done
  echo " ok"
}

build_ubi
build_bootloader_images build/bootloader
wait_for_fel

# boot.scr: full-chip erase (also latches the NAND-ID byte for detection), write
# SPL+u-boot, then hand off to USB fastboot. `fastboot usb 0` is the LAST command
# -- it blocks serving the host, and the host's `fastboot reboot` resets the board,
# so u-boot never returns to re-read the script.
mk_uboot_script build/boot.scr <<EOF
echo == erasing NAND ==
nand erase.chip
$(bootloader_write_cmds)
setenv mtdparts '$FB_MTDPARTS'
echo == entering fastboot -- flash '${FB_PART}_a' from the host ==
fastboot usb 0
EOF

echo ">> FEL loading"
sunxi-fel -v -p uboot "$UBOOT" \
  write "$SCRIPT_ADDR"          build/boot.scr \
  write "$SPLNAND_HYNIX_ADDR"   "$SPLNAND_HYNIX" \
  write "$SPLNAND_TOSHIBA_ADDR" "$SPLNAND_TOSHIBA" \
  write "$UBOOT_ADDR"           "$UBOOTPAD"

wait_for_fastboot
echo ">> flashing '$FB_PART' (streamed, no DRAM cap)"
"${FB[@]}" flash "$FB_PART" "$FB_IMG"
echo ">> rebooting into NAND"
"${FB[@]}" reboot

echo ">> done -- remove the FEL jumper if still set"
