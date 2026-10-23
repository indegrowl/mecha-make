#!/bin/bash
# Build the mechanix-compositor RPM (frogger/compositor/mechanix-compositor.spec)
# for the frogger image: the Mecha 1.0.0 source with smithay pinned before the
# Comet colour matrix. Built natively in an arm64 Fedora 44 container, under
# qemu-user emulation on an x86_64 host. Output: frogger/out/rpms/mechanix-compositor-*.aarch64.rpm
set -euo pipefail

cd "$(dirname "$0")/.."
spec=frogger/compositor/mechanix-compositor.spec
commit=$(sed -n 's/^%global commit //p' "$spec")
sha256=9938289151cf69ce2e82201453b2055500689709d665e421907452cb0959df2a
src=frogger/out/src/mechanix-comp-$commit.tar.gz

mkdir -p frogger/out/src frogger/out/rpms
if [ ! -f "$src" ]; then
    curl -fsSL -o "$src.tmp" "https://github.com/mecha-org/mechanix-comp/archive/$commit/mechanix-comp-$commit.tar.gz"
    mv "$src.tmp" "$src"
fi
echo "$sha256  $src" | sha256sum -c --quiet
cp frogger/compositor/*.patch frogger/out/src/

# A registry name other than fedora:44 so the amd64 mecha-build base isn't replaced.
podman run --rm --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euxc "
    dnf -y -q install rpm-build cargo rust gcc git pkgconf-pkg-config mesa-libgbm-devel libdrm-devel libseat-devel libinput-devel systemd-devel libxkbcommon-devel wayland-devel
    rpmbuild -bb --define '_topdir /tmp/rpmbuild' --define '_sourcedir /build/frogger/out/src' $spec
    cp /tmp/rpmbuild/RPMS/aarch64/mechanix-compositor-*.aarch64.rpm frogger/out/rpms/
"
rm -f frogger/out/rpms/mechanix-compositor-debug*.rpm
ls frogger/out/rpms/mechanix-compositor-*.aarch64.rpm
