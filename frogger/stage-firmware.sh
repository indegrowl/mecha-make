#!/bin/bash
# Stage the Nothing Phone (4a) firmware into a tree the frogger profile adds to
# the image (ExtraTrees). The firmware is proprietary: it comes from a local
# directory, and the default destination is gitignored. Files go under
# /usr/lib/firmware/updates/, which the kernel searches before everything else.
#
# Usage: frogger/stage-firmware.sh [src-dir] [dest-tree]
#   src-dir    default: $FROGGER_FW_DIR or ../pmaports/device/testing/firmware-nothing-frogger
#   dest-tree  default: mkosi.local/frogger-firmware (wiped and recreated)
set -euo pipefail

cd "$(dirname "$0")/.."
src=${1:-${FROGGER_FW_DIR:-../pmaports/device/testing/firmware-nothing-frogger}}
dest=${2:-mkosi.local/frogger-firmware}
fw=usr/lib/firmware/updates

# name -> directory under $fw
declare -A target=(
    [gen80300_sqe.fw]=qcom
    [gen80300_gmu.bin]=qcom
    [gen80300_zap.mbn]=qcom/milos/nothing/frogger
    [adsp.mbn]=qcom/milos/nothing/frogger
    [adsp_dtb.mbn]=qcom/milos/nothing/frogger
    [adspr.jsn]=qcom/milos/nothing/frogger
    [adsps.jsn]=qcom/milos/nothing/frogger
    [adspua.jsn]=qcom/milos/nothing/frogger
    [battmgr.jsn]=qcom/milos/nothing/frogger
    [wpss.mbn]=qcom/milos/nothing/frogger
    [board-2.bin]=ath11k/WCN6750/hw1.0
)

missing=0
for name in $(printf '%s\n' "${!target[@]}" | sort); do
    if [ ! -f "$src/$name" ]; then
        echo "missing firmware: $name" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1

rm -rf "$dest"
for name in "${!target[@]}"; do
    install -Dm644 "$src/$name" "$dest/$fw/${target[$name]}/$name"
done
echo "staged ${#target[@]} firmware files from $src into $dest"
