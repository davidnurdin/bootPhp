#!/usr/bin/env bash
# 04-build-kernel.sh -- compile the kernel (bzImage). Initramfs stays a
# separate file, loaded by GRUB's own "initrd" line, same pattern as the
# rest of this system's boot entries.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="7.2.6"
KDIR="$HERE/src/linux-${KVER}"
JOBS="$(nproc)"

cd "$KDIR"
make -j"$JOBS" bzImage

echo
echo "=== kernel construit ==="
ls -lh "$KDIR/arch/x86/boot/bzImage"
