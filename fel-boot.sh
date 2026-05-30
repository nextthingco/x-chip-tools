#!/bin/bash -ex

# FEL-boot the NAND installer environment (debug/manual path): u-boot +
# -chip kernel + NAND dtb + installer initramfs. Unlike flash.sh this does
# NOT rewrite the bootloader and does NOT run the install -- it just gets
# the device onto USB-net so you can poke at it or run install-nand.sh by
# hand.
#
# Put the CHIP in FEL mode (FEL pin to GND), connect USB, then run this.
#
# Paths default to the sibling project build outputs; override via env.

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}
INITRD=${INITRD:-build/initrd.uimage}
# Partitions come from the DT fixed-partitions node, so no mtdparts= needed.
BOOTARGS=${BOOTARGS:-'console=ttyS0,115200'}

# zImage and the NAND device tree live inside the -chip kernel .deb, so by
# default we pull them out of x-chip-linux-deb/build into our build/kernel.
KERNEL_DEB=${KERNEL_DEB:-$(ls -1 ../x-chip-linux-deb/build/linux-image-*-chip_*.deb 2>/dev/null | head -1)}
if [ -z "${ZIMAGE:-}" ] || [ -z "${DTB:-}" ]; then
  [ -n "$KERNEL_DEB" ] || { echo "no -chip kernel .deb found; set ZIMAGE and DTB" >&2; exit 1; }
  rm -rf build/kernel && mkdir -p build/kernel
  dpkg -x "$KERNEL_DEB" build/kernel
fi
ZIMAGE=${ZIMAGE:-$(ls -1 build/kernel/boot/vmlinuz-*-chip | head -1)}
DTB=${DTB:-$(find build/kernel -name sun5i-r8-chip.dtb | head -1)}

# Installer-only boot script (no bootloader write): just boot the kernel.
mkdir -p build
cat > build/boot-installer.cmd <<EOF
setenv bootargs '$BOOTARGS'
bootz 0x42000000 0x43300000 0x43000000
EOF
mkimage -A arm -O linux -T script -C none \
  -n chip-nand-installer -d build/boot-installer.cmd build/boot-installer.scr

# Load addresses follow the cindy book / deepfry convention. The boot.scr
# goes to 0x43100000 (= sun5i fel_scriptaddr); u-boot's bootcmd_fel sources
# it automatically on a FEL boot, so no serial interaction is needed.
sunxi-fel -v -p uboot "$UBOOT" \
  write 0x42000000 "$ZIMAGE" \
  write 0x43000000 "$DTB" \
  write 0x43100000 build/boot-installer.scr \
  write 0x43300000 "$INITRD"

cat <<'EOF'

Loaded. U-Boot will auto-source the FEL boot script and boot into the
installer (no serial interaction needed). Once it is up, run:

    ./install-nand.sh <rootfs.tar[.gz]>
EOF
