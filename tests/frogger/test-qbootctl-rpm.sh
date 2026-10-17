#!/bin/bash
# Checks the output of frogger/build-qbootctl.sh.
set -uo pipefail

cd "$(dirname "$0")/../.."
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

rpms=(frogger/out/rpms/qbootctl-*.aarch64.rpm)
check "exactly one qbootctl RPM" '[ ${#rpms[@]} -eq 1 ] && [ -f "${rpms[0]}" ]'
rpm=${rpms[0]}
check "built from the pinned commit" \
    '[[ "$(rpm -qp --nosignature --qf "%{NAME} %{VERSION} %{ARCH}" "$rpm" 2>/dev/null)" == "qbootctl 0^20"*"git39a6e6d aarch64" ]]'
check "ships /usr/bin/qbootctl" 'rpm -qlp --nosignature "$rpm" 2>/dev/null | grep -qx /usr/bin/qbootctl'
check "binary is aarch64" \
    'rpm2cpio "$rpm" | cpio -i --quiet --to-stdout ./usr/bin/qbootctl 2>/dev/null | file - | grep -q "ARM aarch64"'
exit "$fail"
