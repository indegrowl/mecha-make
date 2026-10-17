# Mechanix OS Build System

Build system for creating Fedora-based images for Mecha Comet devices using `mkosi`.

## Repository Layout

- `mkosi.conf` – Base mkosi configuration.
- `mkosi.conf.d/` – Package groups and additional configuration.
- `mkosi.profiles/` – Build profiles such as `comet`, `release`, and `qemu`.
- `mkosi.skeleton/` – Files copied into the image before the package manager runs.
  Note: with incremental builds, skeleton changes need a full rebuild (`-ff`).
- `mkosi.extra.comet/` – Comet-only files copied in after the OS is installed
  (USB gadget service, dnsmasq config). Applied on every build.
- `mkosi.version` – Image version.
- `build.sh` – Rootless, containerized build wrapper (see below).

## Prerequisites

Install the required tools:

```sh
sudo apt update
sudo apt install -y mkosi qemu-system-x86 ovmf debootstrap
```

## View Configuration

Show the current mkosi configuration:

```sh
mkosi summary
```

## Development Credentials

The root account is disabled.

A regular user named `mecha` is created during the build.

To set a password for development:

```sh
echo "MECHA_USER_PASSWORD=YOUR_PASSWORD" > mkosi.env
chmod 600 mkosi.env
```

`mechanix-lockscreen`'s PIN if left unset, the lockscreen falls back to tap-to-unlock. To provision a PIN on built images, add it to `mkosi.env`:

```sh
echo "MECHANIX_LOCKSCREEN_PIN=YOUR_4_DIGIT_PIN" >> mkosi.env
```

Do not commit `mkosi.env`.

## Build

A profile is always required.

### Host-installed mkosi

```sh
sudo mkosi --profile=comet -f build
```

Build a release image:

```sh
sudo mkosi --profile=comet,release -f build
```

### Containerized

`./build.sh` builds inside a podman container and stamps the image version + commit SHA:

```sh
./build.sh                     # incremental comet build (mkosi -f)
./build.sh --force             # full rebuild (mkosi -ff)
./build.sh --profile=qemu      # other profiles
./build.sh --version=20260813-1200   # override the IMAGE_VERSION stamp
```

Incremental builds cache the package-install step. After editing `mkosi.skeleton/`, rebuild with `--force` (`-ff`).

## Inspect the Image

Open a shell inside the built image:

```sh
sudo mkosi shell
```

## Test in QEMU

Build and boot the QEMU image:

```sh
./run-qemu.sh
```

Force a rebuild before booting:

```sh
./run-qemu.sh --build
```

If you only want to boot a prebuilt image from GitHub Actions, download the `mechanix-os-qemu-raw` and `run-qemu` artifacts, extract them into the same directory, and run:

```sh
chmod +x run-qemu.sh
./run-qemu.sh
```

## SSH over USB-C

The comet image exposes a USB ethernet gadget (`usb0` = `172.16.42.1/24`) on
the USB-C/PD port. Use `ssh mecha@172.16.42.1` to connect to the device. Only enabled for the comet profile.

## Nothing Phone (4a) (frogger)

The `frogger` profile builds the same Mechanix OS as `comet` for the Nothing
Phone (4a). The phone's bootloader boots an Android boot image, so the build
produces `boot.img` (kernel, DTB, initramfs) and `userdata.img` (the root
filesystem, written straight onto the `userdata` partition).

The phone must already have an unlocked bootloader, `vbmeta_a` with
verification disabled and a zeroed `dtbo_a`.

### Inputs (all local, never committed)

- `mkosi.env` with `MECHA_USER_PASSWORD` and `MECHANIX_LOCKSCREEN_PIN` (both
  required for frogger), and optionally `MECHA_SSH_AUTHORIZED_KEY` (a public key
  installed for `mecha`).
- qbootctl: `frogger/build-qbootctl.sh` builds it as an aarch64 RPM (needs
  `podman` with arm64 emulation). The image runs `qbootctl -m` after every good
  boot, so the bootloader's slot retry counter never runs out.
- The kernel: `frogger/build-kernel.sh` cross-builds `../linux` (branch
  `milos-7.2.y`, override with `KERNEL_SRC`) with clang and packages it as
  `frogger/out/rpms/kernel-7.2.0-*.frogger.aarch64.rpm`. Needs `rpmbuild`.
- The firmware (proprietary, from the phone): the 11 files listed in
  `frogger/stage-firmware.sh`, read from `$FROGGER_FW_DIR`
  (default `../pmaports/device/testing/firmware-nothing-frogger`).

On an x86_64 host the arm64 image builds under emulation, so `qemu-user-static`
with binfmt must be registered.

### Build

```sh
frogger/build-kernel.sh
./build.sh --profile=frogger
```

`./build.sh --profile=frogger --preflight-only` only checks the inputs. The
images and `SHA256SUMS` end up in `frogger/out/images/`.

### Flash

```sh
frogger/flash-frogger.sh userdata   # wipes userdata
frogger/flash-frogger.sh ramboot    # boots boot.img without flashing it
frogger/flash-frogger.sh boot_a     # only after the RAM boot works
```

Enter fastboot from Linux (`systemctl reboot --reboot-argument=bootloader`),
not with the buttons.

### Kernel updates

`dnf` never updates the kernel on the phone: the kernel in `boot_a` and its
modules in `/usr/lib/modules/7.2.0` must come from the same build.

```sh
frogger/build-kernel.sh && ./build.sh --profile=frogger
frogger/kernel-update.sh            # replaces the kernel RPM (modules) on the phone
# reboot to the bootloader from Linux, then:
frogger/flash-frogger.sh ramboot    # test the new boot.img
frogger/flash-frogger.sh boot_a     # only if it works
```

Host tools needed by `frogger/make-images.sh`: `mkbootimg`, `img2simg`
(android-tools), `debugfs`, `e2label` (e2fsprogs). The preflight checks them.
