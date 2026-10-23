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

# source file (in src-dir) -> path under $fw. A source ending in / is a
# directory, copied whole.
files="
gen80300_sqe.fw                 qcom/gen80300_sqe.fw
gen80300_gmu.bin                qcom/gen80300_gmu.bin
gen80300_zap.mbn                qcom/milos/nothing/frogger/gen80300_zap.mbn
adsp.mbn                        qcom/milos/nothing/frogger/adsp.mbn
adsp_dtb.mbn                    qcom/milos/nothing/frogger/adsp_dtb.mbn
adspr.jsn                       qcom/milos/nothing/frogger/adspr.jsn
adsps.jsn                       qcom/milos/nothing/frogger/adsps.jsn
adspua.jsn                      qcom/milos/nothing/frogger/adspua.jsn
battmgr.jsn                     qcom/milos/nothing/frogger/battmgr.jsn
wpss.mbn                        qcom/milos/nothing/frogger/wpss.mbn
vpu20_2v.mbn                    qcom/milos/nothing/frogger/vpu20_2v.mbn
board-2.bin                     ath11k/WCN6750/hw1.0/board-2.bin
aw882xx_acf.bin                 qcom/milos/nothing/frogger/aw882xx_acf.bin
MILOS-Nothing-Phone-4a-tplg.bin qcom/milos/Nothing Phone (4a)-tplg.bin
modem.mbn                       qcom/milos/nothing/frogger/modem.mbn
modemr.jsn                      qcom/milos/nothing/frogger/modemr.jsn
modem_pr/                       qcom/milos/nothing/frogger/modem_pr
ipa_fws.mbn                     qcom/milos/nothing/frogger/ipa_fws.mbn
"
# Sources besides the pmaports firmware package's own (see its .gitignore):
#   aw882xx_acf.bin                  Awinic tuning, vendor partition (research_notes/audio-recon-2026-10-18)
#   MILOS-Nothing-Phone-4a-tplg.bin  AudioReach topology, ref-audio/audioreach-topology-fp6 frogger build;
#                                    the kernel asks for qcom/<driver>/<card name>-tplg.bin
#   modem.mbn, modemr.jsn, modem_pr/, ipa_fws.mbn   ../fw-260402/out/lib/firmware/qcom/milos/nothing/frogger
#   nothing-frogger-dspp.bin is generated below (frogger/color/make-dspp-calib.py)

missing=0 count=0
while read -r name path; do
    [ -n "$name" ] || continue
    if [ ! -e "$src/$name" ]; then
        echo "missing firmware: $name" >&2
        missing=1
    fi
done <<<"$files"
[ "$missing" -eq 0 ] || exit 1

rm -rf "$dest"
while read -r name path; do
    [ -n "$name" ] || continue
    if [ "${name%/}" != "$name" ]; then
        mkdir -p "$dest/$fw/$path"
        # Only the firmware, not the directory's own .gitignore
        (cd "$src/$name" && find . -type f ! -name .gitignore -print0) |
            while IFS= read -r -d '' f; do
                install -Dm644 "$src/$name/$f" "$dest/$fw/$path/$f"
            done
    else
        install -Dm644 "$src/$name" "$dest/$fw/$path"
    fi
    count=$((count + 1))
done <<<"$files"
# DSPP colour calibration, generated from the stock QDCM tables (local, like the rest).
# Table 3 is Android's "Standard" (sRGB, D65); table 0 is its vivid "Alive" default.
qdcm=${FROGGER_QDCM_DIR:-$HOME/projects/nothing-4a-linux/research_notes/dspp-color-2026-10-23/qdcm/qdcm_out}
python3 frogger/color/make-dspp-calib.py --pattern qdcm --qdcm-dir "$qdcm" --table 3 \
    -o "$dest/$fw/qcom/milos/nothing-frogger-dspp.bin"
count=$((count + 1))
echo "staged $count firmware entries from $src into $dest"
