#!/bin/bash
set -euo pipefail

# Rootless containerized build (no host mkosi/sudo needed). Usage:
#   ./build.sh            incremental comet build (mkosi -f)
#   ./build.sh --force    full rebuild (mkosi -ff) - use after skeleton edits
#   ./build.sh --profile=qemu
#   ./build.sh --version=20260813-1200
#   ./build.sh --profile=frogger   Nothing Phone (4a): boot.img + userdata.img in
#                                  frogger/out/images (see README.md)
#   ./build.sh --profile=frogger --preflight-only   only check the inputs

CONTAINER_NAME=mecha-build

opts_force=0
profile="comet"
version=""
preflight_only=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force) opts_force=1 ;;
        --profile=*) profile="${1#--profile=}" ;;
        --version=*) version="${1#--version=}" ;;
        --preflight-only) preflight_only=1 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

cd "$(dirname "$0")"

# frogger needs local inputs that never enter git: credentials in mkosi.env,
# the kernel from frogger/build-kernel.sh and the phone's firmware.
frogger_preflight() {
    local ok=0 var
    for var in MECHA_USER_PASSWORD MECHANIX_LOCKSCREEN_PIN; do
        if ! grep -Eq "^$var=.+" mkosi.env 2>/dev/null; then
            echo "mkosi.env: $var not set"
            ok=1
        fi
    done
    if ! ls frogger/out/rpms/kernel-7.2.0-*.frogger.aarch64.rpm >/dev/null 2>&1 ||
        [ ! -f frogger/out/boot/Image.gz ] || [ ! -f frogger/out/boot/milos-nothing-frogger.dtb ]; then
        echo "no kernel RPM in frogger/out/rpms (run frogger/build-kernel.sh)"
        ok=1
    fi
    # frogger/make-images.sh runs on the host after the image build.
    local tool
    for tool in mkbootimg img2simg debugfs e2label; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "missing host tool: $tool"
            ok=1
        fi
    done
    if ! ls frogger/out/rpms/qbootctl-*.aarch64.rpm >/dev/null 2>&1; then
        echo "no qbootctl RPM in frogger/out/rpms (run frogger/build-qbootctl.sh)"
        ok=1
    fi
    local scratch
    scratch=$(mktemp -d)
    frogger/stage-firmware.sh "" "$scratch/fw" >/dev/null 2>"$scratch/err" || { cat "$scratch/err"; ok=1; }
    rm -rf "$scratch"
    return "$ok"
}

if [ "$profile" = frogger ]; then
    frogger_preflight || exit 1
    [ "$preflight_only" -eq 1 ] && exit 0
    frogger/stage-firmware.sh
elif [ "$preflight_only" -eq 1 ]; then
    exit 0
fi

if ! podman image exists "$CONTAINER_NAME"; then
    echo "==> Building build container ($CONTAINER_NAME)…"
    podman build -t "$CONTAINER_NAME" -f Containerfile .
fi

force_flag=""
[ "$opts_force" -eq 1 ] && force_flag="-ff"

if [ -z "$version" ]; then
    version=$(date -u +%Y%m%d-%H%M)
fi

commit_sha=$(git rev-parse --short HEAD)

echo "==> Building profile '$profile' (IMAGE_VERSION=$version, commit=$commit_sha)…"

export TIMEFORMAT='==> Build took %3lR (%R real)'
time podman run --rm --cap-add=SYS_ADMIN --network=host -v "$PWD":/build -w /build "$CONTAINER_NAME" \
    bash -euxc "git config --global --add safe.directory /build; mkosi --profile=$profile --image-version=\"$version\" --environment=MECHA_COMMIT_SHA=\"$commit_sha\" $force_flag -f build"

if [ "$profile" = frogger ]; then
    roots=(mechanix-os-frogger*root*.raw)
    if [ "${#roots[@]}" -ne 1 ] || [ ! -f "${roots[0]}" ]; then
        echo "expected one mechanix-os-frogger root partition image, found: ${roots[*]}" >&2
        exit 1
    fi
    frogger/make-images.sh "${roots[0]}" frogger/out/images
fi
