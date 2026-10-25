#!/bin/bash
# Build moonlight-qt (frogger/moonlight/moonlight-qt.spec) against the frogger
# ffmpeg-free (.frogger4, frogger/build-ffmpeg.sh), so its hevc_v4l2m2m decoder
# runs on the Iris VPU. Built natively in an arm64 Fedora 44 container under
# qemu-user emulation on an x86_64 host.
# Output: frogger/out/rpms/moonlight-qt-*.frogger2.aarch64.rpm
set -euo pipefail

cd "$(dirname "$0")/.."
version=6.2.0
tarball=MoonlightSrc-$version.tar.gz
sha256=217afac54e4f8734f3d97b32cb8c8b46b677e87f25b77c945343dd06f359e189
spec=frogger/moonlight/moonlight-qt.spec

mkdir -p frogger/out/src/moonlight frogger/out/rpms
if [ ! -f "frogger/out/src/moonlight/$tarball" ]; then
    curl -sSLf -o "frogger/out/src/moonlight/$tarball" \
        "https://github.com/moonlight-stream/moonlight-qt/releases/download/v$version/$tarball"
fi
echo "$sha256  frogger/out/src/moonlight/$tarball" | sha256sum -c --quiet
ls frogger/out/rpms/libavcodec-free-devel-*.frogger4.aarch64.rpm >/dev/null

# A registry name other than fedora:44 so the amd64 mecha-build base isn't replaced.
# label=disable: the data disk has no SELinux labels, so a relabel-free mount is refused
podman run --rm --security-opt label=disable --platform linux/arm64 -v "$PWD":/build -w /build registry.fedoraproject.org/fedora:44 bash -euxc "
    # The frogger FFmpeg first, so builddep can't pull Fedora's
    dnf -y -q --setopt=retries=20 install rpm-build 'dnf-command(builddep)' \
        /build/frogger/out/rpms/lib{avcodec,avutil,swscale,swresample}-free{,-devel}-*.frogger4.aarch64.rpm
    dnf -y -q --setopt=retries=20 builddep $spec
    rpmbuild -bb --define '_topdir /tmp/rpmbuild' --define '_sourcedir /build/frogger/out/src/moonlight' $spec
    cp /tmp/rpmbuild/RPMS/aarch64/moonlight-qt-$version-*.aarch64.rpm frogger/out/rpms/
"
rm -f frogger/out/rpms/moonlight-qt-debug*.rpm
ls frogger/out/rpms/moonlight-qt-*.frogger2*.aarch64.rpm
