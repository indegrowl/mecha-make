#!/bin/bash
# Checks `./build.sh --profile=frogger --preflight-only` in a scratch copy of the
# build scripts: it must name every missing input and never start a build.
set -uo pipefail
export LC_ALL=C

cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$tmp/repo/frogger" "$tmp/fw"
cp build.sh "$tmp/repo/"
cp frogger/*.sh "$tmp/repo/frogger/"
for n in adsp.mbn adsp_dtb.mbn adspr.jsn adsps.jsn adspua.jsn battmgr.jsn board-2.bin gen80300_gmu.bin gen80300_sqe.fw gen80300_zap.mbn wpss.mbn; do
    echo "$n" >"$tmp/fw/$n"
done
run() { (cd "$tmp/repo" && FROGGER_FW_DIR=$tmp/fw ./build.sh --profile=frogger --preflight-only) >"$tmp/out" 2>&1; }

run; rc=$?
check "no mkosi.env: exit 1" '[ $rc -eq 1 ]'
check "names the missing password" 'grep -qx "mkosi.env: MECHA_USER_PASSWORD not set" "$tmp/out"'
check "names the missing PIN" 'grep -qx "mkosi.env: MECHANIX_LOCKSCREEN_PIN not set" "$tmp/out"'
check "names the missing qbootctl RPM" 'grep -qx "no qbootctl RPM in frogger/out/rpms (run frogger/build-qbootctl.sh)" "$tmp/out"'
check "names the missing kernel RPM" 'grep -qx "no kernel RPM in frogger/out/rpms (run frogger/build-kernel.sh)" "$tmp/out"'

printf 'MECHA_USER_PASSWORD=secret\nMECHANIX_LOCKSCREEN_PIN=\n' >"$tmp/repo/mkosi.env"
run; rc=$?
check "empty PIN still counts as not set" '[ $rc -eq 1 ] && grep -qx "mkosi.env: MECHANIX_LOCKSCREEN_PIN not set" "$tmp/out"'
check "password present: not reported" '! grep -q MECHA_USER_PASSWORD "$tmp/out"'

printf 'MECHA_USER_PASSWORD=secret\nMECHANIX_LOCKSCREEN_PIN=1234\n' >"$tmp/repo/mkosi.env"
mkdir -p "$tmp/repo/frogger/out/rpms" "$tmp/repo/frogger/out/boot"
touch "$tmp/repo/frogger/out/rpms/kernel-7.2.0-1.frogger.aarch64.rpm" \
    "$tmp/repo/frogger/out/rpms/qbootctl-0^20250101git39a6e6d-1.fc44.aarch64.rpm" \
    "$tmp/repo/frogger/out/boot/Image.gz" "$tmp/repo/frogger/out/boot/milos-nothing-frogger.dtb"
rm "$tmp/fw/wpss.mbn"
run; rc=$?
check "missing firmware: exit 1" '[ $rc -eq 1 ] && grep -qx "missing firmware: wpss.mbn" "$tmp/out"'

echo wpss.mbn >"$tmp/fw/wpss.mbn"
# A host without mkbootimg: every other host tool stays on PATH.
mkdir "$tmp/bin"
for f in /usr/bin/*; do [ "$(basename "$f")" = mkbootimg ] || ln -s "$f" "$tmp/bin/"; done
(cd "$tmp/repo" && PATH=$tmp/bin FROGGER_FW_DIR=$tmp/fw ./build.sh --profile=frogger --preflight-only) >"$tmp/out" 2>&1; rc=$?
check "missing host tool: exit 1" '[ $rc -eq 1 ] && grep -qx "missing host tool: mkbootimg" "$tmp/out"'

run; rc=$?
check "all inputs present: exit 0" '[ $rc -eq 0 ] || { cat "$tmp/out"; false; }'
check "preflight never builds" '! grep -q "Building profile" "$tmp/out"'

exit "$fail"
