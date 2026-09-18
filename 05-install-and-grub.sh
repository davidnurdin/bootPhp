#!/usr/bin/env bash
# 05-install-and-grub.sh -- install the kernel to /boot on the current
# partition (p4), then add/refresh a NEW, additional entry in p4's OWN
# GRUB config (/boot/grub/grub.cfg on p4 itself -- chainloaded from the
# host's GRUB via /EFI/tinydebian/grubx64.efi, not the host's own grub.cfg
# on p5). Default entry (set default=0, tinydebian quiet/mitigations=off)
# is left untouched.
#
# No initramfs/initrd: the kernel boots with root=UUID=<p4> directly and
# init= points straight at the busybox tree built by
# 03-build-initramfs.sh (under $HERE/initramfs/rootfs, itself living on
# p4 since this whole minimalKernel/ directory is on p4).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="7.2.6"
KDIR="$HERE/src/linux-${KVER}"
ROOTFS="$HERE/initramfs/rootfs"
P4_UUID="50068b6b-6bf5-4ea9-ab58-1e998ad858c0"
# GPT partition UUID (distinct from the ext4 filesystem UUID above) --
# root=UUID= needs udev/blkid (i.e. an initramfs) to resolve a FILESYSTEM
# UUID; without one, only root=PARTUUID= works, since the kernel reads
# GPT partition UUIDs natively while parsing the partition table itself.
# Stable across nvme0n1p4 (bare metal) / vda4 / vdb4 (QEMU) naming.
P4_PARTUUID="b4881c62-d24d-4dd8-abed-512ba21da868"

VMLINUZ_DST="/boot/minimal-vmlinuz-${KVER}"
P4_GRUB_CFG="/boot/grub/grub.cfg"

cp "$KDIR/arch/x86/boot/bzImage" "$VMLINUZ_DST"
sync
echo "Installe sur cette partition (p4) :"
ls -lh "$VMLINUZ_DST"

# --- p4's own grub.cfg (this partition, not the host's) ---
cp "$P4_GRUB_CFG" "${P4_GRUB_CFG}.bak-$(date +%Y%m%d%H%M%S)"

# Supprime un ancien bloc "Minimal Kernel" s'il existe (forme initramfs
# ou forme precedente) pour toujours repartir d'une entree fraiche,
# plutot que de sauter l'ajout si un titre identique est deja present.
awk '
    /^menuentry "Minimal Kernel/ { skip=1 }
    skip && /^}/ { skip=0; next }
    !skip { print }
' "$P4_GRUB_CFG" > "${P4_GRUB_CFG}.tmp"
mv "${P4_GRUB_CFG}.tmp" "$P4_GRUB_CFG"

# rootwait est indispensable sans initramfs: la sonde PCIe/NVMe reelle
# (reset controleur, file d'attente admin, ACPI _PS0...) est asynchrone
# et bien plus lente que sous QEMU/virtio -- sans initramfs pour boucler
# en attendant, le noyau resout root= une seule fois, tres tot, et sur le
# vrai NVMe cette resolution arrive souvent AVANT que le namespace/les
# partitions ne soient enumeres. Resultat observe sur ce Dell (mais pas
# en QEMU): "here are the available partitions" (liste des partitions
# nvme) suivi du panic "VFS: Unable to mount root fs" + clignotement
# Verr Maj (panic_blink) -- pas un plantage silencieux, un vrai panic().
# rootwait fait boucler prepare_namespace() jusqu'a ce que le device
# existe au lieu d'abandonner immediatement.
cat >> "$P4_GRUB_CFG" << EOF

menuentry "Minimal Kernel (busybox)" {
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root ${P4_UUID}
	linux (\$root)${VMLINUZ_DST} root=PARTUUID=${P4_PARTUUID} rootwait rootfstype=ext4 ro rootflags=noload init=${ROOTFS}/init console=tty0 console=ttyS0,115200n8 quiet loglevel=0 vt.global_cursor_default=0
}
EOF
echo "Entree (re)ecrite dans $P4_GRUB_CFG."

# Flush obligatoire : sans ca, les blocs modifies restent en cache
# (dirty pages) potentiellement plusieurs secondes/minutes avant d'etre
# ecrits sur la puce NVMe physique. QEMU lit le disque reel en passthrough
# quasi-brut (readonly=on) -- s'il lit avant le flush, il voit encore les
# anciens octets sur le disque alors que nous (via le meme cache page)
# voyons deja les nouveaux. C'est ce qui causait le "ca ne boote pas le
# bon kernel" en QEMU alors que les fichiers etaient corrects.
sync

echo
echo "=== verification: l'entree par defaut (set default=0) n'a pas bouge ==="
grep "^set default" "$P4_GRUB_CFG"
grep -n "^menuentry" "$P4_GRUB_CFG"
