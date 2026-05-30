FROM debian:trixie

RUN apt-get update \
  && apt-get -y install \
       debootstrap \
       qemu-user-static \
       ca-certificates \
       cpio \
       gzip \
       u-boot-tools
