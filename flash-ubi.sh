#!/bin/bash -e

# Direct NAND flash over FEL -- no live installer, no network, no fastboot.
# Builds a UBIFS image from the rootfs tar on the HOST, then FEL-loads it plus
# the bootloader and has u-boot write SPL, u-boot and the rootfs UBI volume
# straight to NAND, following cindy's "look mom no UART" scripts. One
# power-cycle later the CHIP boots from NAND.
#   ./flash-ubi.sh <rootfs.tar[.gz]>
#
# TRADE-OFF vs flash-live.sh: the whole UBIFS image is staged in DRAM for a single
# `ubi writevol`, so it must fit the FEL/u-boot DRAM budget (UBIFS_MAX_BYTES).
# Large images (e.g. the GUI flavor) won't fit -- use ./flash-live.sh (which streams
# the rootfs over USB-net and writes it incrementally) for those.
#
# Needs root for the rootfs extract + mkfs.ubifs (to preserve ownership / setuid
# / device nodes); it uses sudo for just those steps if not already root.

HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
source "$HERE/lib-nand.sh"

ROOTFS_TAR=${1:?usage: flash-ubi.sh <rootfs.tar[.gz]>}

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}

# UBIFS image staging in DRAM (512 MiB, 0x40000000-0x60000000). The buffer goes
# ABOVE the FEL-staged bootloader blobs + u-boot's load image at 0x4A000000
# (SYS_TEXT_BASE) and BELOW u-boot's reserved top region (video FB + ~64 MiB
# CONFIG_SYS_MALLOC_LEN heap + stack). The image's TAIL must stay clear of that
# top region or it doesn't survive the FEL blast -> the last LEB reads back as
# zeros and the kernel/u-boot can't read the rootfs superblock.
# Cap from MEASURED u-boot footprint (bdinfo, 512 MiB, same binary FEL or NAND).
# u-boot relocates to the top and its lmb reservation floor is 0x59f37758
# (stack/fdt ~0x59f3b9xx, 64 MiB CONFIG_SYS_MALLOC_LEN arena up to relocaddr
# 0x5df62000, then FB base 0x5e000000) -- a ~97 MiB footprint. FEL delivery of a
# large image is handled by chunking (below), so the only limit left is this: the
# image TAIL (ROOTFS_ADDR + size) must stay below 0x59f37758. Reserve 104 MiB
# (ceiling 0x59800000, ~7 MiB margin under the floor) -> 232 MiB cap. (The full
# ~303 MiB headless still won't fit -- use --flash-fastboot or the live installer.)
DRAM_TOP=0x60000000
UBOOT_TOP_RESERVE=$((104 * 1024 * 1024))
ROOTFS_ADDR=${ROOTFS_ADDR:-0x4B000000}
UBIFS_MAX_BYTES=${UBIFS_MAX_BYTES:-$(( DRAM_TOP - UBOOT_TOP_RESERVE - ROOTFS_ADDR ))}

# On-NAND rootfs geometry (SLC mode). In SLC mode UBI/UBIFS see HALF the raw MLC
# erase block, minus two min-io pages for UBI's per-PEB headers -- these match
# what the device kernel's UBI presents (see cindy's NAND book). min-io = page.
PAGE=${PAGE:-16384}
EB=${EB:-4194304}
UBIFS_MIN_IO=${UBIFS_MIN_IO:-$PAGE}
UBIFS_LEB=${UBIFS_LEB:-$(( EB / 2 - 2 * PAGE ))}     # 2064384 = 0x1f8000
UBIFS_MAX_LEB=${UBIFS_MAX_LEB:-4096}
# zlib packs ~10-15% tighter than the mkfs.ubifs default (lzo), which matters
# here because the image must fit the DRAM cap. u-boot's UBIFS reads zlib fine
# (it ubifsload's the kernel/dtb from this volume); only zstd is unsupported.
UBIFS_COMPR=${UBIFS_COMPR:-zlib}

# run a command as root (the script is otherwise unprivileged)
need_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# Extract the rootfs and build build/rootfs.ubifs. Sets UBIFS_IMG, UBIFS_SIZE.
build_ubifs() {
  local z=; case "$ROOTFS_TAR" in *.gz) z=z ;; esac
  local root="build/ubifs-root"
  mkdir -p build
  need_root rm -rf "$root"; rm -f build/rootfs.ubifs
  mkdir -p "$root"

  echo ">> extracting rootfs (root, to preserve ownership)"
  need_root tar -C "$root" "-x${z}f" "$ROOTFS_TAR"

  echo ">> building UBIFS (LEB=$UBIFS_LEB min-io=$UBIFS_MIN_IO, $UBIFS_COMPR)"
  need_root mkfs.ubifs -m "$UBIFS_MIN_IO" -e "$UBIFS_LEB" -c "$UBIFS_MAX_LEB" \
      -x "$UBIFS_COMPR" -d "$root" -o build/rootfs.ubifs
  need_root chown "$(id -u):$(id -g)" build/rootfs.ubifs
  need_root rm -rf "$root"

  UBIFS_IMG="build/rootfs.ubifs"
  UBIFS_SIZE=$(stat -c%s "$UBIFS_IMG")
  echo ">> UBIFS image: $UBIFS_SIZE bytes"
  if [ "$UBIFS_SIZE" -gt "$UBIFS_MAX_BYTES" ]; then
    echo "ERROR: UBIFS image ($UBIFS_SIZE B) exceeds the DRAM staging budget" \
         "($UBIFS_MAX_BYTES B)." >&2
    echo "       Too big for the direct FEL path; use ./flash-live.sh instead." >&2
    exit 1
  fi
}

wait_for_fel() {
  echo "# connect CHIP with the FEL pin pulled low (jumper FEL to GND)"
  until sunxi-fel ver >/dev/null 2>&1; do sleep 0.5; done
}

build_ubifs
build_bootloader_images build/bootloader
wait_for_fel

# boot.scr: full-chip erase (also latches the NAND-ID byte for detection), write
# SPL+u-boot, then create + fill the rootfs UBI volume from the staged image and
# reset into NAND. `ubi part rootfs` uses u-boot's built-in CONFIG_MTDPARTS_DEFAULT
# (verified in x-chip-uboot/nand.cfg) -- crucially it marks the rootfs partition
# `(rootfs)slc`, so we must NOT override mtdparts here or we'd lose SLC mode.
# Needs CONFIG_CMD_UBI (=y in the build; same path the runtime BOOTCOMMAND uses).
UBIFS_SIZE_HEX=$(printf '0x%x' "$UBIFS_SIZE")
mk_uboot_script build/boot.scr <<EOF
echo == erasing NAND ==
nand erase.chip
$(bootloader_write_cmds)
echo == writing rootfs UBI volume ($UBIFS_SIZE bytes) ==
ubi part rootfs
ubi createvol rootfs
ubi writevol $ROOTFS_ADDR rootfs $UBIFS_SIZE_HEX
echo == writevol done -- resetting into NAND ==
reset
EOF

# sunxi-fel silently truncates the tail of a single large `write` (confirmed on
# hw: a 254 MiB write drops its end, while a small write to the same high address
# is fine). Split the UBIFS into <=FEL_CHUNK pieces at consecutive addresses --
# they reassemble into one contiguous buffer at ROOTFS_ADDR, and each transfer is
# small enough to land in full.
FEL_CHUNK=${FEL_CHUNK:-$((64 * 1024 * 1024))}
rm -f build/ubichunk.*
split -b "$FEL_CHUNK" -d -a 3 "$UBIFS_IMG" build/ubichunk.
rootfs_writes=(); off=0
for chunk in build/ubichunk.*; do
  rootfs_writes+=(write "$(printf '0x%x' $(( ROOTFS_ADDR + off )))" "$chunk")
  off=$(( off + $(stat -c%s "$chunk") ))
done

echo ">> FEL loading (${#rootfs_writes[@]} args; rootfs in $(( (UBIFS_SIZE + FEL_CHUNK - 1) / FEL_CHUNK )) chunks)"
sunxi-fel -v -p uboot "$UBOOT" \
  write 0x43100000             build/boot.scr \
  write "$SPLNAND_HYNIX_ADDR"   "$SPLNAND_HYNIX" \
  write "$SPLNAND_TOSHIBA_ADDR" "$SPLNAND_TOSHIBA" \
  write "$UBOOT_ADDR"           "$UBOOTPAD" \
  "${rootfs_writes[@]}"

echo ">> writing NAND on the device; it will reset into NAND when finished"
echo ">> remove the FEL jumper and power-cycle once it reboots"
