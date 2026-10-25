#!/bin/bash
# Moonlight streaming checks for the frogger, run from the host over SSH. Needs
# the PC (bastion) running Sunshine with the "Steam Big Picture" app and the
# phone paired with it. The stream runs in a headless gamescope, so the panel
# and the running session are left alone. Prints PASS/FAIL lines; exits non-zero
# on any FAIL.
#
# Usage: frogger/verify-moonlight.sh [--only install|decode|seam] [user@host]
#   PC_HOST  Sunshine host as the phone reaches it (default 192.168.1.9)
set -uo pipefail

only=all
if [ "${1:-}" = --only ]; then only=$2; shift 2; fi
target=${1:-mecha@192.168.1.10}
pc=${PC_HOST:-192.168.1.9}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1${2:+ ($2)}"; fail=1; }
want() { [ "$only" = all ] || [ "$only" = "$1" ]; }
on_phone() { ssh -o ConnectTimeout=10 "$target" "$@"; }

if want install; then
    on_phone 'QT_QPA_PLATFORM=offscreen moonlight --version' 2>/dev/null | grep -q "^Moonlight 6\." &&
        pass "moonlight runs" || bad "moonlight runs"
    conf=$(on_phone 'cat "$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"' 2>/dev/null)
    for kv in width=1920 height=1080 fps=60 videocfg=2 videodec=1; do
        grep -qx "$kv" <<<"$conf" || { bad "defaults are 1080p60 hevc" "$kv missing"; continue 2; }
    done
    pass "defaults are 1080p60 hevc"
fi

if want decode || want seam; then
    # 30 s of the stream in a headless gamescope; Iris interrupts before/after;
    # a gamescope screenshot at 20 s; then quit the app on the PC.
    on_phone "export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        irqs() { awk '/aa00000|iris/ {for (i=2; i<=NF && \$i ~ /^[0-9]+\$/; i++) s+=\$i} END {print s+0}' /proc/interrupts; }
        rm -f /tmp/vm-shot.png
        before=\$(irqs)
        timeout 40 gamescope --backend headless -W 1920 -H 1080 -- moonlight stream $pc 'Steam Big Picture' >/tmp/vm-moonlight.log 2>&1 &
        sleep 20
        GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 gamescopectl screenshot /tmp/vm-shot.png >/dev/null 2>&1
        sleep 10
        echo IRQS \$((\$(irqs) - before))
        pkill -x moonlight; sleep 2; pkill -x gamescope
        QT_QPA_PLATFORM=offscreen moonlight quit $pc >/dev/null 2>&1
        true" >"$work/run.txt" 2>&1
    scp -q "$target:/tmp/vm-moonlight.log" "$work/moonlight.log" 2>/dev/null
    scp -q "$target:/tmp/vm-shot.png" "$work/shot.png" 2>/dev/null
fi

if want decode; then
    grep -q "decoder: hevc_v4l2m2m" "$work/moonlight.log" 2>/dev/null &&
        pass "decodes hevc on iris" || bad "decodes hevc on iris" "no hevc_v4l2m2m in the log"
    irqs=$(sed -n 's/^IRQS //p' "$work/run.txt")
    [ "${irqs:-0}" -gt 1000 ] && pass "iris interrupts rise during the stream" ||
        bad "iris interrupts rise during the stream" "${irqs:-none}"
    ! grep -q -i "h264_v4l2m2m\|Codec: H.264" "$work/moonlight.log" 2>/dev/null &&
        pass "never h264" || bad "never h264"
fi

if want seam; then
    # The last picture rows must look like the rows above them, not like the
    # decoder's zero-chroma padding (green).
    python3 -I - "$work/shot.png" <<'PY' && pass "bottom rows are not green" || bad "bottom rows are not green"
import sys
from PIL import Image
img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size
def row(y):
    px = [img.getpixel((x, y)) for x in range(0, w, 4)]
    return [sum(p[i] for p in px) / len(px) for i in range(3)]
def greenish(c):
    r, g, b = c
    return g > 1.5 * max(r, b, 8)
bottom, above = row(h - 1), row(h - 12)
print("bottom", [round(v) for v in bottom], "above", [round(v) for v in above], file=sys.stderr)
sys.exit(1 if greenish(bottom) and not greenish(above) else 0)
PY
    [ -s "$work/shot.png" ] || bad "screenshot taken"
fi

exit $fail
