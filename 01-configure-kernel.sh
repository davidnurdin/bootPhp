#!/usr/bin/env bash
# 01-configure-kernel.sh -- minimal .config for this exact hardware:
#   - Dell Inspiron 7786 (Coffee Lake/Whiskey Lake-U)
#   - Storage: NVMe (Samsung 970 EVO) + ext4 + GPT  -> /dev/nvme0n1p4 only
#   - Display: Intel UHD 620 iGPU (i915) for the external HDMI output
#   - Input: USB xHCI + generic/Logitech HID (Unifying receiver + BT)
#   - Bluetooth: btusb + btintel (Intel BE200 combo card, USB-attached)
# No modules -- everything built in (monolithic), no /lib/modules needed.
# Safe to re-run: always starts from allnoconfig and rebuilds .config fresh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="7.2.6"
KDIR="$HERE/src/linux-${KVER}"
JOBS="$(nproc)"

cd "$KDIR"
make allnoconfig

CFG="./scripts/config"

enable() { $CFG --enable "$1"; }

# --- Core / boot essentials ---
enable CONFIG_64BIT
enable CONFIG_SMP
# allnoconfig pousse NR_CPUS a son minimum (2) -- ce Dell a 4 coeurs
# reels (i7-8565U, pas d'HT), donc sans ceci le noyau n'en voit que 2.
$CFG --set-val CONFIG_NR_CPUS 8
enable CONFIG_PCI
enable CONFIG_BLOCK
enable CONFIG_MMU
enable CONFIG_BINFMT_ELF
enable CONFIG_BINFMT_SCRIPT
enable CONFIG_PRINTK
enable CONFIG_UNIX
enable CONFIG_PROC_FS
enable CONFIG_SYSFS
enable CONFIG_TMPFS
enable CONFIG_DEVTMPFS
enable CONFIG_DEVTMPFS_MOUNT

# --- Initramfs ---
enable CONFIG_BLK_DEV_INITRD
enable CONFIG_RD_GZIP

# --- ACPI (needed for real UEFI/Dell hardware to boot cleanly) ---
enable CONFIG_ACPI

# --- EFI (we boot via GRUB in UEFI mode) ---
enable CONFIG_EFI
enable CONFIG_EFI_STUB
enable CONFIG_EFI_PARTITION

# --- Storage: NVMe (real hardware) + ext4 ---
enable CONFIG_BLK_DEV_NVME
enable CONFIG_NVME_CORE
enable CONFIG_EXT4_FS

# --- virtio (QEMU testing only -- purely additive, doesn't affect real
# hardware boot at all). Covers the same physical disk when passed through
# via -device virtio-blk-pci (appears as /dev/vdaX instead of /dev/nvme0n1pX). ---
enable CONFIG_VIRTIO_MENU
enable CONFIG_VIRTIO
enable CONFIG_PCI_MSI
enable CONFIG_VIRTIO_PCI
enable CONFIG_BLK_DEV
enable CONFIG_VIRTIO_BLK
enable CONFIG_VIRTIO_CONSOLE
enable CONFIG_DRM_VIRTIO_GPU

# --- Console / display: Intel iGPU (HDMI), text console on top of it ---
enable CONFIG_VT
enable CONFIG_VT_CONSOLE
enable CONFIG_FRAMEBUFFER_CONSOLE
enable CONFIG_DRM
enable CONFIG_DRM_I915
enable CONFIG_DRM_FBDEV_EMULATION
enable CONFIG_FB

# --- Serial console (ttyS0) -- debugging visibility. Neither the real
# i915 (nothing shows if it fails/panics early) nor QEMU's virtio-gpu
# (this kernel has no virtio-gpu driver at all, so -vga virtio shows
# nothing) can be relied on alone; a serial console works regardless of
# what the display driver is doing. ---
enable CONFIG_SERIAL_8250
enable CONFIG_SERIAL_8250_CONSOLE

# --- USB (xHCI controller + HID input) ---
enable CONFIG_USB_SUPPORT
enable CONFIG_USB
enable CONFIG_USB_XHCI_HCD
enable CONFIG_USB_XHCI_PCI
enable CONFIG_HID_SUPPORT
enable CONFIG_HID
enable CONFIG_HIDRAW
enable CONFIG_HID_GENERIC
enable CONFIG_USB_HID
enable CONFIG_NEW_LEDS
enable CONFIG_LEDS_CLASS
enable CONFIG_LEDS_CLASS_MULTICOLOR
enable CONFIG_HID_LOGITECH
enable CONFIG_HID_LOGITECH_DJ
enable CONFIG_INPUT
enable CONFIG_INPUT_EVDEV

# --- PS/2 keyboard (i8042). QEMU's default graphical window (-display gtk)
# presents an emulated PS/2 keyboard, not USB -- without this driver, the
# on-screen console can't receive keystrokes at all (only the serial
# console works, since that's a plain character stream, unrelated to the
# input subsystem). This also matches real hardware: this Dell's internal
# keyboard is wired through the legacy i8042 controller, same as the
# external USB/BT devices going through HID above. ---
enable CONFIG_SERIO
enable CONFIG_SERIO_I8042
enable CONFIG_INPUT_KEYBOARD
enable CONFIG_KEYBOARD_ATKBD

# --- Bluetooth needs the core net stack (AF_BLUETOOTH sockets), even
# though we don't need/want TCP/IP (net/bluetooth/Kconfig is wrapped in
# an "if NET" block in net/Kconfig) ---
enable CONFIG_NET

# --- Bluetooth: Intel BE200 combo card, USB-attached (btusb + btintel) ---
enable CONFIG_BT
enable CONFIG_BT_BREDR
enable CONFIG_BT_LE
enable CONFIG_BT_HCIBTUSB
enable CONFIG_BT_INTEL
enable CONFIG_BT_HIDP

# --- Firmware loading (i915 + btintel need this to find blobs in /lib/firmware) ---
enable CONFIG_FW_LOADER

# --- No modules: everything above is built directly into the kernel image ---
$CFG --disable CONFIG_MODULES

make olddefconfig

echo
echo "=== .config genere: $KDIR/.config ==="
echo "Verification rapide des options cles :"
for opt in NVME_CORE EXT4_FS DRM_I915 BT_HCIBTUSB BT_INTEL USB_XHCI_HCD HID_LOGITECH_DJ EFI_STUB DEVTMPFS MODULES SERIO_I8042 KEYBOARD_ATKBD; do
    grep -E "^CONFIG_${opt}=" "$KDIR/.config" || echo "CONFIG_${opt} = (absent/non)"
done
