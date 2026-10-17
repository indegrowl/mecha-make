#!/bin/bash
# Checks the outputs of frogger/build-kernel.sh.
set -uo pipefail

cd "$(dirname "$0")/../.."
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

rpms=(frogger/out/rpms/*.rpm)
check "exactly one RPM in frogger/out/rpms" '[ ${#rpms[@]} -eq 1 ] && [ -f "${rpms[0]}" ]'
rpm=${rpms[0]}
check "RPM is kernel 7.2.0 aarch64" \
    '[ "$(rpm -qp --qf "%{NAME} %{VERSION} %{ARCH}" "$rpm" 2>/dev/null)" = "kernel 7.2.0 aarch64" ]'
check "release is tagged .frogger (Packages=kernel-7.2.0-*.frogger)" \
    '[[ "$(rpm -qp --qf "%{RELEASE}" "$rpm" 2>/dev/null)" == *.frogger ]]'
files=$(rpm -qlp "$rpm" 2>/dev/null)
check "RPM ships the ADSP remoteproc module" \
    'grep -Eq "^(/usr)?/lib/modules/7.2.0/kernel/drivers/remoteproc/qcom_q6v5_pas.ko.zst$" <<<"$files"'
check "RPM ships the ath11k AHB module" \
    'grep -Eq "^(/usr)?/lib/modules/7.2.0/kernel/drivers/net/wireless/ath/ath11k/ath11k_ahb.ko.zst$" <<<"$files"'
check "no kernel-headers RPM" '! ls frogger/out/rpms/kernel-headers-* >/dev/null 2>&1'
check "Image.gz exists" '[ -s frogger/out/boot/Image.gz ]'
check "frogger DTB exists" '[ -s frogger/out/boot/milos-nothing-frogger.dtb ]'

exit "$fail"
