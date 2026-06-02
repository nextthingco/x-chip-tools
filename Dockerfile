FROM debian:trixie

RUN apt-get update \
  && apt-get -y install \
       debootstrap \
       qemu-user-static \
       ca-certificates \
       cpio \
       gzip \
       u-boot-tools

# the initramfs build assets (build script, init, installer keys) live in
# assets/ and are baked into the container; the build writes to $OUT, which
# the Makefile bind-mounts to the host build/ dir.
COPY assets/ /opt/assets/
WORKDIR /opt/assets
