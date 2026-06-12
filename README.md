# x-chip-tools

Host-side tooling to flash Debian onto a NextThing C.H.I.P.'s on-board NAND over
FEL (USB), plus the installer initramfs build.

## Quick start

```sh
./update.sh <headless|gui>
```

`update.sh` fetches the latest rootfs image (prompting before downloading a newer
one), the installer initrd, and the u-boot blobs from their GitHub releases,
caches them under `.images/`, then flashes. Jumper the CHIP into FEL mode (FEL pin
to GND) and connect USB before running.

## Flashing modes

`update.sh` (and the underlying scripts) support three ways to write the rootfs.
They differ only in *how the rootfs lands on NAND*; all three write SPL + u-boot
the same way and auto-detect the NAND part (Hynix vs Toshiba).

```sh
./update.sh [--flash-live | --flash-uboot | --flash-fastboot] <headless|gui>
```

| Mode | Flag | How the rootfs is written | Size limit | Needs |
| --- | --- | --- | --- | --- |
| **Live installer** (default) | `--flash-live` | FEL-boots a dropbear initramfs, streams the rootfs tar over USB-net, runs `mkfs.ubifs` **on the device** | none | network gadget |
| **Direct UBI** | `--flash-uboot` | Builds the UBIFS on the host, FEL-loads it into DRAM, u-boot `ubi writevol`s it | **~256 MiB** | root (mkfs) |
| **Fastboot** | `--flash-fastboot` | Builds a `ubinize`'d UBI image, streams it over USB **fastboot** into the rootfs partition | none | root, `ubinize`, `fastboot` |

### When to pick which

- **`--flash-live` (default)** — the safe, general choice. No image-size limit, and
  `mkfs.ubifs` runs on the device so the kernel reports the real SLC geometry (no
  host-side geometry guessing). Use this unless you have a reason not to. Requires
  the installer initrd (fetched automatically).
- **`--flash-uboot`** — no initramfs, simplest path, but the whole UBIFS is staged
  in DRAM for one `ubi writevol`, so it's capped at ~256 MiB (the window between
  u-boot's load address and its relocated heap). **Headless only** — the GUI
  rootfs won't fit. Good for quick headless reflashes.
- **`--flash-fastboot`** — no initramfs *and* no size cap: fastboot streams the
  image in ≤32 MiB sparse chunks, so the **GUI image fits**. Writes a full
  `ubinize`'d UBI image raw into the rootfs MTD partition. Needs `ubinize`
  (mtd-utils) and `fastboot` (android-tools-fastboot) on the host.

> Host deps for the non-default modes: `--flash-uboot` and `--flash-fastboot`
> build the filesystem image as **root** (to preserve ownership / setuid / device
> nodes), so they use `sudo` for the extract + `mkfs.ubifs`/`ubinize` steps.

## Running a flasher directly

The flashers also work standalone on a local `rootfs.tar.gz`, using sibling build
dirs (`../x-chip-uboot/build`, etc.) or `UBOOT`/`SPL`/`UBOOT_BIN`/`INITRD` env
overrides:

```sh
./flash-live.sh      <rootfs.tar.gz>   # live installer
./flash-ubi.sh       <rootfs.tar.gz>   # direct UBI write (DRAM-capped)
./flash-fastboot.sh  <rootfs.tar.gz>   # USB fastboot (streamed)
```

`lib-nand.sh` (sourced by all three) builds the per-NAND-part SPL images and the
NAND-type detection that selects the right one at flash time.

## Building the installer initramfs

```sh
make            # -> build/initrd.uimage (used by the live-installer path)
```

A push to the default branch publishes `initrd.uimage` as a GitHub release
(`installer-<date>`), which `update.sh --flash-live` consumes.
