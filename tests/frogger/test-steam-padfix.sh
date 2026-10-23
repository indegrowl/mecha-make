#!/bin/bash
# Builds and runs the streaming_client padding shim test on the host.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cc -Wall -Werror -Wno-unused-result -o "$tmp/t" tests/frogger/test-steam-padfix.c
"$tmp/t"
