#!/bin/bash
# First-flash acceptance checks for the frogger image, run from the host over
# SSH-over-USB. The visual checks (session on screen, touch, keyboard, Wi-Fi from
# mechanix-settings, lockscreen PIN) are done by hand.
#
# Usage: frogger/verify-phone.sh [user@host]   (default mecha@172.16.42.1)
set -uo pipefail

target=${1:-mecha@172.16.42.1}

ssh -o ConnectTimeout=10 "$target" 'bash -s' <<'EOF'
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

check "kernel 7.2.0" '[ "$(uname -r)" = 7.2.0 ]'
check "kernel from the frogger RPM" 'rpm -q kernel | grep -q "^kernel-7.2.0-.*\.frogger\.aarch64$"'
check "root filesystem grown (> 100 GB)" '[ "$(df -B1 --output=size / | tail -1)" -gt 100000000000 ]'
check "root mounted read-write" 'findmnt -no OPTIONS / | grep -q "^rw"'
check "panel connected" '[ "$(cat /sys/class/drm/card0-DSI-1/status)" = connected ]'
# Match the full command line: process names are cut to 15 characters.
for p in mechanix-compositor waybar nwg-drawer mechanix-keyboard; do
    check "$p running" "pgrep -f \"^(/usr/bin/)?$p( |$)\""
done
for fw in adsp.mbn wpss.mbn; do
    check "remoteproc $fw running" "grep -l $fw /sys/class/remoteproc/*/firmware | sed 's/firmware\$/state/' | xargs cat | grep -qx running"
done
check "battery reported" '[ -e /sys/class/power_supply/qcom-battmgr-bat/capacity ]'
check "charging on USB power" 'grep -Eqx "Charging|Full" /sys/class/power_supply/qcom-battmgr-bat/status'
check "Wi-Fi radio enabled" '[ "$(nmcli -t radio wifi)" = enabled ]'
# kernel-headers (userspace API headers) may upgrade; the kernel itself must not.
check "dnf offers no kernel upgrade" '[ -z "$(dnf -q repoquery --upgrades kernel kernel-core "kernel-modules*" 2>/dev/null)" ]'
exit $fail
EOF
