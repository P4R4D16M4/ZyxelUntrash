# Building UntrashOS

> **You only want to install UntrashOS? You do not need to build anything.**
> Download the ready stick image and write it to a USB stick:
>
> 1. Download [`untrash-stick-1.2-rc4.img.xz`](https://github.com/P4R4D16M4/ZyxelUntrash/releases/download/v1.2-rc4/untrash-stick-1.2-rc4.img.xz)
>    (about 270 MB; all versions are on the [Releases](https://github.com/P4R4D16M4/ZyxelUntrash/releases) page).
> 2. Install [balenaEtcher](https://etcher.balena.io/) or
>    [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (Windows, macOS, Linux).
> 3. Choose the downloaded `.img.xz` (no need to unpack it), choose a USB stick of at least
>    4 GB and write.  **Everything on the stick is erased.**
> 4. Continue with the [user guide](user-guide/README.md#13-first-run-under-the-zyxel-firmware):
>    stick into the NAS, switch it on.
>
> The rest of this page is for developers who want to build the image themselves.

UntrashOS is built on a Debian/Ubuntu PC (x86-64) for the NAS542 (ARMv7).
Everything comes from this repository, the UntrashOS repository (the
device-independent part, a git submodule in `untrashos/`) and a few external
inputs that are downloaded from their official sources or that you provide
yourself.  Nothing proprietary is stored in the repositories.

```
git clone --recursive https://github.com/P4R4D16M4/ZyxelUntrash.git
```

In an existing checkout: `git submodule update --init`.  The submodule is
pinned to one UntrashOS commit; `git submodule update --remote` moves it to
the newest one (then commit the new pin).

## 1. Tools

```
sudo apt install build-essential gcc-arm-linux-gnueabihf bc bison flex libssl-dev \
  u-boot-tools erofs-utils cryptsetup-bin fakeroot dosfstools mtools gdisk cpio \
  python3 python3-pil git curl xz-utils qemu-user-static binfmt-support dnsmasq-base
```

`mkosi` (v25.3, rootfs builder) is fetched by `make inputs`.

## 2. External inputs (`inputs/`, never committed)

`make inputs` (`tools/fetch-inputs.sh`) downloads them and checks fixed SHA-256 sums.
The firmware of the network engine (PFE) is not among them: every NAS542
carries it in its stock kernel, and UntrashOS extracts it on the NAS
(`untrash-pfe-firmware`): from the copy of the stock kernel that the install run
saves to the stick, or from the stock kernel slot in the NAND; the image ships
no proprietary firmware.

| File | Source |
|---|---|
| `inputs/src/linux-6.6.145.tar.xz` | kernel.org |
| `inputs/src/kexec-tools-2.0.31.tar.xz` | kernel.org |
| `inputs/src/busybox-1.37.0.tar.bz2` | busybox.net (static userland of the loader) |
| `inputs/mkosi/` | github.com/systemd/mkosi, v25.3 |

You provide one file yourself:

- **`inputs/keys/untrash-dev.sec`**: your secret key for signing system
  images.  Create a pair with `zt-sig`:

  ```
  gcc -O2 -Iuntrashos/third_party/tweetnacl -o zt-sig untrashos/slot/zt-sig.c untrashos/third_party/tweetnacl/tweetnacl.c
  ./zt-sig keygen inputs/keys/untrash-dev.sec untrashos/slot/keys/untrash-dev.pub
  ```

  The public key in `untrashos/slot/keys/` goes into loader and system; a NAS only
  accepts system images signed with a key it knows.

- Optional **`inputs/keys/untrash-release.sec`**: the release key.  When it is
  there, `make slot` signs with both keys: the first signature (dev key) is
  the one the installed loaders check, the second one is read by the Desk
  update and by newer loaders.  `ZT_SLOT_KEYS="a.sec b.sec"` sets the keys
  and their order explicitly.  Keep an offline copy of every secret key: a
  lost key cannot sign updates for the NAS that trust it.


Optional, only for `make test` (the PartnerKey dry runs are skipped without
them): `inputs/test/stock-env-mtd2.bin` (a stock Barebox environment dump),
`inputs/test/uImage-stock-kernel1` (a stock kernel) and
`inputs/test/stock-rootfs/` (the stock kernel's initramfs, extracted; the dry
runs execute the stock BusyBox under qemu-arm).  These contain data of one
device; keep them private.

## 3. Build

```
make inputs              # download + verify
make kernel              # build/kernel-system: zImage, DTB, modules
make busybox             # build/busybox: static BusyBox 1.37 for the loader (+ a PC build for tests)
make loader              # build/loader.uImage (NAND loader) + offline contract check
make rootfs              # build/image/untrash-rootfs: Debian 13 armhf
make slot RELEASE=1.0    # build/slot-1.0.img: erofs + dm-verity, signed
make update RELEASE=1.0  # build/untrash-1.0-update.utslot for Desk -> Updates
make stick RELEASE=1.0   # build/untrash-stick-1.0.img: installer stick for a new NAS
```

The release profile has no SSH host keys (the NAS creates its own), no
authorized keys, no self-signed TLS key and no developer address; the build
stops if a private key would end up in the image.  The loader has no network.

Reproducibility: the system kernel from `linux-6.6.145.tar.xz` +
`kernel/patches` + `kernel/config/system.config` is bit-identical to the
hardware-tested kernel (release string `6.6.145+`, fixed timestamps); so are
the helpers in `nas-tools/` (`zt-kexec` up to its build ID).  BusyBox builds
reproducibly too.  The loader contains only static programs built here.  The stick image is
bit-identical for equal inputs; the system image is not quite (random
dm-verity salt).

## 4. Tests

```
make test                                             # no root
make test-root TOOLROOT=<dir>                         # md/LVM/loop with sudo
make test-services APACHEROOT=<dir> RCLONEROOT=<dir>  # WebDAV (real Apache), cloud (real rclone)
```

`make test` covers the Barebox env generator, the PartnerKey dry runs, the
stock importer, `untrash-config`, the Desk API, export, broadcast channels, the
ad filter (real dnsmasq), the watchdog keeper, sounds and the translations.
`TOOLROOT`, `APACHEROOT` and `RCLONEROOT` are unpacked Debian packages
(`apt-get download` + `dpkg-deb -x`; nothing is installed).

**User guide.** `make manual` builds `docs/user-guide/manual.html` and the
PDF. The Desk screenshots (`docs/user-guide/img/d*.webp`) are made by
`python3 tools/manual/shoot.py [d03 d47 ...]`: it runs the Desk in its PC
test mode with example data only (stub `ip`, `systemctl`, `lsblk`, … so
nothing of the build PC appears) and drives a headless `chromium` over the
DevTools protocol. Re-run it after visible Desk changes, then `make manual`.
The first-setup and installer screenshots (`d00`, `i*`) are made by hand.

## 5. Layout

| Path | Content |
|---|---|
| `kernel/` | patch series for Linux 6.6.145, full configs (system, loader), build script |
| `loader/` | loader initramfs (`rc.ssh`, `zt-init.c`, module list) and its BusyBox config |
| `loader/slot/` | stage-1 loader `zt-loader`, `zt-blk.c` (md/LVM/dm), slot initrd `zt-slotinit.c`, tests |
| `board/nas542/` | board part of the system image: `board.conf`, `rootfs/` (power MCU, PFE firmware, bays, fan/PCIe units), `slot-hook.sh`, slot initrd builder, tests |
| `install/` | installer stick, PartnerKey hook, Barebox envfs, stock restore |
| `nas-tools/` | static helpers: fan, I2C, mount, blackbox, SMART |
| `tools/` | input fetcher, user guide builder, PFE and loader tools |
| `untrashos/` | UntrashOS (submodule): Desk, services, design system, translations, mkosi config, slot builder, slot signatures and keys (`untrashos/docs/board-interface.md`) |
| `docs/` | user guide, architecture, hardware reference |
| `build/`, `inputs/` | generated / external, not in git |

## 6. Publishing a release

Installed systems look for updates on the GitHub releases of this
repository (`board/nas542/rootfs/usr/share/untrash/board.json`):

1. `make stick update RELEASE=1.1`: the version is written into the slot
   manifest, signed with the dev key and, if present, the release key.
2. A GitHub release with the tag **`v1.1`** (the tag without `v` must be the
   `RELEASE` above, or the NAS refuses the image), with the assets
   `untrash-1.1-update.utslot` (the NAS takes the asset matching
   `untrash-*-update.utslot`) and the stick image.  Mark test versions as
   *pre-release*: only NAS on the beta channel take them.  Drafts are never
   offered.
3. The NAS finds it at its next daily check (or **Check now**), downloads and
   verifies it; an admin installs it.

The repository must be public for this; until then updates go by file.

## 7. Safety

The loader is written to NAND by the stock firmware (PartnerKey hook), only
after a full backup of the affected partitions onto the stick, and
`make check-loader` must pass first.  A loader built from this repository that
differs from the last hardware-tested one is a new candidate: test it on
hardware before it goes onto a release stick.
