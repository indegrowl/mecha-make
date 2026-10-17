#!/bin/bash
# Turn the frogger root partition into the two images the phone is flashed with:
#   userdata.img  sparse ext4 for `fastboot flash userdata`
#   boot.img      Android boot image v2 for `fastboot boot` / `fastboot flash boot_a`
# plus SHA256SUMS. The boot.img header matches the phone's working postmarketOS
# boot image; its ramdisk is /boot/initramfs-frogger.img from the root filesystem.
#
# Usage: frogger/make-images.sh <root.raw> <out-dir>
#   FROGGER_BOOT_DIR  Image.gz + milos-nothing-frogger.dtb (default: frogger/out/boot)
set -euo pipefail

root=${1:?usage: make-images.sh <root.raw> <out-dir>}
out=${2:?usage: make-images.sh <root.raw> <out-dir>}
boot_dir=${FROGGER_BOOT_DIR:-$(dirname "$0")/out/boot}
label=mechanix-root
boot_a_size=100663296 # 96 MiB
cmdline="console=ttyMSM0,115200 console=tty0 clk_ignore_unused pd_ignore_unused mem_sleep_default=s2idle selinux=0 quiet splash root=LABEL=$label rootfstype=ext4 rw rootwait"

actual_label=$(e2label "$root" 2>/dev/null || true)
if [ "$actual_label" != "$label" ]; then
    echo "root label is '$actual_label', expected $label" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
debugfs -R "dump /boot/initramfs-frogger.img $work/initramfs" "$root" >/dev/null 2>&1 || true
if [ ! -s "$work/initramfs" ]; then
    echo "no /boot/initramfs-frogger.img in $root" >&2
    exit 1
fi

mkbootimg \
    --header_version 2 \
    --kernel "$boot_dir/Image.gz" \
    --ramdisk "$work/initramfs" \
    --dtb "$boot_dir/milos-nothing-frogger.dtb" \
    --cmdline "$cmdline" \
    --base 0x0 --pagesize 4096 \
    --kernel_offset 0x8000 --ramdisk_offset 0x01000000 \
    --tags_offset 0x100 --dtb_offset 0x01f00000 \
    --os_version 99.87.36 --os_patch_level 2099-12-31 \
    -o "$work/boot.img"
size=$(stat -c %s "$work/boot.img")
if [ "$size" -ge "$boot_a_size" ]; then
    echo "boot.img is $size bytes: too big for boot_a ($boot_a_size)" >&2
    exit 1
fi

img2simg "$root" "$work/userdata.img"

mkdir -p "$out"
mv "$work/boot.img" "$work/userdata.img" "$out/"
(cd "$out" && sha256sum boot.img userdata.img >SHA256SUMS)
echo "boot.img ($size bytes) and userdata.img in $out"
