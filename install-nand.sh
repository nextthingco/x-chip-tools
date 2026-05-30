#!/bin/bash -ex

# Drives the FEL-booted installer (see fel-boot.sh) over ssh to format the
# SLC UBI volume and stream in the Debian rootfs. Runs entirely from Linux
# on the device, so the UBIFS is written through the same sunxi_nand/UBI
# stack that mounts it at runtime -- no fastboot, no geometry/ECC mismatch.
#
# usage: ./install-nand.sh <rootfs.tar[.gz]>

CHIP_ADDR=${CHIP_ADDR:-192.168.81.1}
KEY=${KEY:-installer_key}   # committed throwaway key; see build-initramfs.sh
ROOTFS_TAR=${1:?usage: install-nand.sh <rootfs.tar[.gz]>}

SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$CHIP_ADDR"

echo -n "waiting for installer network..."
until ping -c1 -w1 "$CHIP_ADDR" >/dev/null 2>&1; do echo -n "."; sleep 1; done
echo " ok"

# Do the whole format + mount in ONE ssh session. dropbear in a tiny
# initramfs handles a single long connection far more reliably than a
# burst of short-lived ones. rootfs is mtd4 per the kernel NAND device
# tree (SPL=0, SPL.backup=1, U-Boot=2, env=3, rootfs=4).
echo "formatting SLC UBI volume..."
$SSH 'sh -seux' <<'REMOTE'
cat /proc/mtd
umount -l /rootfs 2>/dev/null || true   # drop any stale mount from a re-run
ubidetach -m 4 2>/dev/null || true      # in case of a re-run
ubiformat /dev/mtd4 -y
ubiattach -m 4
ubimkvol /dev/ubi0 --name rootfs -m      # -m: take all available space
mkfs.ubifs /dev/ubi0_0                    # so U-Boot can mount it too
mkdir -p /rootfs
mount -t ubifs /dev/ubi0_0 /rootfs
REMOTE

# Set the device clock so extracted mtimes aren't all "in the future"
# (the board has no RTC; it boots at epoch 0).
$SSH "date -s @$(date +%s)" || true

# Stream the rootfs in over a second connection. Send it still-compressed
# and decompress on the device so far fewer bytes cross the (flaky) USB-net
# link -- less time, less exposure to a mid-transfer gadget drop. `dd
# status=progress` (coreutils) gives a live bytes/rate readout; it throttles
# to the real ssh/NAND throughput, so it reflects actual progress.
echo "streaming rootfs into UBIFS..."
case "$ROOTFS_TAR" in
  *.gz) TARFLAGS=xzf ;;
  *)    TARFLAGS=xf  ;;
esac
dd if="$ROOTFS_TAR" bs=1M status=progress | $SSH "tar -C /rootfs -$TARFLAGS -"

# Flush and tear down on a third connection.
$SSH 'sh -seux' <<'REMOTE'
sync
# Block on a *real* umount -- a successful UBIFS umount commits the journal
# before returning. Retry until /rootfs is truly gone (handles a transient
# busy, and peels any stacked mounts); never lazy-detach, so we don't pull
# UBI out from under a still-live filesystem.
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

# Reboot straight into the freshly flashed NAND system. The installer runs a
# bare /bin/sh as PID 1 (no systemd), so /sbin/reboot won't work -- use the
# magic-sysrq trigger (CONFIG_MAGIC_SYSRQ=y): enable it, sync, then reboot.
# The ssh connection dies as the board resets, so ignore its exit status.
echo "flash complete -- rebooting (remove the FEL jumper to land in NAND)..."

## this seems to hang the shell, but it does reboot the thing
## commenting out for now
# $SSH 'echo 1 > /proc/sys/kernel/sysrq; echo s > /proc/sysrq-trigger; echo b > /proc/sysrq-trigger' || true
