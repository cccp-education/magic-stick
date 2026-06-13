FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN chmod 1777 /tmp && apt-get update && apt-get install -y --no-install-recommends \
    live-build \
    debootstrap \
    ubuntu-keyring \
    xorriso \
    squashfs-tools \
    syslinux \
    syslinux-common \
    isolinux \
    grub2-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-amd64-signed \
    shim-signed \
    mtools \
    dosfstools \
    cpio \
    zutils \
    fdisk \
    gdisk \
    parted \
    curl \
    ca-certificates \
    qemu-system-x86 \
    qemu-utils \
    ovmf \
    genisoimage \
    python3 \
    xz-utils \
    file \
    tigervnc-standalone-server \
    tigervnc-viewer \
    novnc \
    websockify \
    x11vnc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /magic-stick

CMD ["bash"]