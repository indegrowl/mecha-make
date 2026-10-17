#!/bin/bash
# The comet profile must build from exactly the same config and files as the
# baseline taken before the frogger work. The qemu profile may only lose the
# Comet hardware files that used to leak into it from the shared skeleton.
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

"$here/snapshot-profile.sh" "$tmp/comet" comet
"$here/snapshot-profile.sh" "$tmp/qemu" qemu

for ext in summary tree; do
    if ! diff -u "$here/comet-baseline.$ext" "$tmp/comet.$ext" >"$tmp/comet.$ext.diff"; then
        echo "FAIL: comet .$ext differs from the baseline:"
        cat "$tmp/comet.$ext.diff"
        fail=1
    fi
done

if ! diff -u "$here/qemu-baseline.summary" "$tmp/qemu.summary" >"$tmp/qemu.summary.diff"; then
    echo "FAIL: qemu .summary differs from the baseline:"
    cat "$tmp/qemu.summary.diff"
    fail=1
fi

# Comet hardware files the qemu image is allowed to stop receiving.
allowed='^main	Skeleton Trees	(etc/kernel/devicetree|etc/modules-load\.d/moal\.conf|etc/environment\.d/libcamera\.conf|usr/share/alsa/ucm2/(Mecha/Comet/[^	]+|conf\.d/simple-card/[^	]*Mecha[^	]*))	'
added=$(comm -13 "$here/qemu-baseline.tree" "$tmp/qemu.tree")
removed=$(comm -23 "$here/qemu-baseline.tree" "$tmp/qemu.tree" | grep -Ev "$allowed" || true)
if [ -n "$added$removed" ]; then
    echo "FAIL: qemu .tree changed beyond the Comet hardware files:"
    [ -n "$added" ] && printf '+ %s\n' "$added"
    [ -n "$removed" ] && printf -- '- %s\n' "$removed"
    fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: comet unchanged, qemu only lost Comet hardware files"
exit "$fail"
