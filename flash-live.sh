#!/bin/bash -e

# one-shot NAND flash over FEL + gadget-eth: rewrite SPL+u-boot, boot the
# installer, then format + stream the rootfs. no serial needed.
#   ./flash-live.sh <rootfs.tar[.gz]>

HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

ROOTFS_TAR=${1:?usage: flash-live.sh <rootfs.tar[.gz]>}

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}
INITRD=${INITRD:-build/initrd.uimage}
KEY=${KEY:-assets/installer_key}                        # committed throwaway key (see assets/)
GADGET_HOST_MAC=${GADGET_HOST_MAC:-de:ad:be:ef:53:02}   # matches init's host_addr
DEV_IP=${DEV_IP:-192.168.81.1}
BOOTARGS=${BOOTARGS:-'console=ttyS0,115200'}            # partitions come from the DT

# Shared bootloader-image helpers (per-NAND SPL build, NAND-type detection,
# boot-script wrapper) + the DRAM staging addresses they FEL-load to. Installer
# payload lives below them: zImage 0x42000000, dtb 0x43000000, boot.scr
# 0x43100000, initrd 0x43300000 (+~30MiB); SPL/u-boot at 0x46/0x47/0x48; all
# clear of u-boot's own >= 0x4A000000.
source "$HERE/lib-nand.sh"

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
  # git doesn't preserve permissions on clone, chmod 0600 it
  chmod og-rw "$KEY"
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

# boot.scr: erase the boot region (also latches the NAND-ID byte for detection),
# rewrite the bootloader, then boot the installer kernel.
mk_uboot_script build/boot.scr <<EOF
echo == erasing CHIP boot region ==
nand erase 0x0 0x1000000
$(bootloader_write_cmds)
echo == booting installer ==
setenv bootargs '$BOOTARGS'
bootz 0x42000000 0x43300000 0x43000000
EOF

echo ">> FEL loading"
sunxi-fel -v -p uboot "$UBOOT" \
  write 0x42000000             "$ZIMAGE" \
  write 0x43000000             "$DTB" \
  write 0x43100000             build/boot.scr \
  write 0x43300000             "$INITRD" \
  write "$SPLNAND_HYNIX_ADDR"   "$SPLNAND_HYNIX" \
  write "$SPLNAND_TOSHIBA_ADDR" "$SPLNAND_TOSHIBA" \
  write "$UBOOT_ADDR"           "$UBOOTPAD"

wait_for_device
install_rootfs
