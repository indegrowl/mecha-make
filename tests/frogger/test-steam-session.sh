#!/bin/bash
# Checks the Steam session pieces: streaming_client wrapper upkeep, the wrapper
# itself, and that every way out of Steam switches back to Mechanix.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
x=mkosi.extra.frogger
template=$x/usr/share/frogger-steam/streaming_client
FROGGER_STEAM_LIB=1 source $x/usr/libexec/frogger-steam-run

rt=$tmp/steamrtarm64
mkdir -p "$rt"
printf '\x7fELF one' >"$rt/streaming_client"
ensure_wrapper "$rt" "$template"
check "ELF client moves to .real" '[ "$(cat "$rt/streaming_client.real")" = "$(printf "\x7fELF one")" ]'
check "wrapper installed" 'cmp -s "$rt/streaming_client" "$template" && [ -x "$rt/streaming_client" ]'
ensure_wrapper "$rt" "$template"
check "wrapper left alone" '[ "$(cat "$rt/streaming_client.real")" = "$(printf "\x7fELF one")" ] && cmp -s "$rt/streaming_client" "$template"'
printf '\x7fELF two' >"$rt/streaming_client"
ensure_wrapper "$rt" "$template"
check "updated ELF replaces .real" '[ "$(cat "$rt/streaming_client.real")" = "$(printf "\x7fELF two")" ]'

printf '#!/bin/bash\necho "preload=$LD_PRELOAD args=$*"\n' >"$rt/streaming_client.real"
chmod 755 "$rt/streaming_client.real"
SC_LOG=$tmp/sc.log "$rt/streaming_client" --a --openvr --b
check "wrapper drops --openvr" 'grep -q "args=--a --b$" "$tmp/sc.log"'
check "wrapper preloads the shim" 'grep -q "preload=/usr/lib64/frogger-steam/sc-padfix.so" "$tmp/sc.log"'

# Stubs: gamescope fails at once, systemctl records what it was asked.
mkdir "$tmp/bin"
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/gamescope"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$tmp/systemctl.log" >"$tmp/bin/systemctl"
chmod 755 "$tmp/bin/"*
PATH=$tmp/bin:$PATH FROGGER_STEAM_LOG=$tmp/steam.log $x/usr/libexec/frogger-steam-session
check "failing gamescope still switches back" 'grep -qx "start --no-block frogger-session-switch@mechanix.service" "$tmp/systemctl.log"'
rm -f "$tmp/systemctl.log"
PATH=$tmp/bin:$PATH $x/usr/bin/steamos-session-select plasma
check "steamos-session-select switches back" 'grep -qx "start --no-block frogger-session-switch@mechanix.service" "$tmp/systemctl.log"'
rm -f "$tmp/systemctl.log"
PATH=$tmp/bin:$PATH $x/usr/bin/frogger-steam
check "launcher entry switches to steam" 'grep -qx "start --no-block frogger-session-switch@steam.service" "$tmp/systemctl.log"'

d=$x/usr/share/applications/frogger-steam.desktop
check "desktop entry runs frogger-steam" 'grep -qx "Exec=/usr/bin/frogger-steam" $d'
check "desktop entry icon" 'grep -qx "Icon=applications-games" $d'
check "desktop entry name" 'grep -qx "Name=Steam" $d'
for f in usr/libexec/frogger-steam-session usr/libexec/frogger-steam-run usr/bin/frogger-steam \
    usr/bin/steamos-session-select usr/share/frogger-steam/streaming_client; do
    check "$f executable in git" '[ "$(git ls-files -s $x/$f | cut -c1-6)" = 100755 ]'
done

[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
