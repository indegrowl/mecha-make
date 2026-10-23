#!/bin/bash
# Build the frogger-steam-padfix RPM (frogger/steam/frogger-steam-padfix.spec) for
# the frogger image. It is built natively in an arm64 Fedora 44 container, under
# qemu-user emulation on an x86_64 host. Output: frogger/out/rpms/frogger-steam-padfix-*.aarch64.rpm
set -euo pipefail

cd "$(dirname "$0")/.."
spec=frogger/steam/frogger-steam-padfix.spec
mkdir -p frogger/out/src frogger/out/rpms
cp frogger/steam/sc-padfix.c frogger/out/src/

# A registry name other than fedora:44 so the amd64 mecha-build base isn't replaced.
podman run --rm --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euxc "
    dnf -y -q install rpm-build gcc kernel-headers
    rpmbuild -bb --define '_topdir /tmp/rpmbuild' --define '_sourcedir /build/frogger/out/src' $spec
    cp /tmp/rpmbuild/RPMS/aarch64/frogger-steam-padfix-*.aarch64.rpm frogger/out/rpms/
"
rm -f frogger/out/rpms/frogger-steam-padfix-debug*.rpm
ls frogger/out/rpms/frogger-steam-padfix-*.aarch64.rpm
