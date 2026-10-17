#!/bin/bash
# Checks the frogger profile's resolved config and its device files.
set -uo pipefail
export LC_ALL=C

cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

podman run --rm --cap-add=SYS_ADMIN -v "$PWD":/build -w /build mecha-build \
    bash -euc 'git config --global --add safe.directory /build; mkosi --profile=frogger summary' \
    2>&1 | sed -n '/^IMAGE: main/,$p' >"$tmp/summary"
s=$tmp/summary
field() { grep -E "^ +$1: " "$s" | head -1 | sed -E "s/^ +$1: //"; }
# all values of a multi-line field
values() { awk -v k="$1" '
    $0 ~ "^ +" k ": " { on=1; sub("^ +" k ": ", ""); print; next }
    on && NF == 0 { next }
    on && /^ +[A-Za-z][^:]*: / { on=0 }
    on { gsub(/^ +/, ""); print }' "$s"; }

check "summary rendered" '[ -s "$s" ]'
check "Architecture arm64" '[ "$(field Architecture)" = arm64 ]'
check "Hostname frogger" '[ "$(field Hostname)" = frogger ]'
check "Bootable disabled" '[ "$(field Bootable)" = disabled ]'
check "extra trees: mecha, frogger, staged firmware" \
    '[ "$(values "Extra Trees" | sed "s|/build/||" | tr "\n" " ")" = "mkosi.extra.mecha mkosi.extra.frogger mkosi.local/frogger-firmware " ]'
check "frogger repart dir" '[ "$(field "Repart Directories")" = /build/mkosi.repart.frogger ]'
check "frogger sandbox tree only" '[ "$(values "Sandbox Trees")" = /build/mkosi.sandbox.frogger ]'
check "local kernel RPM dir" '[ "$(field "Package Directories")" = /build/frogger/out/rpms ]'
check "split root partition" 'values "Split Artifacts" | grep -qx partitions'
pk=$(values Packages)
for p in mechanix-compositor mechanix-keyboard mechanix-lockscreen mechanix-settings impeller tqftpserv qrtr usb-signaller dracut 'kernel-7.2.0-*.frogger'; do
    check "package $p" 'grep -qxF "$p" <<<"$pk"'
done
check "no systemd-boot" '! grep -qx systemd-boot-unsigned <<<"$pk"'
check "no comet kernel" '! grep -q "mecha\." <<<"$pk"'
check "no comet hardware skeleton" '! values "Skeleton Trees" | grep -Eq "skeleton\.(comet|efi|media-unbind)$"'

check "device files have no Comet values" '! grep -rEq "card2|32e60000|imx" mkosi.extra.frogger'
check "session uses the msm display by-path link" \
    'grep -q "^export MECHA_DRM_DEVICE=/dev/dri/by-path/platform-ae01000.display-controller-card$" mkosi.extra.frogger/usr/bin/mechanix-session'
check "session is executable" '[ -x mkosi.extra.frogger/usr/bin/mechanix-session ]'
check "backlight unit uses ae94000.dsi.0" 'grep -q "/sys/class/backlight/ae94000.dsi.0" mkosi.extra.frogger/usr/lib/systemd/system/frogger-backlight.service'
check "preset enables backlight and tqftpserv" \
    '[ "$(grep -v "^#" mkosi.extra.frogger/usr/lib/systemd/system-preset/80-mecha-frogger.preset | sort | tr "\n" " ")" = "enable frogger-backlight.service enable tqftpserv.service " ]'
check "fstab grows the root" 'grep -Eq "^LABEL=mechanix-root +/ +ext4 +defaults,x-systemd.growfs +0 +1$" mkosi.extra.frogger/etc/fstab'
check "dnf never replaces the kernel" \
    'grep -qx "excludepkgs=kernel,kernel-core,kernel-modules\*" mkosi.extra.frogger/etc/dnf/libdnf5.conf.d/90-frogger-kernel.conf'
check "build-time Mecha repo excludes its kernels" \
    'grep -qx "excludepkgs=kernel,kernel-core,kernel-modules\*" mkosi.sandbox.frogger/etc/yum.repos.d/mecha-comet-rpm.repo'
check "build-time Mecha repo keeps priority=1" 'grep -qx "priority=1" mkosi.sandbox.frogger/etc/yum.repos.d/mecha-comet-rpm.repo'
check "build-time Mecha repo differs from comet only by the kernel exclude" \
    '[ "$(grep -vE "^(#|excludepkgs=)" mkosi.sandbox.frogger/etc/yum.repos.d/mecha-comet-rpm.repo)" = "$(grep -vE "^#" mkosi.sandbox/etc/yum.repos.d/mecha-comet-rpm.repo)" ]'
check "root partition label" 'grep -qx "Label=mechanix-root" mkosi.repart.frogger/10-root.conf'
check "postinst links /init to systemd for frogger" 'grep -q "ln -snf usr/lib/systemd/systemd /init" mkosi.postinst.chroot'
check "postinst builds a module-less initramfs" \
    'grep -q "dracut --force --no-hostonly --no-kernel --kernel-cmdline \"root=LABEL=mechanix-root rootfstype=ext4 rw\" --kver 7.2.0 /boot/initramfs-frogger.img" mkosi.postinst.chroot'
check "postinst installs MECHA_SSH_AUTHORIZED_KEY" 'grep -q "MECHA_SSH_AUTHORIZED_KEY" mkosi.postinst.chroot'

exit "$fail"
