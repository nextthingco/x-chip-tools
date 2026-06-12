#!/bin/bash -e

# Fetch the latest CHIP artifacts from GitHub releases and flash a flavor.
#   ./update.sh <headless|gui>
#
# Three per-repo releases feed a flash (see memory: flash-release-topology):
#   - rootfs   <- nextthingco/x-chip-os     asset <flavor>-rootfs.tar.gz   (PROMPTED)
#   - initrd   <- nextthingco/x-chip-tools  asset initrd.uimage            (auto)
#   - u-boot   <- nextthingco/x-chip-uboot  sunxi-spl.bin/u-boot-dtb.bin/  (auto)
#                                           u-boot-sunxi-with-spl.bin
#
# The rootfs is versioned and the user is PROMPTED before downloading a newer
# build; declining reuses the newest local image, and if there is none we exit.
# Exactly one image is kept per flavor (a new download replaces the old).
# The installer initrd and u-boot blobs auto-track latest with no prompt.

HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

usage() { echo "usage: update.sh [--flash-live|--flash-uboot|--flash-fastboot] <headless|gui>" >&2; exit "${1:-2}"; }

# --flash-live (default): FEL-boot the installer initramfs + stream the rootfs
#                         (flash-live.sh) -- works for any image size.
# --flash-uboot:          build the UBIFS on the host + write it straight via
#                         u-boot ubi writevol (flash-ubi.sh) -- no initramfs, but
#                         DRAM-capped (~256 MiB), so headless only.
# --flash-fastboot:       build a UBI image + flash it over USB fastboot
#                         (flash-fastboot.sh) -- no initramfs, streamed so NOT
#                         size-capped (GUI fits).
MODE=live
FLAVOR=
while [ $# -gt 0 ]; do
  case "$1" in
    --flash-live)     MODE=live ;;
    --flash-uboot)    MODE=uboot ;;
    --flash-fastboot) MODE=fastboot ;;
    headless|gui)     FLAVOR=$1 ;;
    -h|--help)        usage 0 ;;
    *)                echo "unknown arg: $1" >&2; usage ;;
  esac
  shift
done
[ -n "$FLAVOR" ] || usage

OS_REPO=${OS_REPO:-nextthingco/x-chip-os}
TOOLS_REPO=${TOOLS_REPO:-nextthingco/x-chip-tools}
UBOOT_REPO=${UBOOT_REPO:-nextthingco/x-chip-uboot}

CACHE="$HERE/.images"
mkdir -p "$CACHE"

# ---- GitHub release helpers -------------------------------------------------
# Prefer gh (honors the user's auth, handles private repos); fall back to the
# anonymous/​token REST API via curl. Both print to stdout / drop files in $dir.

have_gh() { command -v gh >/dev/null 2>&1; }

_curl_auth() {
  local tok="${GITHUB_TOKEN:-}"
  [ -z "$tok" ] && have_gh && tok=$(gh auth token 2>/dev/null || true)
  [ -n "$tok" ] && printf '%s' "-H Authorization: Bearer $tok"
}

# latest_tag REPO  ->  prints the tag of the "latest" release ("" on failure)
latest_tag() {
  local repo=$1
  if have_gh; then
    gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true
  else
    curl -fsSL $(_curl_auth) "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
  fi
}

# download_asset REPO TAG PATTERN DESTDIR  ->  downloads matching asset(s)
download_asset() {
  local repo=$1 tag=$2 pat=$3 dir=$4
  mkdir -p "$dir"
  if have_gh; then
    gh release download "$tag" --repo "$repo" --pattern "$pat" --dir "$dir" --clobber
  else
    # Pull the per-asset download URLs for this tag and fetch the matching ones.
    # browser_download_url works anonymously for public releases; a token (if
    # set) still authorizes it for private repos.
    local url name
    curl -fsSL $(_curl_auth) "https://api.github.com/repos/$repo/releases/tags/$tag" \
      | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
      | while read -r url; do
          name=${url##*/}
          case "$name" in $pat) ;; *) continue ;; esac
          echo ">> downloading $name ($repo $tag)"
          curl -fSL $(_curl_auth) "$url" -o "$dir/$name"
        done
  fi
}

# ---- rootfs (prompted) ------------------------------------------------------

ROOTFS="$CACHE/$FLAVOR-rootfs.tar.gz"
TAGFILE="$CACHE/$FLAVOR.tag"
ASSET="$FLAVOR-rootfs.tar.gz"

local_tag=""; [ -f "$TAGFILE" ] && local_tag=$(cat "$TAGFILE")
remote_tag=$(latest_tag "$OS_REPO")

fetch_rootfs() {  # downloads $ASSET@$remote_tag into place, retaining one image
  local tmp; tmp=$(mktemp -d "$CACHE/.dl.XXXXXX")
  trap 'rm -rf "$tmp"' RETURN
  download_asset "$OS_REPO" "$remote_tag" "$ASSET" "$tmp"
  [ -f "$tmp/$ASSET" ] || { echo "download produced no $ASSET" >&2; return 1; }
  mv -f "$tmp/$ASSET" "$ROOTFS"          # replaces the old image (keep exactly 1)
  printf '%s\n' "$remote_tag" > "$TAGFILE"
}

if [ -z "$remote_tag" ]; then
  echo ">> could not reach GitHub; using local image if present"
  [ -f "$ROOTFS" ] || { echo "no local $FLAVOR image cached, nothing to flash" >&2; exit 1; }
  echo ">> using cached $FLAVOR image (${local_tag:-unknown})"
elif [ "$remote_tag" = "$local_tag" ] && [ -f "$ROOTFS" ]; then
  echo ">> already on latest $FLAVOR image ($local_tag)"
else
  echo ">> latest $FLAVOR image: $remote_tag (local: ${local_tag:-none})"
  read -rp "   download it? [y/N] " ans
  case "$ans" in
    [yY]*) fetch_rootfs ;;
    *)
      if [ -f "$ROOTFS" ]; then
        echo ">> keeping cached $FLAVOR image (${local_tag:-unknown})"
      else
        echo "no local $FLAVOR image and download declined, exiting" >&2
        exit 0
      fi ;;
  esac
fi

# ---- installer initrd (auto; live mode only) --------------------------------
# The direct (--flash-uboot) path writes the rootfs straight from u-boot, so it
# needs no installer initramfs.

INITRD="$CACHE/initrd.uimage"
if [ "$MODE" = live ]; then
  ITAGFILE="$CACHE/installer.tag"
  itag=$(latest_tag "$TOOLS_REPO")
  if [ -n "$itag" ] && { [ ! -f "$INITRD" ] || [ "$itag" != "$(cat "$ITAGFILE" 2>/dev/null || true)" ]; }; then
    download_asset "$TOOLS_REPO" "$itag" "initrd.uimage" "$CACHE"
    printf '%s\n' "$itag" > "$ITAGFILE"
  elif [ ! -f "$INITRD" ]; then
    echo "no installer initrd available (offline and none cached)" >&2; exit 1
  fi
fi

# ---- u-boot blobs (auto) ----------------------------------------------------

UBOOT_DIR="$CACHE/uboot"
UTAGFILE="$CACHE/uboot.tag"
utag=$(latest_tag "$UBOOT_REPO")
if [ -n "$utag" ] && { [ ! -f "$UBOOT_DIR/u-boot-sunxi-with-spl.bin" ] || [ "$utag" != "$(cat "$UTAGFILE" 2>/dev/null || true)" ]; }; then
  download_asset "$UBOOT_REPO" "$utag" "sunxi-spl.bin"             "$UBOOT_DIR"
  download_asset "$UBOOT_REPO" "$utag" "u-boot-dtb.bin"            "$UBOOT_DIR"
  download_asset "$UBOOT_REPO" "$utag" "u-boot-sunxi-with-spl.bin" "$UBOOT_DIR"
  printf '%s\n' "$utag" > "$UTAGFILE"
elif [ ! -f "$UBOOT_DIR/u-boot-sunxi-with-spl.bin" ]; then
  echo "no u-boot blobs available (offline and none cached)" >&2; exit 1
fi

# ---- flash ------------------------------------------------------------------
# Hand the flasher absolute cached paths (both cd to their own dir, so relative
# paths would break) via the env overrides they already honor.

export UBOOT="$UBOOT_DIR/u-boot-sunxi-with-spl.bin"
export SPL="$UBOOT_DIR/sunxi-spl.bin"
export UBOOT_BIN="$UBOOT_DIR/u-boot-dtb.bin"

case "$MODE" in
  uboot)
    echo ">> flashing $FLAVOR image into NAND (direct u-boot UBI write)"
    exec "$HERE/flash-ubi.sh" "$ROOTFS" ;;
  fastboot)
    echo ">> flashing $FLAVOR image into NAND (USB fastboot)"
    exec "$HERE/flash-fastboot.sh" "$ROOTFS" ;;
  *)
    echo ">> flashing $FLAVOR image into NAND (live installer)"
    export INITRD="$INITRD"
    exec "$HERE/flash-live.sh" "$ROOTFS" ;;
esac
