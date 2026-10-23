#!/bin/bash
# Check the DSPP colour calibration on the phone (msm.dpu_default_ctm=3):
# calibration loaded, last LUTDMA submit OK, IGC/gamut/GC enabled in the DSPP,
# no display errors in dmesg. Exit code = number of failed checks.
#
# Usage: frogger/verify-color.sh [ssh-host]   (default mecha@192.168.1.10)
set -uo pipefail

host=${1:-mecha@192.168.1.10}
out=$(ssh "$host" 'echo mecha | sudo -S -p "" sh -c "cat /sys/kernel/debug/dri/0/debug/dspp_color; echo ---; dmesg"') || {
    echo "FAIL ssh/debugfs"
    exit 1
}
status=${out%%---*}
dmesg=${out#*---}
fails=0

field() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$status" | head -1; }
check() {  # check <name> <ok?>
    if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

echo "$status"
check "mode=3"             "$([ "$(field mode)" = 3 ] && echo 1)"
check "loaded=1"           "$([ "$(field loaded)" = 1 ] && echo 1)"
check "failed=0"           "$([ "$(field failed)" = 0 ] && echo 1)"
check "last_rc=0"          "$([ "$(field last_rc)" = 0 ] && echo 1)"
check "igc_opmode=0x100"   "$([ "$(field igc_opmode)" = 0x100 ] && echo 1)"
check "gamut_opmode=0x1"   "$([ "$(field gamut_opmode)" = 0x1 ] && echo 1)"
check "gc enabled"         "$(( $(field gc_en) & 1 ))"
check "no underruns"       "$(grep -qi underrun <<<"$dmesg" || echo 1)"
check "no lutdma errors"   "$(grep -qiE 'lutdma failed|colour calibration (disabled|.*invalid)' <<<"$dmesg" || echo 1)"
check "no SMMU faults"     "$(grep -qiE 'unhandled context fault|smmu.*fault' <<<"$dmesg" || echo 1)"
exit "$fails"
