# lib-nand.sh -- shared NAND bootloader helpers for the CHIP flashers.
# Sourced by flash-live.sh (live-installer) and flash-ubi.sh (direct UBI write).
# Pure functions + DRAM staging-address constants; no side effects on source.

# DRAM staging addresses for the bootloader blobs. Both flashers FEL-load the
# two SPL variants + the padded u-boot here; kept clear of each flasher's own
# payload and of u-boot's load/relocation region (>= 0x4A000000).
SPLNAND_HYNIX_ADDR=${SPLNAND_HYNIX_ADDR:-0x46000000}
SPLNAND_TOSHIBA_ADDR=${SPLNAND_TOSHIBA_ADDR:-0x47000000}
UBOOT_ADDR=${UBOOT_ADDR:-0x48000000}

# build_bootloader_images <workdir>
# Build a BROM SPL image for EACH NAND part + the padded full u-boot.
# Sets: SPLNAND_HYNIX, SPLNAND_TOSHIBA, UBOOTPAD, PAGES_PER_EB.
build_bootloader_images() {
  local work=$1

  : "${UBOOT_DIR:=../x-chip-uboot/build/u-boot}"
  : "${SPL:=$UBOOT_DIR/spl/sunxi-spl.bin}"
  : "${UBOOT_BIN:=$UBOOT_DIR/u-boot-dtb.bin}"
  : "${SNIB:=sunxi-nand-image-builder}"
  # Erase block + page are identical on both CHIP NAND parts; only the OOB
  # (spare/ECC) size differs -- SK Hynix H27UCG8T2ETR 1664, Toshiba
  # TC58TEG5DCLTA00 1280 -- so build a BROM SPL image for each and let u-boot
  # write whichever matches the detected chip.
  : "${PAGE:=16384}" "${EB:=4194304}"
  : "${OOB_HYNIX:=1664}" "${OOB_TOSHIBA:=1280}"

  rm -rf "$work"; mkdir -p "$work"

  SPLNAND_HYNIX="$work/spl.hynix.nand"
  SPLNAND_TOSHIBA="$work/spl.toshiba.nand"
  _build_spl_image "$OOB_HYNIX"   "$SPLNAND_HYNIX"
  _build_spl_image "$OOB_TOSHIBA" "$SPLNAND_TOSHIBA"

  UBOOTPAD="$work/uboot.bin"
  dd if="$UBOOT_BIN" of="$UBOOTPAD" bs="$EB" conv=sync status=none

  PAGES_PER_EB=$(printf '0x%x' $(( EB / PAGE )))
}

# _build_spl_image <oob> <outfile>
# Fill one erase block with SPL copies at the BROM-probed pages (0/64/128/192),
# random padding between, using the given OOB geometry.
_build_spl_image() {
  local oob=$1 out=$2 work
  work=$(dirname "$out")
  local one="$work/spl-one.$oob.nand"
  $SNIB -c 64/1024 -p "$PAGE" -o "$oob" -u 1024 -e "$EB" -b -s "$SPL" "$one"
  local one_pages=$(( $(stat -c%s "$one") / (PAGE + oob) ))
  local pad_pages=$(( 64 - one_pages ))
  local copies=$(( EB / PAGE / 64 ))
  : > "$out"
  local i
  for ((i = 0; i < copies; i++)); do
    dd if=/dev/urandom of="$work/pad.$oob" bs=1024 count="$pad_pages" status=none
    $SNIB -c 64/1024 -p "$PAGE" -o "$oob" -u 1024 -e "$EB" -b -s "$work/pad.$oob" "$work/pad.$oob.nand"
    cat "$one" "$work/pad.$oob.nand" >> "$out"
  done
}

# bootloader_write_cmds  ->  u-boot commands (stdout)
# Detect the NAND part (Hynix vs Toshiba) and write SPL(+backup)+u-boot from the
# FEL-staged images. The caller MUST have already issued a `nand erase ...`: the
# chip-ID byte at *0x1c03035 only reads back correctly after an erase initialises
# the NAND controller (40 = Toshiba, 60 = Hynix; learned from Chris Morgan's
# flashing scripts via cindy's NAND book). Defaults to Hynix if neither matches,
# so a detection miss preserves the old Hynix-only behaviour. Leaves the rootfs
# UBI region (>= 0x1000000) untouched.
bootloader_write_cmds() {
  cat <<EOF
echo == writing CHIP bootloader to NAND ==
setenv spl_img $SPLNAND_HYNIX_ADDR
if itest.b *0x1c03035 == 40; then echo "  Toshiba NAND detected"; setenv spl_img $SPLNAND_TOSHIBA_ADDR; fi
if itest.b *0x1c03035 == 60; then echo "  Hynix NAND detected";   setenv spl_img $SPLNAND_HYNIX_ADDR;   fi
nand write.raw.noverify \${spl_img} 0x0 $PAGES_PER_EB
nand write.raw.noverify \${spl_img} 0x400000 $PAGES_PER_EB
nand write $UBOOT_ADDR 0x800000 0x400000
EOF
}

# mk_uboot_script <out>   (u-boot commands on stdin)
# wrap u-boot commands into a bootable script image
mk_uboot_script() {
  local out=$1 tmp
  tmp=$(mktemp)
  cat > "$tmp"
  mkimage -A arm -O linux -T script -C none -n chip-nand -d "$tmp" "$out" >/dev/null
  rm -f "$tmp"
}
