#!/bin/bash
# Checks frogger/flash-frogger.sh against a fake fastboot.
set -uo pipefail
export LC_ALL=C

cd "$(dirname "$0")/../.."
repo=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# Fake fastboot: logs its argv; `flash`/`boot` fail with ABL's stale-session
# error while $tmp/failures holds a positive count.
mkdir "$tmp/bin"
cat >"$tmp/bin/fastboot" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/log"
case " \$* " in
*" devices "*) echo "00294765M004787	fastboot" ;;
*" flash "*|*" boot "*)
    n=\$(cat "$tmp/failures" 2>/dev/null || echo 0)
    if [ "\$n" -gt 0 ]; then
        echo \$((n - 1)) >"$tmp/failures"
        echo "FAILED (remote: 'Invalid argument size')" >&2
        exit 1
    fi
    echo "Finished. Total time: 1.000s" ;;
esac
EOF
chmod +x "$tmp/bin/fastboot"

mkdir "$tmp/images"
echo boot >"$tmp/images/boot.img"
echo userdata >"$tmp/images/userdata.img"
(cd "$tmp/images" && sha256sum boot.img userdata.img >SHA256SUMS)

flash() { # <failures> <stdin> <args...>
    echo "$1" >"$tmp/failures"
    : >"$tmp/log"
    local input=$2
    shift 2
    printf '%s' "$input" | PATH="$tmp/bin:$PATH" FROGGER_REBOOT_WAIT=0 "$repo/frogger/flash-frogger.sh" "$@" >"$tmp/out" 2>&1
}

flash 0 "" userdata "$tmp/images"; rc=$?
check "userdata: exit 0" '[ $rc -eq 0 ]'
check "userdata: exact fastboot call" '[ "$(cat "$tmp/log")" = "-S 256M flash userdata $tmp/images/userdata.img" ]'

flash 1 "" userdata "$tmp/images"; rc=$?
check "stale ABL: soft reboot, then retry" '[ $rc -eq 0 ] && [ "$(grep -v "^devices" "$tmp/log")" = "-S 256M flash userdata $tmp/images/userdata.img
reboot bootloader
-S 256M flash userdata $tmp/images/userdata.img" ]'

flash 2 "" userdata "$tmp/images"; rc=$?
check "fails twice: exit 1 after one retry" '[ $rc -eq 1 ] && [ "$(grep -c "flash userdata" "$tmp/log")" -eq 2 ]'

flash 0 "" ramboot "$tmp/images"; rc=$?
check "ramboot: fastboot boot boot.img" '[ $rc -eq 0 ] && [ "$(cat "$tmp/log")" = "boot $tmp/images/boot.img" ]'

flash 0 "no
" boot_a "$tmp/images"; rc=$?
check "boot_a without yes: nothing flashed" '[ $rc -eq 1 ] && [ ! -s "$tmp/log" ]'

flash 0 "yes
" boot_a "$tmp/images"; rc=$?
check "boot_a with yes: flashes boot_a" '[ $rc -eq 0 ] && [ "$(cat "$tmp/log")" = "-S 256M flash boot_a $tmp/images/boot.img" ]'

echo corrupted >"$tmp/images/userdata.img"
flash 0 "" userdata "$tmp/images"; rc=$?
check "checksum mismatch: exit 1 before fastboot" '[ $rc -eq 1 ] && [ ! -s "$tmp/log" ]'

flash 0 "" vbmeta_a "$tmp/images"; rc=$?
check "unknown target refused" '[ $rc -ne 0 ] && [ ! -s "$tmp/log" ]'

exit "$fail"
