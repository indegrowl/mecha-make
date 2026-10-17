#!/bin/bash
# Cross-build the Nothing Phone (4a) kernel on an x86_64 host and package it as
# an RPM for the frogger image.
#
#   KERNEL_SRC  kernel tree on branch milos-7.2.y (default: ../linux)
#
# Outputs (frogger/out/, gitignored):
#   kbuild/                              out-of-tree build directory
#   rpms/kernel-7.2.0-*.frogger.aarch64.rpm   the only RPM the image installs
#   boot/Image.gz, boot/milos-nothing-frogger.dtb   for boot.img
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD
src=$(realpath "${KERNEL_SRC:-../linux}")
out=$repo/frogger/out
release=7.2.0
branch=milos-7.2.y

actual_branch=$(git -C "$src" rev-parse --abbrev-ref HEAD)
if [ "$actual_branch" != "$branch" ]; then
    echo "$src is on '$actual_branch', expected $branch" >&2
    exit 1
fi

mkdir -p "$out/kbuild" "$out/rpms" "$out/boot"
make=(make -C "$src" O="$out/kbuild" ARCH=arm64 LLVM=1 LOCALVERSION= -j"$(nproc)")

cp frogger/kernel/frogger.config "$out/kbuild/.config"
"${make[@]}" olddefconfig
"${make[@]}" Image.gz qcom/milos-nothing-frogger.dtb modules

actual_release=$("${make[@]}" -s kernelrelease)
if [ "$actual_release" != "$release" ]; then
    echo "kernelrelease is '$actual_release', expected $release" >&2
    exit 1
fi

rm -rf "$out/kbuild/rpmbuild/RPMS"
# The ".frogger" release tag is what the image asks for (kernel-7.2.0-*.frogger),
# so it can never pick a Fedora or Mecha kernel of the same version.
"${make[@]}" binrpm-pkg RPMOPTS="--define 'dist .frogger'"

rm -f "$out/rpms"/*.rpm
cp "$out/kbuild/rpmbuild/RPMS/aarch64/kernel-$release-"*.aarch64.rpm "$out/rpms/"
cp "$out/kbuild/arch/arm64/boot/Image.gz" "$out/boot/"
cp "$out/kbuild/arch/arm64/boot/dts/qcom/milos-nothing-frogger.dtb" "$out/boot/"
echo "built kernel $release: $(ls "$out/rpms")"
