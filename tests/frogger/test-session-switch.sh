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
calls=$tmp/calls
stop_greetd() { echo stop >>"$calls"; }
start_greetd() { echo start >>"$calls"; restarts=$((restarts + 1)); }
wait_seat_free() { echo "wait greetd.run=$([ -e "$GREETD_RUN" ] && echo yes || echo no)" >>"$calls"; }
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
check "old session ends before greetd starts" '[ "$(tr "\n" " " <"$calls")" = "stop wait greetd.run=no start " ]'
switch_to steam
check "switch twice leaves one flag" '[ "$(cat "$flag")" = steam ]'
touch "$GREETD_RUN"; restarts=0
switch_to mechanix
check "switch mechanix clears the flag" '[ ! -e "$flag" ]'
check "switch mechanix restarts greetd" '[ $restarts = 1 ]'
restarts=0
check "switch rejects other names" '! switch_to foo 2>/dev/null'
check "rejected switch writes nothing" '[ ! -e "$flag" ] && [ $restarts = 0 ]'

mkdir "$tmp/bin"
printf '#!/bin/sh\nn=$(cat "%s" 2>/dev/null || echo 0); echo $((n + 1)) >"%s"\n[ "$n" -lt 2 ] && echo "c1 1000 mecha seat0 123 user tty2 yes -"\necho "c9 1000 mecha - 456 user - no -"\n' "$tmp/n" "$tmp/n" >"$tmp/bin/loginctl"
chmod 755 "$tmp/bin/loginctl"
unset -f wait_seat_free
source mkosi.extra.frogger/usr/libexec/frogger-session-switch
PATH=$tmp/bin:$PATH SEAT_POLL=0 wait_seat_free
check "waits until seat0 has no session" '[ "$(cat "$tmp/n")" = 3 ]'

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
