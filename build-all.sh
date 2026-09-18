#!/usr/bin/env bash
# build-all.sh -- run the whole pipeline in order. Each step is also usable
# standalone (00 through 06) if you only need to redo one part (e.g. tweak
# 01-configure-kernel.sh and just re-run 01, 04, 05).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$HERE/00-deps-and-fetch.sh"
"$HERE/01-configure-kernel.sh"
"$HERE/02-build-busybox.sh"
"$HERE/03-build-initramfs.sh"
"$HERE/04-build-kernel.sh"
"$HERE/05-install-and-grub.sh"
"$HERE/06-build-php.sh"

echo
echo "=== Termine. Reboote et choisis \"Minimal Kernel (busybox)\" dans GRUB. ==="
