#!/usr/bin/env bash
# 02-build-busybox.sh -- static busybox build (glibc, no shared libs needed).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BB_VERSION="1.37.0"
BDIR="$HERE/src/busybox-${BB_VERSION}"
JOBS="$(nproc)"

cd "$BDIR"
make defconfig </dev/null > /dev/null

# Force fully static linking (glibc static, no .so needed at runtime).
# Busybox's Kconfig has no scripts/config helper -- edit .config directly.
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
# CONFIG_TC (the 'tc' applet) references kernel pkt_sched.h CBQ structs
# that newer kernel headers dropped -- doesn't build, and we don't need
# traffic-control shaping anyway. Disable it.
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
make oldconfig </dev/null > /dev/null
grep -q "^CONFIG_STATIC=y" .config || { echo "CONFIG_STATIC ne s'est pas applique"; exit 1; }

make -j"$JOBS"
rm -rf _install
make install  # installs into ./_install (bin/, sbin/, usr/ + busybox symlinks)

echo
echo "=== busybox statique construit ==="
file "$BDIR/busybox"
ldd "$BDIR/busybox" 2>&1 || echo "(pas de dependances dynamiques -- statique, c'est le but)"
