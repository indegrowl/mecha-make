#!/bin/bash
# Flash or RAM-boot the frogger images on a Nothing Phone (4a) in fastboot.
#
# Usage: frogger/flash-frogger.sh userdata|ramboot|boot_a [image-dir]
#   userdata  flash userdata.img (wipes the userdata partition)
#   ramboot   boot boot.img from RAM; boot_a is left as it is
#   boot_a    flash boot.img, only after it RAM-booted and passed acceptance
# image-dir defaults to frogger/out/images and must hold SHA256SUMS.
#
# Enter fastboot from Linux (systemctl reboot --reboot-argument=bootloader), not
# with the buttons. ABL reports no max-download-size, so every flash passes
# -S 256M. "Invalid argument size" means a stale ABL session: the fix is a soft
# reboot into the bootloader and one retry. vbmeta_a, dtbo_a and slot b are
# never touched.
set -euo pipefail

usage() { echo "usage: flash-frogger.sh userdata|ramboot|boot_a [image-dir]" >&2; exit 2; }
target=${1:-}
dir=${2:-$(dirname "$0")/out/images}
case $target in userdata|ramboot|boot_a) ;; *) usage ;; esac

(cd "$dir" && sha256sum -c --quiet SHA256SUMS) || { echo "image checksums don't match $dir/SHA256SUMS" >&2; exit 1; }

# Run one fastboot command; on a stale ABL session reboot into the bootloader
# and retry once.
run() {
    local err
    err=$(mktemp)
    if fastboot "$@" 2> >(tee "$err" >&2); then
        rm -f "$err"
        return 0
    fi
    sleep 0.2 # let the tee above finish writing $err
    if ! grep -q "Invalid argument size" "$err"; then
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    echo "stale bootloader session: rebooting into the bootloader and retrying" >&2
    fastboot reboot bootloader
    sleep "${FROGGER_REBOOT_WAIT:-5}"
    local i
    for i in $(seq 30); do
        [ -n "$(fastboot devices)" ] && break
        sleep 2
    done
    fastboot "$@"
}

case $target in
userdata)
    run -S 256M flash userdata "$dir/userdata.img" ;;
ramboot)
    run boot "$dir/boot.img" ;;
boot_a)
    read -r -p "boot.img RAM-booted and passed acceptance? [yes/no] " answer || answer=
    if [ "$answer" != yes ]; then
        echo "not flashing boot_a" >&2
        exit 1
    fi
    run -S 256M flash boot_a "$dir/boot.img" ;;
esac
