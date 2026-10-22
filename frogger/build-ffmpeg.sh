#!/bin/bash
# Rebuild Fedora 44's ffmpeg-free with the V4L2 mem2mem H.264 and HEVC decoders
# (frogger/ffmpeg/ffmpeg-v4l2.patch) and the v4l2m2m resolution-change fixes
# (frogger/ffmpeg/ffmpeg-v4l2m2m-*.patch) so mpv, Firefox and anything else using the
# system libavcodec can decode on the Iris VPU. Same sonames as Fedora's, release
# suffixed .frogger2 so it wins over the repo build. Built natively in an arm64
# Fedora 44 container under qemu-user emulation on an x86_64 host.
# Output: frogger/out/rpms/{ffmpeg-free,lib*-free{,-devel}}-*.frogger2.aarch64.rpm
# (-devel too: mpv-devel in the image pins the exact libav*-free-devel release)
set -euo pipefail

cd "$(dirname "$0")/.."
srpm=ffmpeg-8.1.3-1.fc44.src.rpm
sha256=08c3af9895d38fbd2ef71a3107a0edeef5c367dac31224d803a4db6e53721e45

mkdir -p frogger/out/src frogger/out/rpms
if [ ! -f "frogger/out/src/$srpm" ]; then
    podman run --rm --platform linux/arm64 -v "$PWD/frogger/out/src":/w -w /w registry.fedoraproject.org/fedora:44 \
        dnf -y -q download --source "${srpm%.src.rpm}"
fi
echo "$sha256  frogger/out/src/$srpm" | sha256sum -c --quiet

podman run --rm --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euxc "
    # Build against noopenh264 (Fedora repo) like Fedora does; the Cisco repo has no aarch64 -devel.
    dnf -y -q install rpm-build 'dnf-command(builddep)' patch
    mkdir -p /tmp/rpmbuild/SOURCES /tmp/rpmbuild/SPECS
    cd /tmp/rpmbuild/SOURCES
    rpm2cpio /build/frogger/out/src/$srpm | cpio -idm --quiet
    patch -p1 < /build/frogger/ffmpeg/ffmpeg-v4l2.patch
    cp /build/frogger/ffmpeg/ffmpeg-v4l2m2m-*.patch .
    mv ffmpeg.spec ../SPECS/
    dnf -y -q --setopt=retries=20 --disablerepo=fedora-cisco-openh264 builddep ../SPECS/ffmpeg.spec
    rpmbuild -bb --nocheck --define '_topdir /tmp/rpmbuild' ../SPECS/ffmpeg.spec
    for f in /tmp/rpmbuild/RPMS/aarch64/*.rpm; do
        case \$f in *-debug*) ;; *) cp \$f /build/frogger/out/rpms/ ;; esac
    done
"
ls frogger/out/rpms/*frogger2*.rpm
