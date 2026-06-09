#!/bin/bash -e

# one-shot NAND flash over FEL + gadget-eth: rewrite SPL+u-boot, boot the
# installer, then format + stream the rootfs. no serial needed.
#   ./flash.sh <rootfs.tar[.gz]>

HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

ROOTFS_TAR=${1:?usage: flash.sh <rootfs.tar[.gz]>}

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}
INITRD=${INITRD:-build/initrd.uimage}
KEY=${KEY:-assets/installer_key}                        # committed throwaway key (see assets/)
GADGET_HOST_MAC=${GADGET_HOST_MAC:-de:ad:be:ef:53:02}   # matches init's host_addr
DEV_IP=${DEV_IP:-192.168.81.1}
BOOTARGS=${BOOTARGS:-'console=ttyS0,115200'}            # partitions come from the DT

# DRAM staging addresses for the bootloader blobs, clear of the installer
# payload (zImage 0x42000000, dtb 0x43000000, boot.scr 0x43100000,
# initrd 0x43300000 +~30MiB) and u-boot's own 0x4A000000.
SPLNAND_ADDR=0x46000000
UBOOT_ADDR=0x47000000

# build the BROM-formatted SPL image (one erase block of SPL copies) and the
# padded u-boot -> $SPLNAND, $UBOOTPAD; sets $PAGES_PER_EB.
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

# u-boot commands to erase the 16MiB boot region and write SPL(+backup)+u-boot,
# leaving the rootfs UBI partition (>= 0x1000000) untouched.
bootloader_write_cmds() {
  cat <<EOF
echo == writing CHIP bootloader to NAND ==
nand erase 0x0 0x1000000
nand write.raw.noverify $SPLNAND_ADDR 0x0 $PAGES_PER_EB
nand write.raw.noverify $SPLNAND_ADDR 0x400000 $PAGES_PER_EB
nand write $UBOOT_ADDR 0x800000 0x400000
EOF
}

# wrap u-boot commands (read from stdin) into a bootable script image
mk_uboot_script() {
  local out=$1 tmp
  tmp=$(mktemp)
  cat > "$tmp"
  mkimage -A arm -O linux -T script -C none -n chip-nand -d "$tmp" "$out" >/dev/null
  rm -f "$tmp"
}

# The installer boots on the SAME -chip kernel that's in the rootfs (apt-installed
# during the live-build), so pull zImage + nand dtb straight out of $ROOTFS_TAR
# -> $ZIMAGE, $DTB. No separate kernel artifact needed. Override ZIMAGE/DTB to
# boot a different installer kernel.
resolve_kernel() {
  if [ -z "${ZIMAGE:-}" ] || [ -z "${DTB:-}" ]; then
    rm -rf build/kernel && mkdir -p build/kernel
    local z=; case "$ROOTFS_TAR" in *.gz) z=z ;; esac
    # tar stores paths as ./boot/... (build.sh packs with `-C binary .`).
    tar -C build/kernel "-x${z}f" "$ROOTFS_TAR" --wildcards \
        './boot/vmlinuz-*-chip' \
        './boot/dtbs/*/sun5i-r8-chip.dtb' \
        './usr/lib/linux-image-*/sun5i-r8-chip.dtb' 2>/dev/null || true
  fi
  ZIMAGE=${ZIMAGE:-$(ls -1 build/kernel/boot/vmlinuz-*-chip 2>/dev/null | head -1)}
  DTB=${DTB:-$(find build/kernel -name sun5i-r8-chip.dtb 2>/dev/null | head -1)}
  [ -n "$ZIMAGE" ] && [ -n "$DTB" ] || {
    echo "could not extract installer kernel+dtb from $ROOTFS_TAR; set ZIMAGE and DTB" >&2; exit 1; }
}

# wait for the gadget nic (by pinned mac), then for the device to ping.
# the device runs dnsmasq, so the host auto-addresses the nic (no ip/sudo).
wait_for_device() {
  local iface=""
  echo -n ">> waiting for gadget NIC ($GADGET_HOST_MAC)"
  for _ in $(seq 120); do
    for a in /sys/class/net/*/address; do
      [ "$(cat "$a" 2>/dev/null)" = "$GADGET_HOST_MAC" ] && iface=$(basename "$(dirname "$a")")
    done
    [ -n "$iface" ] && break
    echo -n "."; sleep 1
  done
  [ -n "$iface" ] || { echo " not found"; echo "gadget NIC never appeared" >&2; exit 1; }
  echo " $iface"
  echo -n ">> waiting for $DEV_IP"
  until ping -c1 -w1 "$DEV_IP" >/dev/null 2>&1; do echo -n "."; sleep 1; done
  echo " ok"
}

# Drive the FEL-booted installer over ssh: format the SLC UBI volume and
# stream in the Debian rootfs. The install runs entirely from Linux on the
# device, so the UBIFS is written through the same sunxi_nand/UBI stack that
# mounts it at runtime -- no fastboot, no geometry/ECC mismatch. rootfs is
# mtd4 per the kernel NAND device tree (SPL=0, SPL.backup=1, U-Boot=2,
# env=3, rootfs=4).
install_rootfs() {
  local ssh="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$DEV_IP"

  # Format + mount in ONE ssh session. dropbear in a tiny initramfs handles a
  # single long connection far more reliably than a burst of short-lived ones.
  echo ">> formatting SLC UBI volume"
  $ssh 'sh -seux' <<'REMOTE'
cat /proc/mtd
umount -l /rootfs 2>/dev/null || true   # drop any stale mount from a re-run
ubidetach -m 4 2>/dev/null || true      # in case of a re-run
ubiformat /dev/mtd4 -y
ubiattach -m 4
ubimkvol /dev/ubi0 --name rootfs -m     # -m: take all available space
mkfs.ubifs /dev/ubi0_0
# mkfs.ubifs -x zlib                     # zlib: best ratio (fewest NAND reads on a
                                         # storage-bound board) AND readable by
                                         # u-boot, which mounts this to load the
                                         # kernel/dtb. NOT zstd: u-boot's ubifs has
                                         # no zstd decompressor -> superblock -EINVAL.
mkdir -p /rootfs
mount -t ubifs /dev/ubi0_0 /rootfs
REMOTE

  # Board has no RTC (boots at epoch 0); set the clock so extracted mtimes
  # aren't all "in the future".
  $ssh "date -s @$(date +%s)" || true

  # Stream the rootfs in over a second connection. Send it still-compressed
  # and decompress on the device so far fewer bytes cross the (flaky) USB-net
  # link. `dd status=progress` (coreutils) gives a live readout; it throttles
  # to the real ssh/NAND throughput, so it reflects actual progress.
  echo ">> streaming rootfs into UBIFS"
  local tarflags
  case "$ROOTFS_TAR" in
    *.gz) tarflags=xzf ;;
    *)    tarflags=xf  ;;
  esac
  dd if="$ROOTFS_TAR" bs=1M status=progress | $ssh "tar -C /rootfs -$tarflags -"

  # Flush and tear down on a third connection. Block on a *real* umount -- a
  # successful UBIFS umount commits the journal before returning. Retry until
  # /rootfs is truly gone (handles a transient busy, peels stacked mounts);
  # never lazy-detach, so we don't pull UBI out from under a live filesystem.
  echo ">> syncing + tearing down"
  $ssh 'sh -seux' <<'REMOTE'
sync
for _ in $(seq 60); do
  grep -q ' /rootfs ' /proc/mounts || break
  umount /rootfs || sleep 1
done
if grep -q ' /rootfs ' /proc/mounts; then
  echo "ERROR: /rootfs still mounted; refusing to detach UBI" >&2
  exit 1
fi
ubidetach -m 4
REMOTE

  echo ">> flash complete -- remove the FEL jumper and reboot into NAND"
}

resolve_kernel
build_bootloader_images build/bootloader

# boot.scr: rewrite the bootloader, then boot the installer kernel
mk_uboot_script build/boot.scr <<EOF
$(bootloader_write_cmds)
echo == booting installer ==
setenv bootargs '$BOOTARGS'
bootz 0x42000000 0x43300000 0x43000000
EOF

echo ">> FEL loading"
sunxi-fel -v -p uboot "$UBOOT" \
  write 0x42000000      "$ZIMAGE" \
  write 0x43000000      "$DTB" \
  write 0x43100000      build/boot.scr \
  write 0x43300000      "$INITRD" \
  write "$SPLNAND_ADDR" "$SPLNAND" \
  write "$UBOOT_ADDR"   "$UBOOTPAD"

wait_for_device
install_rootfs
