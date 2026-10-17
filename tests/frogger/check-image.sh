#!/bin/bash
# Offline checks of a built frogger image (no root, no mounts: debugfs only).
# Usage: tests/frogger/check-image.sh <root.raw> <boot.img>
set -uo pipefail
export LC_ALL=C

root=${1:?usage: check-image.sh <root.raw> <boot.img>}
boot=${2:?usage: check-image.sh <root.raw> <boot.img>}
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
dbg() { debugfs -R "$1" "$root" 2>/dev/null; }
exists() { dbg "stat $1" | grep -q "^Inode:"; }
cat_() { dbg "cat $1"; }

check "e2fsck clean" 'e2fsck -fn "$root" >/dev/null 2>&1'
check "label mechanix-root" '[ "$(e2label "$root")" = mechanix-root ]'
check "/init -> usr/lib/systemd/systemd" 'dbg "stat /init" | grep -q "Fast link dest: \"usr/lib/systemd/systemd\""'
check "fstab grows and remounts the root" 'cat_ /etc/fstab | grep -Eq "^LABEL=mechanix-root +/ +ext4 +defaults,x-systemd.growfs"'
check "only the 7.2.0 modules" '[ "$(dbg "ls -p /usr/lib/modules" | awk -F/ "\$6 != \".\" && \$6 != \"..\" && \$6 != \"\" {print \$6}")" = 7.2.0 ]'
check "ADSP remoteproc module" 'exists /usr/lib/modules/7.2.0/kernel/drivers/remoteproc/qcom_q6v5_pas.ko.zst'
check "initramfs in /boot" 'exists /boot/initramfs-frogger.img'
fw=/usr/lib/firmware/updates
for f in qcom/gen80300_sqe.fw qcom/gen80300_gmu.bin ath11k/WCN6750/hw1.0/board-2.bin \
    qcom/milos/nothing/frogger/{adsp.mbn,adsp_dtb.mbn,adspr.jsn,adsps.jsn,adspua.jsn,battmgr.jsn,wpss.mbn,gen80300_zap.mbn}; do
    check "firmware $f" 'exists "$fw/$f"'
done
check "dnf kernel exclude" 'cat_ /etc/dnf/libdnf5.conf.d/90-frogger-kernel.conf | grep -qx "excludepkgs=kernel,kernel-core,kernel-modules\*"'
check "session uses the msm display" 'cat_ /usr/bin/mechanix-session | grep -q "ae01000.display-controller"'
check "compositor installed" 'exists /usr/bin/mechanix-compositor'
check "keyboard installed" 'exists /usr/bin/mechanix-keyboard'
check "greetd autologin into mechanix-session" 'cat_ /etc/greetd/config.toml | grep -q "/usr/bin/mechanix-session"'
check "lockscreen PIN provisioned" 'exists /etc/mechanix/pin.passwd'
check "SSH key installed for mecha" 'exists /home/mecha/.ssh/authorized_keys'
check "hostname frogger" '[ "$(cat_ /etc/hostname)" = frogger ]'
check "VARIANT_ID=frogger" 'cat_ /usr/lib/os-release | grep -qx "VARIANT_ID=\"frogger\""'
check "tqftpserv enabled by preset" 'cat_ /usr/lib/systemd/system-preset/80-mecha-frogger.preset | grep -qx "enable tqftpserv.service"'

cmdline=$(unpack_bootimg --boot_img "$boot" 2>/dev/null | sed -n 's/^command line args: //p')
check "boot.img cmdline" '[ "$cmdline" = "console=ttyMSM0,115200 console=tty0 clk_ignore_unused pd_ignore_unused mem_sleep_default=s2idle selinux=0 quiet splash root=LABEL=mechanix-root rootfstype=ext4 rw rootwait" ]'
check "boot.img fits boot_a" '[ "$(stat -c %s "$boot")" -lt 100663296 ]'

exit "$fail"
