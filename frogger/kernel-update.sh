#!/bin/bash
# Install the kernel RPM from frogger/build-kernel.sh on a running phone, so its
# modules in /usr/lib/modules/7.2.0 match the boot.img about to be flashed.
# dnf never touches the kernel on the phone (90-frogger-kernel.conf), and every
# build has release 7.2.0, so the package is replaced in place with rpm -U.
#
# Usage: frogger/kernel-update.sh [user@host]   (default mecha@172.16.42.1)
#
# Full kernel update:
#   frogger/build-kernel.sh && ./build.sh --profile=frogger
#   frogger/kernel-update.sh                 # modules on the phone
#   (reboot to the bootloader from Linux)
#   frogger/flash-frogger.sh ramboot         # test the new boot.img
#   frogger/flash-frogger.sh boot_a          # only if it works
set -euo pipefail

KERNEL_UPDATE_CMD="rpm -Uvh --oldpackage --replacefiles"

target=${1:-mecha@172.16.42.1}
cd "$(dirname "$0")/.."
rpms=(frogger/out/rpms/kernel-7.2.0-*.frogger.aarch64.rpm)
if [ "${#rpms[@]}" -ne 1 ] || [ ! -f "${rpms[0]}" ]; then
    echo "expected one kernel RPM in frogger/out/rpms (run frogger/build-kernel.sh)" >&2
    exit 1
fi
rpm=${rpms[0]}

scp "$rpm" "$target:/tmp/"
ssh -t "$target" "sudo $KERNEL_UPDATE_CMD /tmp/$(basename "$rpm") && rm /tmp/$(basename "$rpm") && rpm -q kernel"
