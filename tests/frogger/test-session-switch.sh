#!/bin/bash
# Checks the one-shot Mechanix/Steam session switch (chooser, switch helper,
# greetd config, polkit rule).
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FROGGER_SESSION_LIB=1 FROGGER_SESSION_DIR=$tmp/run GREETD_RUN=$tmp/greetd.run
source mkosi.extra.frogger/usr/libexec/frogger-session-chooser
source mkosi.extra.frogger/usr/libexec/frogger-session-switch
restarts=0
restart_greetd() { restarts=$((restarts + 1)); }
flag=$tmp/run/next

check "no flag chooses mechanix" '[ "$(chosen_session)" = mechanix ]'
mkdir -p "$tmp/run"; echo steam >"$flag"
check "steam flag chooses steam" '[ "$(chosen_session)" = steam ]'
check "steam flag is used once" '[ "$(chosen_session)" = mechanix ]'
echo "rm -rf /" >"$flag"
check "garbage flag chooses mechanix" '[ "$(chosen_session)" = mechanix ]'

touch "$GREETD_RUN"; restarts=0
switch_to steam
check "switch steam writes the flag" '[ "$(cat "$flag")" = steam ]'
check "switch steam removes greetd.run" '[ ! -e "$GREETD_RUN" ]'
check "switch steam restarts greetd once" '[ $restarts = 1 ]'
switch_to steam
check "switch twice leaves one flag" '[ "$(cat "$flag")" = steam ]'
touch "$GREETD_RUN"; restarts=0
switch_to mechanix
check "switch mechanix clears the flag" '[ ! -e "$flag" ]'
check "switch mechanix restarts greetd" '[ $restarts = 1 ]'
restarts=0
check "switch rejects other names" '! switch_to foo 2>/dev/null'
check "rejected switch writes nothing" '[ ! -e "$flag" ] && [ $restarts = 0 ]'

check "greetd runs the chooser" \
    'grep -qx "command = \"/usr/libexec/frogger-session-chooser\"" mkosi.extra.frogger/etc/greetd/config.toml'
check "greetd still logs in mecha" 'grep -qx "user = \"mecha\"" mkosi.extra.frogger/etc/greetd/config.toml'
rule=mkosi.extra.frogger/etc/polkit-1/rules.d/50-frogger-session-switch.rules
check "polkit names the steam unit" 'grep -q "frogger-session-switch@steam.service" $rule'
check "polkit names the mechanix unit" 'grep -q "frogger-session-switch@mechanix.service" $rule'
check "polkit only for mecha" 'grep -q "subject.user == \"mecha\"" $rule'
check "polkit only for start" 'grep -q "\"start\"" $rule'
check "polkit grants in one place" '[ "$(grep -c "Result.YES" $rule)" = 1 ]'
unit=mkosi.extra.frogger/usr/lib/systemd/system/frogger-session-switch@.service
check "switch unit runs the helper" 'grep -qx "ExecStart=/usr/libexec/frogger-session-switch %i" $unit'
for f in frogger-session-chooser frogger-session-switch; do
    check "$f executable in git" '[ "$(git ls-files -s mkosi.extra.frogger/usr/libexec/$f | cut -c1-6)" = 100755 ]'
done

[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
