#!/bin/bash
# Build the iris-seq decoder sequence tester as a static arm64 binary in a
# Fedora 44 container (qemu-user on x86_64 hosts). Output: frogger/out/iris-seq
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p frogger/out
podman run --rm --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euc "
    dnf -y -q install gcc glibc-static kernel-headers >/dev/null
    gcc -O2 -Wall -Wextra -static -o frogger/out/iris-seq frogger/iris-seq/iris-seq.c
"
ls -la frogger/out/iris-seq
