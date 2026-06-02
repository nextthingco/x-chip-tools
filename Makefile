.PHONY: all

# Native amd64 host; debootstrap cross-builds the armhf installer rootfs
# with qemu-user-static. Nothing is compiled, so this stays fast.
all:
	mkdir -p build
	docker build --platform linux/amd64 -t chip-tools-amd64 .
	docker run --rm --platform linux/amd64 -e HOST_UID=$$(id -u) -e HOST_GID=$$(id -g) -e OUT=/out -v $$PWD/build:/out chip-tools-amd64 ./build-initramfs.sh
