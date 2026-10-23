#!/bin/bash
# Rebuild Fedora 44's gamescope with frogger/gamescope/gamescope-touch-spi.patch:
# gamescope only maps I2C touchscreens to the internal panel (and so to its
# rotation); the frogger's FocalTech touchscreen is on SPI, so touches landed
# unrotated on the landscape Steam UI. Release suffixed .frogger1 so it wins over
# the repo build. Built natively in an arm64 Fedora 44 container under qemu-user
# emulation on an x86_64 host. Output: frogger/out/rpms/gamescope-*.frogger1.aarch64.rpm
set -euo pipefail

cd "$(dirname "$0")/.."
srpm=gamescope-3.16.29-1.fc44.src.rpm
sha256=4869f3fd7e24a14bf5e4959b7c4365a78335ff8c864d241086ff68310190084c

mkdir -p frogger/out/src frogger/out/rpms
if [ ! -f "frogger/out/src/$srpm" ]; then
    podman run --rm --platform linux/arm64 -v "$PWD/frogger/out/src":/w -w /w registry.fedoraproject.org/fedora:44 \
        dnf -y -q download --source "${srpm%.src.rpm}"
fi
echo "$sha256  frogger/out/src/$srpm" | sha256sum -c --quiet

podman run --rm --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euxc "
    dnf -y -q install rpm-build 'dnf-command(builddep)'
    mkdir -p /tmp/rpmbuild/SOURCES /tmp/rpmbuild/SPECS
    cd /tmp/rpmbuild/SOURCES
    rpm2cpio /build/frogger/out/src/$srpm | cpio -idm --quiet
    cp /build/frogger/gamescope/gamescope-touch-spi.patch .
    sed -i -e 's/^Release:.*/Release:        1%{?dist}.frogger1/' \
        -e '/^Patch:          Use-system-stb-glm.patch/a Patch:          gamescope-touch-spi.patch' gamescope.spec
    mv gamescope.spec ../SPECS/
    dnf -y -q --setopt=retries=20 --disablerepo=fedora-cisco-openh264 builddep ../SPECS/gamescope.spec
    rpmbuild -bb --nocheck --define '_topdir /tmp/rpmbuild' ../SPECS/gamescope.spec
    for f in /tmp/rpmbuild/RPMS/aarch64/*.rpm; do
        case \$f in *-debug*) ;; *) cp \$f /build/frogger/out/rpms/ ;; esac
    done
"
ls frogger/out/rpms/*frogger1.aarch64.rpm
