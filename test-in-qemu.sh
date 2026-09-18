#!/usr/bin/env bash
# test-in-qemu.sh -- boot straight into p4's OWN grub.cfg in QEMU, as
# close to the physical machine as possible, WITHOUT needing to fight the
# host's hidden 2s GRUB menu (holding Shift/ESC at the right moment under
# OVMF proved unreliable -- Shift alone often isn't reported by UEFI's
# basic text input protocol, and spamming ESC gets intercepted by OVMF's
# own firmware-setup trigger instead of reaching GRUB).
#
# Instead: build a small, separate FAT boot stub (not on the real disk)
# containing just a copy of the real grubx64.efi plus ONE custom grub.cfg
# that does exactly what "Custom Debian (p4)" does on the real machine --
# find p4 by UUID and load ITS grub.cfg -- skipping the host's own
# grub.cfg (and its hidden-menu problem) entirely. p4's own grub.cfg is
# NOT hidden (5s visible timeout), so once there you just click normally,
# no timing trick needed.
#
# The real physical disk (/dev/nvme0n1) is still passed through, READ-ONLY,
# as a second drive -- the stub only provides the bootstrap; p4's actual
# kernels/initrds are read from the real disk. Read-only is deliberate:
# p1 (/efi) and p4 (/) are live-mounted by the system you're running this
# from, so two kernels writing to the same blocks at once would risk
# corruption; read-only, concurrent reads are safe.
set -euo pipefail

DISK="/dev/nvme0n1"
P4_UUID="50068b6b-6bf5-4ea9-ab58-1e998ad858c0"
OVMF_CODE_SRC="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_SRC="/usr/share/OVMF/OVMF_VARS_4M.fd"
REAL_GRUBX64="/efi/EFI/debian/grubx64.efi"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qemu-ovmf"
OVMF_VARS="$WORKDIR/OVMF_VARS.fd"
STUB_IMG="$WORKDIR/boot-stub.img"
STUB_MNT="$WORKDIR/boot-stub-mnt"

MEM="8G"
SMP="$(nproc)"

mkdir -p "$WORKDIR" "$STUB_MNT"

# Le disque reel est lu en quasi-passthrough (readonly=on) par QEMU : si
# une installation (05-install-and-grub.sh) vient de tourner, ses
# ecritures peuvent encore etre en cache (dirty pages) et pas encore sur
# la puce NVMe physique. On force le flush avant de demarrer QEMU pour ne
# jamais lire un vieux kernel/initramfs par accident.
sync

# ATTENTION, ceci est le VRAI correctif : lire /dev/nvme0n1 en tant que
# peripherique bloc brut passe par un cache DIFFERENT de celui utilise
# quand on lit les memes donnees via le systeme de fichiers monte
# (/boot/...). "sync" ci-dessus ne flush que les pages ECRITES (dirty) --
# il n'invalide PAS une ancienne lecture deja en cache du device brut
# (faite par exemple par un lsblk, blkid, ou une precedente execution de
# QEMU). Sans ca, QEMU peut continuer a voir une VIEILLE version du
# kernel/initramfs meme apres un sync + une reinstallation reussie.
blockdev --flushbufs "$DISK"

# --- Build the small boot stub (idempotent: rebuilt fresh every run) ---
if mount | grep -q "$STUB_MNT"; then
    umount "$STUB_MNT"
fi
rm -f "$STUB_IMG"
dd if=/dev/zero of="$STUB_IMG" bs=1M count=16 status=none
mkfs.vfat "$STUB_IMG" >/dev/null

mount -o loop "$STUB_IMG" "$STUB_MNT"
mkdir -p "$STUB_MNT/EFI/Boot" "$STUB_MNT/EFI/debian"
cp "$REAL_GRUBX64" "$STUB_MNT/EFI/Boot/bootx64.efi"

# grubx64.efi has its config-search prefix ("/EFI/debian") compiled in,
# so this is where it looks for grub.cfg regardless of which file/path it
# was actually launched from.
cat > "$STUB_MNT/EFI/debian/grub.cfg" << EOF
insmod part_gpt
insmod ext2
search --no-floppy --fs-uuid --set=root ${P4_UUID}
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EOF

umount "$STUB_MNT"

# --- Plain/empty OVMF vars: the stub's /EFI/Boot/bootx64.efi is the
# standard UEFI fallback path, no NVRAM entry needed. ---
cp "$OVMF_VARS_SRC" "$OVMF_VARS"

xhost +si:localuser:root >/dev/null 2>&1 || true
trap 'xhost -si:localuser:root >/dev/null 2>&1 || true' EXIT

# DEBUG=1 ./test-in-qemu.sh -- disables KVM (falls back to slower TCG
# software emulation) so -d int actually captures something. Under KVM
# the guest CPU runs directly on hardware and QEMU can't trace most
# interrupts/exceptions, which is why the debug log came out empty.
if [ "${DEBUG:-0}" = "1" ]; then
    ACCEL_ARGS=(-cpu qemu64 -machine q35,accel=tcg)
    SMP=1  # TCG multi-vCPU sync overhead makes SMP dramatically slower
    # No GTK window at all: this kernel has no virtio-gpu driver so that
    # window is always black anyway, and it was very likely stealing
    # keyboard focus away from the terminal (keystrokes going to the
    # emulated PS2/USB keyboard, which nothing in this kernel listens on,
    # instead of the serial console). -nographic forces everything --
    # serial console output AND your keyboard input -- through this one
    # terminal, unambiguously. Ctrl-A X to quit, Ctrl-A C for the monitor.
    DISPLAY_ARGS=(-nographic)
    echo "Mode DEBUG: KVM desactive (TCG, 1 vCPU), pas de fenetre graphique."
    echo "Tout (sortie + clavier) passe par CE terminal. Ctrl-A X pour quitter."
else
    ACCEL_ARGS=(-enable-kvm -cpu host -machine q35,accel=kvm)
    DISPLAY_ARGS=(-vga virtio -display gtk -serial stdio -monitor none)
fi

echo "Demarrage QEMU -- ${SMP} vCPU, ${MEM} RAM"
echo "OVMF -> stub grub -> grub.cfg de p4 directement (menu visible 5s, pas cache)."

qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -smp "$SMP" \
    -m "$MEM" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_SRC" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -drive file="$STUB_IMG",format=raw,if=none,id=stubdisk \
    -device virtio-blk-pci,drive=stubdisk,bootindex=1 \
    -drive file="$DISK",format=raw,if=none,readonly=on,id=realdisk \
    -device virtio-blk-pci,drive=realdisk,bootindex=2 \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    "${DISPLAY_ARGS[@]}" \
    -no-reboot \
    -d int,guest_errors,cpu_reset \
    -D "$WORKDIR/qemu-debug.log" \
    -s
