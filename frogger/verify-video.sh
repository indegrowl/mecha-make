#!/bin/bash
# Hardware video decode checks for the frogger (Iris VPU), run from the host
# over SSH. Pushes the test clips made by c1/video/make-clips.sh, then runs the
# checks on the phone. Prints PASS/FAIL lines; exits non-zero on any FAIL.
#
# Usage: frogger/verify-video.sh [--only kernel|ffmpeg|mpv|gst|seq] [user@host]
#   seq: decoder client sequences (seek, drain, restart, resolution change,
#        sessions) with frogger/iris-seq (build it with frogger/iris-seq/build.sh)
#   CLIPS  clip directory (default: ../c1/video/clips next to mecha-make)
set -uo pipefail

only=all
if [ "${1:-}" = --only ]; then only=$2; shift 2; fi
target=${1:-mecha@172.16.42.1}
clips=${CLIPS:-$(dirname "$0")/../../c1/video/clips}
[ -d "$clips" ] || { echo "no clips in $clips (run c1/video/make-clips.sh)" >&2; exit 2; }

rsync -a --mkpath "$clips/" "$target:video-test/" || exit 2
if [ "$only" = all ] || [ "$only" = seq ]; then
	tool=$(dirname "$0")/out/iris-seq
	[ -x "$tool" ] || { echo "no $tool (run frogger/iris-seq/build.sh)" >&2; exit 2; }
	rsync -a "$tool" "$(dirname "$0")/iris-seq/gaps.sh" "$target:video-test/" || exit 2
fi

# Run from a file with stdin on /dev/null: as `bash -s` the decoders under test
# would read the rest of the script from stdin.
ssh -o ConnectTimeout=10 "$target" 'cat > video-test/.verify-video.sh' <<'EOF' || exit 2
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
	timeout -k 5 120 v4l2-ctl -d "$dev" --set-fmt-video-out=pixelformat=$cc --set-fmt-video=pixelformat=NV12 \
		--stream-mmap --stream-out-mmap --stream-from="$es" --stream-to=$out >/tmp/vv-dec.log 2>&1
	FRAMES=$(( $(stat -c %s $out 2>/dev/null || echo 0) / size ))
	MD5=$(nv12_md5 $out "$n" "$w" "$h" "$bpl" "$bh" "$size" 2>/dev/null)
}

if want kernel; then
	check "qcom-iris module loaded" 'lsmod | grep -q "^qcom_iris "'
	dmesg_=$(sudo_ dmesg)
	check "no iris errors in dmesg" '! grep -iE "iris|aa00000.video-codec" <<<"$dmesg_" | grep -iqE "error|fail|timeout|watchdog|holds|not queued|restarted before"'
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
		check "no new iris errors after the decodes" '! sudo_ dmesg | grep -iE "iris|aa00000.video-codec" | grep -iqE "error|fail|timeout|watchdog|holds|not queued|restarted before"'
	fi
fi

# Hash every decoded frame of $1 (w x h, packed) against the host reference list.
cmp_frames() { # md5list w h  (stdin: raw frames) -> prints "<frames> <exact>"
	python3 -I -c '
import hashlib, sys
ref = [l.strip() for l in open(sys.argv[1])]; w, h = map(int, sys.argv[2:4]); s = w * h * 3 // 2
got = []; r = sys.stdin.buffer
while (b := r.read(s)) and len(b) == s: got.append(hashlib.md5(b).hexdigest())
print(len(got), sum(a == b for a, b in zip(got, ref)))' "$@"
}

if want ffmpeg; then
	dec=$(ffmpeg -hide_banner -decoders 2>/dev/null)
	for c in h264 hevc vp9; do check "ffmpeg has ${c}_v4l2m2m" "grep -q ' ${c}_v4l2m2m ' <<<\"\$dec\""; done
	for t in h264:h264-1080p30.mp4 hevc:hevc-1080p30.mp4 vp9:vp9-1080p30.webm; do
		c=${t%%:*} f=${t#*:} n=${f%.*}
		i0=$(irqs)
		read -r frames exact < <(timeout -k 5 120 ffmpeg -hide_banner -loglevel error -c:v ${c}_v4l2m2m -i "$f" -pix_fmt nv12 -f rawvideo - 2>/dev/null | cmp_frames es/$n.md5 1920 1080)
		i1=$(irqs)
		check "ffmpeg $c 1080p: 900/900 frames bit-exact (got $frames/$exact)" '[ "$frames" = 900 ] && [ "$exact" = 900 ]'
		check "ffmpeg $c 1080p: iris interrupts rose ($i0 -> $i1)" '[ "$i1" -gt "$i0" ]'
		def=$(ffmpeg -hide_banner -v verbose -i "$f" -frames:v 1 -f null - 2>&1 | grep -o "Stream #0:0 -> #0:0 ($c ([a-z0-9_]*)" | grep -o '([a-z0-9_]*)$' | tr -d '()')
		if [ "$c" != vp9 ]; then
			# ffmpeg-free has no software H.264/HEVC decoder (only the noopenh264 stub).
			check "ffmpeg $c 1080p: default decoder is ${c}_v4l2m2m (got ${def:-?})" '[ "$def" = ${c}_v4l2m2m ]'
			continue
		fi
		hw=$( { /usr/bin/time -f %U ffmpeg -hide_banner -loglevel error -c:v ${c}_v4l2m2m -i "$f" -f null - >/dev/null; } 2>&1 | tail -1)
		sw=$( { /usr/bin/time -f %U ffmpeg -hide_banner -loglevel error -i "$f" -f null - >/dev/null; } 2>&1 | tail -1)
		echo "INFO ffmpeg $c 1080p CPU user: hardware ${hw}s, default decoder ($def) ${sw}s"
		check "ffmpeg $c 1080p: hardware CPU < half of default decoder" "python3 -c 'import sys; sys.exit(0 if $hw < $sw / 2 else 1)'"
	done
	# As a player sees them (no frame-rate conversion): the VP9 hidden frames
	# the driver returns empty and flagged ERROR must not come out as frames.
	read -r frames exact < <(timeout -k 5 120 ffmpeg -hide_banner -loglevel error -c:v vp9_v4l2m2m -i vp9-1080p30.webm -fps_mode passthrough -pix_fmt nv12 -f rawvideo - 2>/dev/null | cmp_frames es/vp9-1080p30.md5 1920 1080)
	check "ffmpeg vp9 1080p without frame-rate conversion: 900/900 frames bit-exact (got $frames/$exact)" '[ "$frames" = 900 ] && [ "$exact" = 900 ]'
	read -r frames exact < <(timeout -k 5 120 ffmpeg -hide_banner -loglevel error -c:v h264_v4l2m2m -i h264-1280x536.mp4 -pix_fmt nv12 -f rawvideo - 2>/dev/null | cmp_frames es/h264-1280x536.md5 1280 536)
	check "ffmpeg h264 1280x536: 300/300 bit-exact (got $frames/$exact)" '[ "$frames" = 300 ] && [ "$exact" = 300 ]'
	# Seek back to the start after a drain (looping): three passes, all exact.
	read -r frames exact < <(timeout -k 5 120 ffmpeg -hide_banner -loglevel error -stream_loop 2 -c:v h264_v4l2m2m -i h264-1280x536.mp4 -pix_fmt nv12 -f rawvideo - 2>/dev/null | cmp_frames <(cat es/h264-1280x536.md5 es/h264-1280x536.md5 es/h264-1280x536.md5) 1280 536)
	check "ffmpeg h264 looped 3x (seek after drain): 900/900 bit-exact (got $frames/$exact)" '[ "$frames" = 900 ] && [ "$exact" = 900 ]'
	# Per-frame NV12 size and CRC against the software decode (150 x 720p, 150 x 1080p).
	read -r n ok < <(timeout -k 5 120 ffmpeg -hide_banner -loglevel error -c:v h264_v4l2m2m -i h264-reschange.ts -fps_mode passthrough -noautoscale -pix_fmt nv12 -f framecrc - 2>/dev/null | awk -F', *' '/^0,/{print $5, $6}' | paste -d' ' - es/h264-reschange.crc | awk 'NF == 4 {n++; if ($1 == $3 && $2 == $4) ok++} END {print n+0, ok+0}')
	check "ffmpeg h264 720p->1080p resolution change: 300/300 frames exact (got $n/$ok)" '[ "$n" = 300 ] && [ "$ok" = 300 ]'
	for t in av1_unsupported:av1-1080p30.mkv:hevc hevc10:hevc10-1080p30.mp4:hevc; do
		f=$(cut -d: -f2 <<<"$t") c=$(cut -d: -f3 <<<"$t")
		timeout -k 5 60 ffmpeg -hide_banner -loglevel error -c:v ${c}_v4l2m2m -i "$f" -frames:v 30 -f null - >/dev/null 2>&1; rc=$?
		check "ffmpeg ${t%%:*} clip on the hardware decoder ends within 60 s (rc $rc)" '[ "$rc" -ne 124 ] && [ "$rc" -ne 137 ]'
	done
	check "no iris errors after the ffmpeg runs" '! sudo_ dmesg | grep -iE "iris|aa00000.video-codec" | grep -iqE "error|fail|timeout|watchdog|holds|not queued|restarted before"'
fi

# Fedora's GStreamer in /usr, not Mecha's /opt/gstreamer (its profile.d script
# puts /opt first in PATH and GST_PLUGIN_PATH), inside the user's Wayland session.
# (arrays, not functions: timeout can only run commands)
fgst=(env -u GST_PLUGIN_PATH -u GST_PLUGIN_PATH_1_0 -u LD_LIBRARY_PATH XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1})

if want gst; then
	check "Fedora gst-launch-1.0 in /usr/bin" '[ -x /usr/bin/gst-launch-1.0 ] && rpm -qf /usr/bin/gst-launch-1.0 | grep -q ^gstreamer1-'
	for e in v4l2h264dec v4l2h265dec v4l2vp9dec; do check "Fedora GStreamer has $e" '"${fgst[@]}" /usr/bin/gst-inspect-1.0 '"$e"; done
	for t in h264:h264-1080p30.mp4:qtdemux:h264parse hevc:hevc-1080p30.mp4:qtdemux:h265parse vp9:vp9-1080p30.webm:matroskademux:vp9parse; do
		IFS=: read -r c f demux parse <<<"$t"; n=${f%.*}; e=v4l2${c/hevc/h265}dec
		i0=$(irqs)
		read -r frames exact < <(timeout -k 5 120 "${fgst[@]}" /usr/bin/gst-launch-1.0 -q filesrc location=$f ! $demux ! $parse ! $e ! videoconvert ! video/x-raw,format=I420 ! fdsink fd=1 2>/dev/null | cmp_frames es/$n.i420.md5 1920 1080)
		i1=$(irqs)
		check "gst $c 1080p: 900/900 frames bit-exact (got $frames/$exact)" '[ "$frames" = 900 ] && [ "$exact" = 900 ]'
		check "gst $c 1080p: iris interrupts rose ($i0 -> $i1)" '[ "$i1" -gt "$i0" ]'
		out=$(timeout -k 5 60 "${fgst[@]}" /usr/bin/gst-launch-1.0 -v filesrc location=$f ! $demux ! $parse ! $e ! videoconvert ! fpsdisplaysink video-sink=waylandsink text-overlay=false sync=true 2>&1)
		drop=$(grep -o 'dropped: [0-9]*' <<<"$out" | tail -1 | grep -o '[0-9]*')
		check "gst $c 1080p on screen: reached EOS, 0 dropped (dropped=${drop:-?})" 'grep -q "Got EOS" <<<"$out" && [ "${drop:-1}" -eq 0 ]'
	done
	# Fedora's v4l2h264dec drops ~31 frames around the change (the driver delivers
	# all 300, see the ffmpeg check): require EOS and frames at both sizes.
	out=$(timeout -k 5 60 "${fgst[@]}" /usr/bin/gst-launch-1.0 -v filesrc location=h264-reschange.ts ! tsdemux ! h264parse ! v4l2h264dec ! fakesink silent=false 2>&1)
	n720=$(grep -c 'chain .*(1413120 bytes' <<<"$out") n1080=$(grep -c 'chain .*(3133440 bytes' <<<"$out")
	echo "INFO gst h264 720p->1080p resolution change: $n720 + $n1080 of 150 + 150 frames"
	check "gst h264 720p->1080p resolution change: EOS with frames at both sizes" 'grep -q "Got EOS" <<<"$out" && [ "$n720" -gt 0 ] && [ "$n1080" -gt 0 ]'
	check "Mecha /opt/gstreamer still runs" 'LD_LIBRARY_PATH=/opt/gstreamer/lib64 /opt/gstreamer/bin/gst-inspect-1.0 --version'
fi

# mpv with the system config (/etc/mpv/mpv.conf) in the user's Wayland session.
smpv=(env XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1} mpv --no-config --include=/etc/mpv/mpv.conf --script=drops.lua --msg-level=all=info,vd=v)

if want mpv; then
	check "/etc/mpv/mpv.conf present" '[ -f /etc/mpv/mpv.conf ]'
	for f in h264-1080p30.mp4 hevc-1080p30.mp4 vp9-1080p30.webm; do
		i0=$(irqs)
		out=$(timeout -k 5 60 "${smpv[@]}" --fs --length=20 "$f" 2>&1)
		i1=$(irqs)
		check "mpv $f: hardware decoding (v4l2m2m)" 'grep -q "Using hardware decoding (v4l2m2m" <<<"$out"'
		drops=$(grep -o "DROPS.*" <<<"$out" | tail -1)
		# decoder drops must be 0; allow one compositor (vo) drop in 600 frames
		check "mpv $f: no decoder drops, at most 1 display drop ($drops)" 'grep -qE "DROPS vo=[01] dec=0 " <<<"$drops"'
		check "mpv $f: iris interrupts rose ($i0 -> $i1)" '[ "$i1" -gt "$i0" ]'
	done
	timeout -k 5 60 "${smpv[@]}" --length=10 --geometry=50%x50% h264-1080p30.mp4 >/tmp/mpv-a.log 2>&1 & a=$!
	sleep 2
	timeout -k 5 60 "${smpv[@]}" --length=8 --geometry=50%x50% h264-1080p30.mp4 >/tmp/mpv-b.log 2>&1; rb=$?
	wait $a; ra=$?
	# Looping seeks back after a drain: decoding must go on, not spin (it once
	# hung the decoder and spun 4 cores until the phone overheated).
	"${smpv[@]}" --fs --loop-file=inf h264-1280x536.mp4 >/tmp/mpv-loop.log 2>&1 & lp=$!
	sleep 15; i0=$(irqs); sleep 10; i1=$(irqs); cpu=$(ps -o %cpu= -p $lp | tr -d ' ')
	kill $lp; sleep 1; kill -9 $lp 2>/dev/null
	check "mpv loop: decoding continues after the loop point (irqs $i0 -> $i1, mpv cpu ${cpu}%)" '[ "$i1" -gt "$i0" ] && [ "${cpu%.*}" -lt 100 ]'
	check "two mpv at once: both exit 0 (rc $ra/$rb)" '[ "$ra" -eq 0 ] && [ "$rb" -eq 0 ]'
	echo "INFO second mpv: $(grep -E "Using hardware|Using software|fallback" /tmp/mpv-b.log | head -1)"
	for f in h264-2160p30.mp4 hevc-2160p30.mp4 vp9-2160p30.webm; do
		echo "INFO mpv 4K $f: $(timeout -k 5 40 "${smpv[@]}" --fs --length=10 "$f" 2>&1 | grep -o "DROPS.*" | tail -1)"
	done
fi

if want seq; then
	./gaps.sh || fail=1
fi

exit $fail
EOF
ssh -o ConnectTimeout=10 "$target" "ONLY=$only bash video-test/.verify-video.sh </dev/null"
