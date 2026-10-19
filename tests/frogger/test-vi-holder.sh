#!/bin/bash
# Checks the frogger-vi-holder playback-state decision.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

FROGGER_VI_HOLDER_LIB=1 source mkosi.extra.frogger/usr/libexec/frogger-vi-holder

check "closed playback releases V/I"   '! wants_vi "closed"'
check "empty status releases V/I"      '! wants_vi ""'
check "set-up stream holds V/I"        'wants_vi "state: SETUP"'
check "prepared stream holds V/I"      'wants_vi "state: PREPARED"'
check "running stream holds V/I"       'wants_vi "state: RUNNING"'
check "draining stream holds V/I"      'wants_vi "state: DRAINING"'

[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
