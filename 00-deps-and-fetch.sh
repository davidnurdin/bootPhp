#!/usr/bin/env bash
# 00-deps-and-fetch.sh -- install build deps and download kernel + busybox
# sources. Safe to re-run (skips downloads already present).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"

KERNEL_VERSION="7.2.6"
KERNEL_MAJOR="7.x"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}/linux-${KERNEL_VERSION}.tar.xz"

BUSYBOX_VERSION="1.37.0"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y \
    build-essential bc bison flex libssl-dev libelf-dev \
    xz-utils bzip2 cpio rsync wget

mkdir -p "$SRC"
cd "$SRC"

if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
    wget -O "linux-${KERNEL_VERSION}.tar.xz" "$KERNEL_URL"
fi
if [ ! -d "linux-${KERNEL_VERSION}" ]; then
    tar xf "linux-${KERNEL_VERSION}.tar.xz"
fi

if [ ! -f "busybox-${BUSYBOX_VERSION}.tar.bz2" ]; then
    wget -O "busybox-${BUSYBOX_VERSION}.tar.bz2" "$BUSYBOX_URL"
fi
if [ ! -d "busybox-${BUSYBOX_VERSION}" ]; then
    tar xf "busybox-${BUSYBOX_VERSION}.tar.bz2"
fi

echo "OK: sources en place dans $SRC"
echo "  kernel : linux-${KERNEL_VERSION}"
echo "  busybox: busybox-${BUSYBOX_VERSION}"
