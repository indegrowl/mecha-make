#!/bin/bash
# Iris decoder client-sequence checks with iris-seq (run on the phone in
# ~/video-test). Prints PASS/FAIL lines; exits non-zero on any FAIL.
cd "$(dirname "$0")" || exit 2
fail=0
H="h264 es/h264-1080p30.aud.h264 es/h264-1080p30.adler"
R="h264 es/h264-reschange.aud.h264 es/h264-reschange.adler"
seq_() { timeout -k 2 60 ./iris-seq "$@" 2>&1; }
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; echo "$2" | sed 's/^/      /' | tail -8; fail=1; }
# frames=N on the OP line of op number $2 (1-based)
opf() { grep '^OP' <<<"$1" | sed -n "${2}p" | grep -o 'frames=[0-9]*' | cut -d= -f2; }
opl() { grep '^OP' <<<"$1" | sed -n "${2}p"; }
sum() { grep -o "$2=[0-9]*" <<<"$(grep SUMMARY <<<"$1")" | cut -d= -f2; }

# gap 3: a second STOP while draining is refused, decoding still ends cleanly
o=$(seq_ $H play:300 stop wait:300 stop wait:3000 drain)
if grep -q "STOP: Device or resource busy" <<<"$o" && [ "$(sum "$o" hang)" = 0 ] && [ "$(sum "$o" last)" -ge 1 ]; then ok "second STOP during a drain refused (EBUSY), drain completes"; else bad "second STOP during a drain refused (EBUSY), drain completes" "$o"; fi

# restart after a finished drain, same session
# (resume at keyframe 360: the GOP is 60 frames)
for v in "start" "seek:360 start" "seekc:360"; do
	o=$(seq_ $H feed:360 drain $v play:100)
	n=$(grep '^OP play:100' <<<"$o" | grep -o 'frames=[0-9]*' | cut -d= -f2)
	if [ "${n:-0}" -ge 100 ] && [ "$(sum "$o" hang)" = 0 ] && [ "$(sum "$o" frames)" = "$(sum "$o" matched)" ]; then ok "restart after drain via '$v': 100 more frames, all exact"; else bad "restart after drain via '$v': 100 more frames, all exact" "$o"; fi
done

# gap 2: EOS event at each end of stream
o=$(seq_ $H feed:360 drain start feed:120 drain wait:500)  # EOS may follow the LAST buffer
if [ "$(sum "$o" eos)" -ge 2 ]; then ok "EOS event on both drains of one session (eos=$(sum "$o" eos))"; else bad "EOS event on both drains of one session" "$o"; fi
o=$(seq_ $R play:5000 drain wait:500)  # EOS may follow the LAST buffer
n=$(( $(opl "$o" 2 | grep -o 'eos=[0-9]*' | cut -d= -f2) + $(opl "$o" 3 | grep -o 'eos=[0-9]*' | cut -d= -f2) ))
if [ "${n:-0}" -ge 1 ] && [ "$(sum "$o" matched)" = 300 ]; then ok "resolution change then drain: 300/300 exact, EOS at the end"; else bad "resolution change then drain: 300/300 exact, EOS at the end" "$o"; fi

# gap 1: a session error wakes the client (unsupported 10-bit HEVC)
s=$(date +%s)
o=$(seq_ h264 es/h264-interlaced.aud.h264 es/h264-1080p30.adler play:30); rc=$?
t=$(( $(date +%s) - s ))
# told at once: POLLERR from the queue error, or an ioctl error at setup
if [ "$rc" != 3 ] && [ "$t" -lt 5 ] && { grep -q POLLERR <<<"$o" || [ "$rc" = 2 ]; }; then ok "unsupported stream: client woken with an error (${t}s)"; else bad "unsupported stream: client woken with an error (${t}s)" "$o"; fi

# gap 6: seek while a drain is still running
o=$(seq_ $H feed:300 stop seekc:360 play:100)
n=$(grep '^OP play:100' <<<"$o" | grep -o 'frames=[0-9]*' | cut -d= -f2)
if [ "${n:-0}" -ge 100 ] && [ "$(sum "$o" hang)" = 0 ]; then ok "seek during a drain: decoding resumes"; else bad "seek during a drain: decoding resumes" "$o"; fi

# gaps 4/5: seek storm
ops="play:30"; for k in $(seq 1 20); do ops="$ops seekc:$(( (k * 120) % 840 )) play:5"; done  # keyframes: multiples of 60
o=$(seq_ $H $ops drain)
if [ "$(sum "$o" hang)" = 0 ] && [ "$(sum "$o" frames)" = "$(sum "$o" matched)" ] && ! grep -q POLLERR <<<"$o"; then ok "20 seeks: no error, no hang, all frames exact ($(sum "$o" frames))"; else bad "20 seeks: no error, no hang, all frames exact" "$o"; fi

# gap 8: too many sessions fail cleanly at open, the rest decode
for i in $(seq 1 20); do (seq_ $H play:30 > /tmp/sess.$i 2>&1; echo $? >> /tmp/sess.$i) & done; wait
good=$(grep -l "SUMMARY frames=3[0-9] matched=3[0-9]" /tmp/sess.* | wc -l)
hung=$(grep -l "hang=1" /tmp/sess.* | wc -l)
early=$(grep -lE "^(S_FMT|REQBUFS|STREAMON|SUBSCRIBE|QUERYBUF|mmap)|no Iris decoder" /tmp/sess.* | wc -l)
echo "INFO 20 sessions: $good decoded, $early refused at setup, $hung hung"
if [ "$hung" = 0 ] && [ $(( good + early )) = 20 ]; then ok "20 parallel sessions: each decodes or is refused at setup"; else bad "20 parallel sessions: each decodes or is refused at setup" "$(cat /tmp/sess.* | grep -vE '^ +capture|^input' | sort | uniq -c | head)"; fi
rm -f /tmp/sess.*
exit $fail
