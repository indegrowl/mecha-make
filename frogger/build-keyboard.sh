#!/bin/bash
# Build the mechanix-keyboard RPM (frogger/keyboard/mechanix-keyboard.spec) for
# the frogger image. It is built natively in an arm64 Fedora 44 container, under
# qemu-user emulation on an x86_64 host. Output: frogger/out/rpms/mechanix-keyboard-*.aarch64.rpm
set -euo pipefail

cd "$(dirname "$0")/.."
spec=frogger/keyboard/mechanix-keyboard.spec
commit=$(sed -n 's/^%global commit //p' "$spec")
sha256=0d4744c9364ec31823313d2bb9104437774170a6b2d42dc27e5e5090427ca5c3
src=frogger/out/src/mechanix-keyboard-$commit.tar.gz

mkdir -p frogger/out/src frogger/out/rpms
if [ ! -f "$src" ]; then
    curl -fsSL -o "$src.tmp" "https://github.com/mecha-org/mechanix-keyboard/archive/$commit/mechanix-keyboard-$commit.tar.gz"
    mv "$src.tmp" "$src"
fi
echo "$sha256  $src" | sha256sum -c --quiet
cp frogger/keyboard/*.patch frogger/out/src/

# A registry name other than fedora:44 so the amd64 mecha-build base isn't replaced.
# label=disable: the data disk has no SELinux labels, so a relabel-free mount is refused
podman run --rm --security-opt label=disable --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euxc "
    dnf -y -q install rpm-build cargo rust gcc git pkgconf-pkg-config alsa-lib-devel libxkbcommon-devel wayland-devel mesa-libgbm-devel
    rpmbuild -bb --define '_topdir /tmp/rpmbuild' --define '_sourcedir /build/frogger/out/src' $spec
    cp /tmp/rpmbuild/RPMS/aarch64/mechanix-keyboard-*.aarch64.rpm frogger/out/rpms/
"
rm -f frogger/out/rpms/mechanix-keyboard-debug*.rpm
ls frogger/out/rpms/mechanix-keyboard-*.aarch64.rpm
