#!/bin/bash
# Checks frogger/stage-firmware.sh with dummy firmware files.
set -uo pipefail
export LC_ALL=C

cd "$(dirname "$0")/../.."
repo=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

names="adsp.mbn adsp_dtb.mbn adspr.jsn adsps.jsn adspua.jsn battmgr.jsn board-2.bin gen80300_gmu.bin gen80300_sqe.fw gen80300_zap.mbn wpss.mbn"
mkdir "$tmp/src"
for n in $names; do echo "$n" >"$tmp/src/$n"; done

expected="usr/lib/firmware/updates/ath11k/WCN6750/hw1.0/board-2.bin
usr/lib/firmware/updates/qcom/gen80300_gmu.bin
usr/lib/firmware/updates/qcom/gen80300_sqe.fw
usr/lib/firmware/updates/qcom/milos/nothing/frogger/adsp.mbn
usr/lib/firmware/updates/qcom/milos/nothing/frogger/adsp_dtb.mbn
usr/lib/firmware/updates/qcom/milos/nothing/frogger/adspr.jsn
usr/lib/firmware/updates/qcom/milos/nothing/frogger/adsps.jsn
usr/lib/firmware/updates/qcom/milos/nothing/frogger/adspua.jsn
usr/lib/firmware/updates/qcom/milos/nothing/frogger/battmgr.jsn
usr/lib/firmware/updates/qcom/milos/nothing/frogger/gen80300_zap.mbn
usr/lib/firmware/updates/qcom/milos/nothing/frogger/wpss.mbn"

echo stale >"$tmp/stale"
mkdir -p "$tmp/dest" && cp "$tmp/stale" "$tmp/dest/old-file"
frogger/stage-firmware.sh "$tmp/src" "$tmp/dest" >/dev/null 2>"$tmp/err"
rc=$?
check "all present: exit 0" '[ $rc -eq 0 ]'
check "exactly the 11 destination paths" '[ "$(cd "$tmp/dest" && find . -type f | sed "s|^\./||" | sort)" = "$expected" ]'
check "contents copied" '[ "$(cat "$tmp/dest/usr/lib/firmware/updates/qcom/milos/nothing/frogger/wpss.mbn")" = wpss.mbn ]'
check "files are 0644" '[ "$(stat -c %a "$tmp/dest/usr/lib/firmware/updates/qcom/gen80300_sqe.fw")" = 644 ]'

rm "$tmp/src/wpss.mbn" "$tmp/src/board-2.bin"
frogger/stage-firmware.sh "$tmp/src" "$tmp/dest2" >/dev/null 2>"$tmp/err"
rc=$?
check "missing file: exit 1" '[ $rc -eq 1 ]'
check "names every missing file" 'grep -qx "missing firmware: wpss.mbn" "$tmp/err" && grep -qx "missing firmware: board-2.bin" "$tmp/err"'
check "missing file: nothing written" '[ ! -e "$tmp/dest2" ]'

check "default destination is gitignored" 'git -C "$repo" check-ignore -q mkosi.local/frogger-firmware'

exit "$fail"
