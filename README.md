# x-chip-tools

Host-side tooling to flash a Linux image onto a NextThing C.H.I.P.'s on-board
NAND over FEL (USB). One command fetches the latest image and writes it.

## Requirements

A Linux host (Debian or Ubuntu assumed below). Flashing happens over USB, so
this doesn't work from a VM unless you can pass the USB device through.

```sh
sudo apt update && sudo apt install -y sunxi-tools u-boot-tools openssh-client iputils-ping curl
```

`sunxi-fel` talks to the CHIP over raw USB, which needs permission. Add a udev
rule once, so you don't have to run the flasher as root:

```sh
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", ATTR{idProduct}=="efe8", MODE="0660", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/99-sunxi-fel.rules
sudo udevadm control --reload
```

`TAG+="uaccess"` grants access to whoever is logged in at the console, which
covers a normal desktop login. If your system doesn't do that (no systemd-logind,
or you're over SSH), use a group instead — swap the rule's tag for
`GROUP="plugdev"`, then add yourself and **log out and back in** for it to apply:

```sh
sudo usermod -aG plugdev "$USER"
```

## Quick start

1. **Power off** the CHIP and unplug it.
2. **Jumper FEL to GND** — `U14_7` (FEL) to any ground pin, e.g. `U14_1`. A
   paperclip or jumper wire is fine.
3. **Connect the micro-USB port to your machine.** The CHIP powers up in FEL
   mode and waits (no video output — that's expected).
4. **Flash:**

   ```sh
   ./update.sh <headless|gui|pocketchip|alpine>
   ```

5. When it finishes, **unplug, remove the jumper**, and power back on.

`update.sh` fetches the latest rootfs image (prompting before downloading a newer
one), the installer initrd, and the u-boot blobs from their GitHub releases,
caches them under `.images/`, then flashes. Re-running it later only downloads
what changed.

Log in as `chip` / `chip`.

## Troubleshooting

- **`sunxi-fel` says it can't access the device / `LIBUSB_ERROR_ACCESS`** — the
  udev rule above is missing or hasn't taken effect. Re-plug the CHIP after
  reloading the rules.
- **Nothing happens / no FEL device** — the jumper isn't making contact, or the
  board was already powered when you connected it. Unplug, re-check the FEL-to-GND
  jumper, plug back in. `lsusb` should list `1f3a:efe8` (Allwinner sunxi SoC OTG
  connector in FEL mode).
- **`gadget NIC never appeared`** — the live installer booted but its USB network
  interface didn't come up on the host. Check `dmesg` for a `usb0`-style interface;
  some network managers need a moment to configure it (the device runs its own
  DHCP server, so no manual addressing).
- **Flashing is slow** — expected. The rootfs streams over USB and is written to
  raw NAND on a 1 GHz ARMv7; the GUI images take a while.

## More

- **[ADVANCED_FLASHING.md](ADVANCED_FLASHING.md)** — the three flashing modes and
  when to use each, flashing a locally built image, and rebuilding the installer
  initramfs.
- u-boot and the images themselves live in the sibling `x-chip-uboot` / `x-chip-os`
  repos.
