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

| Mode | Flag | How the rootfs is written | Image size | Status |
| --- | --- | --- | --- | --- |
| **Live installer** (default) | `--flash-live` | FEL-boots a dropbear initramfs, streams the rootfs tar over USB-net, runs `mkfs.ubifs` **on the device** | any | ✅ works (needs USB-net gadget) |
| **Direct UBI** | `--flash-uboot` | Builds the UBIFS on the host (zlib), FEL-loads it into DRAM, u-boot `ubi writevol`s it | **≤ 232 MiB** | ✅ works (root for mkfs) |
| **Fastboot** | `--flash-fastboot` | Builds a `ubinize`'d UBI image, streams it over USB fastboot to the rootfs partition | any | ❌ broken on the SLC rootfs (see below) |

### When to pick which

- **`--flash-live` (default)** — the safe, general choice, **any image size**.
  `mkfs.ubifs` runs on the device so the kernel reports the real SLC geometry (no
  host-side geometry guessing). Use this unless you have a reason not to — and it's
  the **only** working path for the full headless (~303 MiB) and GUI images.
  Requires the installer initrd (fetched automatically) + the USB-net gadget.
- **`--flash-uboot`** — no initramfs, simplest path, but the whole UBIFS is staged
  in DRAM for one `ubi writevol`, so it's capped at **232 MiB** (measured via
  `bdinfo`: the window between u-boot's load address `0x4B000000` and its reserved
  top RAM at `0x59f37758`). The host build uses **zlib** (`UBIFS_COMPR`) to pack
  tighter. Good for quick **headless** reflashes that fit under the cap; it
  hard-errors and points you here if the image is too big.
- **`--flash-fastboot`** — ❌ **does not work on this rootfs, don't use it.**
  Fastboot streams fine (no DRAM cap), but u-boot's `fb_nand` writes the
  whole-chip NAND in plain **MLC** mode at the partition offset, bypassing our
  **per-partition SLC** emulation — so the SLC-mode boot reads uncorrectable ECC
  errors (`ubi_io_read error -74`) and won't mount. It's left in the tree for
  reference / a future `fb_nand` (or u-boot SLC) patch. For large images use
  `--flash-live`.

> Host deps: `--flash-uboot` (and the parked `--flash-fastboot`) build the
> filesystem image as **root** (to preserve ownership / setuid / device nodes),
> so they `sudo` the extract + `mkfs.ubifs`/`ubinize` steps.

## Running a flasher directly

The flashers also work standalone on a local `rootfs.tar.gz`, using sibling build
dirs (`../x-chip-uboot/build`, etc.) or `UBOOT`/`SPL`/`UBOOT_BIN`/`INITRD` env
overrides:

```sh
./flash-live.sh      <rootfs.tar.gz>   # live installer (any size)
./flash-ubi.sh       <rootfs.tar.gz>   # direct UBI write (<= 232 MiB)
./flash-fastboot.sh  <rootfs.tar.gz>   # USB fastboot -- broken on SLC rootfs (ECC)
```

`lib-nand.sh` (sourced by all three) builds the per-NAND-part SPL images and the
NAND-type detection that selects the right one at flash time.

## Building the installer initramfs

```sh
make            # -> build/initrd.uimage (used by the live-installer path)
```

A push to the default branch publishes `initrd.uimage` as a GitHub release
(`installer-<date>`), which `update.sh --flash-live` consumes.
