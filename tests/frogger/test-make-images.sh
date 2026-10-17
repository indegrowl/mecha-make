#!/bin/bash
# Checks frogger/make-images.sh with a small fixture root filesystem.
set -uo pipefail
export LC_ALL=C

cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# No root= here: Nothing's ABL hangs before starting the kernel if the cmdline has root=.
# The root comes from the initramfs (dracut --kernel-cmdline).
cmdline='console=ttyMSM0,115200 console=tty0 clk_ignore_unused pd_ignore_unused mem_sleep_default=s2idle selinux=0 quiet splash'
# Header fields of the phone's working postmarketOS boot.img (c1/boot-pmos-susp2.img).
header="--header_version 2 --os_version 99.87.36 --os_patch_level 2099-12 --pagesize 0x00001000 --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --second_offset 0x00000000 --tags_offset 0x00000100 --dtb_offset 0x0000000001f00000 --board '' --cmdline '$cmdline'"

mkdir -p "$tmp/boot" "$tmp/tree/boot"
head -c 300000 /dev/urandom >"$tmp/boot/Image.gz"
head -c 80000 /dev/urandom >"$tmp/boot/milos-nothing-frogger.dtb"
head -c 2000000 /dev/urandom >"$tmp/tree/boot/initramfs-frogger.img"
mkroot() { # <label> <out> [initramfs size]
    [ -n "${3:-}" ] && head -c "$3" /dev/urandom >"$tmp/tree/boot/initramfs-frogger.img"
    rm -f "$2"
    mkfs.ext4 -q -L "$1" -d "$tmp/tree" "$2" 160M
}
mkroot mechanix-root "$tmp/root.raw"

FROGGER_BOOT_DIR=$tmp/boot frogger/make-images.sh "$tmp/root.raw" "$tmp/out" >"$tmp/log" 2>&1
rc=$?
check "valid input: exit 0" '[ $rc -eq 0 ] || { cat "$tmp/log"; false; }'
unpack_bootimg --boot_img "$tmp/out/boot.img" --out "$tmp/unpacked" --format=mkbootimg >"$tmp/args" 2>/dev/null
args=$(sed -E "s# --(kernel|ramdisk|dtb) [^ ]+##g" "$tmp/args")
check "boot.img header and cmdline" '[ "$args" = "$header" ] || { echo "  got: $args"; false; }'
check "kernel is Image.gz" 'cmp -s "$tmp/unpacked/kernel" "$tmp/boot/Image.gz"'
check "dtb is the frogger DTB" 'cmp -s "$tmp/unpacked/dtb" "$tmp/boot/milos-nothing-frogger.dtb"'
check "ramdisk is the image's initramfs" 'cmp -s "$tmp/unpacked/ramdisk" "$tmp/tree/boot/initramfs-frogger.img"'
simg2img "$tmp/out/userdata.img" "$tmp/userdata.raw" 2>/dev/null
check "userdata.img is the sparse root filesystem" 'cmp -s "$tmp/userdata.raw" "$tmp/root.raw"'
check "SHA256SUMS covers both images" '(cd "$tmp/out" && sha256sum -c --quiet SHA256SUMS) && [ "$(wc -l <"$tmp/out/SHA256SUMS")" -eq 2 ]'

mkroot foo "$tmp/foo.raw"
FROGGER_BOOT_DIR=$tmp/boot frogger/make-images.sh "$tmp/foo.raw" "$tmp/out-foo" >"$tmp/log" 2>&1
rc=$?
check "wrong root label: exit 1" '[ $rc -eq 1 ] && grep -q "root label" "$tmp/log"'

mkroot mechanix-root "$tmp/big.raw" $((97 * 1024 * 1024))
FROGGER_BOOT_DIR=$tmp/boot frogger/make-images.sh "$tmp/big.raw" "$tmp/out-big" >"$tmp/log" 2>&1
rc=$?
check "boot.img over 96 MiB: exit 1" '[ $rc -eq 1 ] && grep -q "too big for boot_a" "$tmp/log"'
check "oversized boot.img not left behind" '[ ! -e "$tmp/out-big/boot.img" ]'

rm "$tmp/tree/boot/initramfs-frogger.img"
mkroot mechanix-root "$tmp/noinit.raw"
FROGGER_BOOT_DIR=$tmp/boot frogger/make-images.sh "$tmp/noinit.raw" "$tmp/out-noinit" >"$tmp/log" 2>&1
rc=$?
check "missing initramfs: exit 1" '[ $rc -eq 1 ] && grep -q "initramfs" "$tmp/log"'

exit "$fail"
