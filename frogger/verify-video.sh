#!/bin/bash
# Hardware video decode checks for the frogger (Iris VPU), run from the host
# over SSH. Pushes the test clips made by c1/video/make-clips.sh, then runs the
# checks on the phone. Prints PASS/FAIL lines; exits non-zero on any FAIL.
#
# Usage: frogger/verify-video.sh [--only kernel|ffmpeg|mpv|gst] [user@host]
#   CLIPS  clip directory (default: ../c1/video/clips next to mecha-make)
set -uo pipefail

only=all
if [ "${1:-}" = --only ]; then only=$2; shift 2; fi
target=${1:-mecha@172.16.42.1}
clips=${CLIPS:-$(dirname "$0")/../../c1/video/clips}
[ -d "$clips" ] || { echo "no clips in $clips (run c1/video/make-clips.sh)" >&2; exit 2; }

rsync -a --mkpath "$clips/" "$target:video-test/" || exit 2

ssh -o ConnectTimeout=10 "$target" "ONLY=$only bash -s" <<'EOF'
cd ~/video-test || exit 2
fail=0
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1${2:+ ($2)}"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else bad "$1"; fi; }
want() { [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }
# Iris interrupt count (all CPUs) from /proc/interrupts.
irqs() { awk '/aa00000|iris/ {for (i=2; i<=NF && $i ~ /^[0-9]+$/; i++) s+=$i} END {print s+0}' /proc/interrupts; }
sudo_() { echo mecha | sudo -S -p "" "$@"; }

# Device nodes by V4L2 card type.
dev_for() { for d in /dev/video*; do v4l2-ctl -d "$d" -D 2>/dev/null | grep -q "Card type *: *$1" && { echo "$d"; return; }; done; }

# Extract the visible NV12 area of frame <n> from a raw capture with the given
# bytesperline/height layout and print its md5.
nv12_md5() { # file n width height bpl buf_height sizeimage
	python3 -I - "$@" <<'PY'
import sys, hashlib
f, n, w, h, bpl, bh, size = sys.argv[1], *map(int, sys.argv[2:])
with open(f, 'rb') as fp:
    fp.seek(n * size); buf = fp.read(size)
y = b''.join(buf[r*bpl:r*bpl+w] for r in range(h))
uv0 = bpl * bh
uv = b''.join(buf[uv0+r*bpl:uv0+r*bpl+w] for r in range(h // 2))
print(hashlib.md5(y + uv).hexdigest())
PY
}
ref_md5() { python3 -I -c 'import sys,hashlib;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# Stateful decode of an elementary stream with v4l2-ctl; sets FRAMES and MD5.
# The format can't be read back after the stream stops (the next open gets the
# 384x256 default), so use Iris' NV12 layout: lines padded to 128 bytes, the Y
# plane to 32 lines, the UV plane to 16 lines.
v4l2_decode() { # dev es fourcc width height frame
	local dev=$1 es=$2 cc=$3 w=$4 h=$5 n=$6 out=/tmp/vv-out.nv12
	local bpl=$(( (w + 127) / 128 * 128 )) bh=$(( (h + 31) / 32 * 32 ))
	local size=$(( bpl * bh + bpl * ((h / 2 + 15) / 16 * 16) ))
	rm -f $out
	timeout 120 v4l2-ctl -d "$dev" --set-fmt-video-out=pixelformat=$cc --set-fmt-video=pixelformat=NV12 \
		--stream-mmap --stream-out-mmap --stream-from="$es" --stream-to=$out >/tmp/vv-dec.log 2>&1
	FRAMES=$(( $(stat -c %s $out 2>/dev/null || echo 0) / size ))
	MD5=$(nv12_md5 $out "$n" "$w" "$h" "$bpl" "$bh" "$size" 2>/dev/null)
}

if want kernel; then
	check "qcom-iris module loaded" 'lsmod | grep -q "^qcom_iris "'
	dmesg_=$(sudo_ dmesg)
	check "no iris errors in dmesg" '! grep -iE "iris|aa00000.video-codec" <<<"$dmesg_" | grep -iqE "error|fail|timeout|watchdog"'
	check "VPU firmware vpu20_2v.mbn present" '[ -e /usr/lib/firmware/updates/qcom/milos/nothing/frogger/vpu20_2v.mbn ]'
	dec=$(dev_for "Iris Decoder"); enc=$(dev_for "Iris Encoder")
	check "decoder node ($dec)" '[ -n "$dec" ]'
	check "encoder node ($enc)" '[ -n "$enc" ]'
	if [ -n "$dec" ]; then
		outfmts=$(v4l2-ctl -d "$dec" --list-formats-out 2>/dev/null)
		for cc in H264 HEVC VP90; do check "decoder accepts $cc" "grep -q \"'$cc'\" <<<\"\$outfmts\""; done

		# v4l2-ctl's own H.264 splitter drops/garbles a few 1080p access units, so
		# here 1080p only proves the decoder runs; bit-exactness at 1080p is checked
		# with real parsers in the ffmpeg and gst groups.
		i0=$(irqs)
		v4l2_decode "$dec" es/h264-1080p30.h264 H264 1920 1080 0
		i1=$(irqs)
		check "h264 1080p: decoder ran (got $FRAMES frames)" '[ "$FRAMES" -ge 850 ]'
		check "h264 1080p: iris interrupts rose ($i0 -> $i1)" '[ "$i1" -gt "$i0" ]'

		v4l2_decode "$dec" es/h264-1280x536.h264 H264 1280 536 150
		check "h264 1280x536: 300 frames decoded (got $FRAMES)" '[ "$FRAMES" -eq 300 ]'
		check "h264 1280x536: frame 150 matches software decode (crop)" '[ "$MD5" = "$(ref_md5 es/h264-1280x536.f150.nv12)" ]'


		sleep 60   # let Iris runtime-suspend, then decode again
		v4l2_decode "$dec" es/h264-1280x536.h264 H264 1280 536 150
		check "h264 after 60 s idle: 300 frames, frame 150 exact" '[ "$FRAMES" -eq 300 ] && [ "$MD5" = "$(ref_md5 es/h264-1280x536.f150.nv12)" ]'
		check "no new iris errors after the decodes" '! sudo_ dmesg | grep -iE "iris|aa00000.video-codec" | grep -iqE "error|fail|timeout|watchdog"'
	fi
fi

exit $fail
EOF
