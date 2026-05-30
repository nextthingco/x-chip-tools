.PHONY: all

# Native amd64 host; debootstrap cross-builds the armhf installer rootfs
# with qemu-user-static. Nothing is compiled, so this stays fast.
all:
	docker build --platform linux/amd64 -t chip-tools-amd64 .
	docker run --rm --platform linux/amd64 -e HOST_UID=$$(id -u) -e HOST_GID=$$(id -g) -v $$PWD:/build -w /build chip-tools-amd64 ./build-initramfs.sh
