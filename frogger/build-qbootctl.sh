#!/bin/bash
# Build the qbootctl RPM (frogger/qbootctl/qbootctl.spec) for the frogger image.
# It is built natively in an arm64 Fedora 44 container, under qemu-user
# emulation on an x86_64 host. Output: frogger/out/rpms/qbootctl-*.aarch64.rpm
set -euo pipefail

cd "$(dirname "$0")/.."
spec=frogger/qbootctl/qbootctl.spec
commit=$(sed -n 's/^%global commit //p' "$spec")
sha256=9dc68fdc00309dacedaf5077d83c673f531c4abce37a65453830455b8de8b67b
src=frogger/out/src/qbootctl-$commit.tar.gz

mkdir -p frogger/out/src frogger/out/rpms
if [ ! -f "$src" ]; then
    curl -fsSL -o "$src.tmp" "https://github.com/linux-msm/qbootctl/archive/$commit/qbootctl-$commit.tar.gz"
    mv "$src.tmp" "$src"
fi
echo "$sha256  $src" | sha256sum -c --quiet

# A registry name other than fedora:44 so the amd64 mecha-build base isn't replaced.
podman run --rm --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euxc "
    dnf -y -q install rpm-build gcc meson kernel-headers
    rpmbuild -bb --define '_topdir /tmp/rpmbuild' --define '_sourcedir /build/frogger/out/src' $spec
    cp /tmp/rpmbuild/RPMS/aarch64/qbootctl-*.aarch64.rpm frogger/out/rpms/
"
rm -f frogger/out/rpms/qbootctl-debug*.rpm
ls frogger/out/rpms/qbootctl-*.aarch64.rpm
