#!/bin/bash
# The documented on-phone kernel update (README "Kernel updates") must replace
# the installed frogger kernel package in place: same name, same 7.2.0 module
# paths, new release. Checked in a scratch rpm root with two builds of the RPM.
#   usage: tests/frogger/test-kernel-update.sh <old.rpm> <new.rpm>
set -uo pipefail
export LC_ALL=C

cd "$(dirname "$0")/../.."
old=${1:?usage: test-kernel-update.sh <old.rpm> <new.rpm>}
new=${2:?usage: test-kernel-update.sh <old.rpm> <new.rpm>}
# rpm --root needs chroot, so run as (namespaced) root in the build container.
if [ "$(id -u)" -ne 0 ]; then
    old=$(realpath "$old") new=$(realpath "$new")
    exec podman run --rm --cap-add=SYS_ADMIN -v "$PWD":/build:ro -w /build \
        -v "$old":/rpms/old.rpm:ro -v "$new":/rpms/new.rpm:ro \
        mecha-build tests/frogger/test-kernel-update.sh /rpms/old.rpm /rpms/new.rpm
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

cmd=$(sed -n 's/^ *KERNEL_UPDATE_CMD="\(.*\)"$/\1/p' frogger/kernel-update.sh)
check "update command is defined" '[ -n "$cmd" ]'
# The scratch root is x86_64 and empty, so arch, deps and scriptlets are skipped.
rpm=(rpm --root "$tmp/root" --dbpath /var/lib/rpm)
foreign=(--ignorearch --nodeps --noscripts --nosignature)
mkdir -p "$tmp/root"
"${rpm[@]}" --initdb
"${rpm[@]}" -i "${foreign[@]}" "$old" >/dev/null 2>&1
check "old kernel installed" '[ "$("${rpm[@]}" -q kernel)" = "$(rpm -qp --nosignature "$old" 2>/dev/null)" ]'
# shellcheck disable=SC2086 # the documented command, word-split as a user would type it
"${rpm[@]}" ${cmd#rpm } "${foreign[@]}" "$new" >"$tmp/log" 2>&1
check "update command succeeds" '[ $? -eq 0 ] || { cat "$tmp/log"; false; }'
check "only the new kernel is installed" '[ "$("${rpm[@]}" -q kernel)" = "$(rpm -qp --nosignature "$new" 2>/dev/null)" ]'
check "7.2.0 modules still present" '[ -n "$(find "$tmp/root" -path "*/lib/modules/7.2.0/kernel/drivers/remoteproc/qcom_q6v5_pas.ko.zst")" ]'
exit "$fail"
