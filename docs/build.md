# Building UntrashOS

UntrashOS is built on a Debian/Ubuntu PC (x86-64) for the NAS542 (ARMv7).
Everything comes from this repository plus a few external inputs that are
downloaded from their official sources or that you provide yourself.  Nothing
proprietary is stored in the repository.

## 1. Tools

```
sudo apt install build-essential gcc-arm-linux-gnueabihf bc bison flex libssl-dev \
  u-boot-tools erofs-utils cryptsetup-bin fakeroot dosfstools mtools gdisk cpio \
  python3 python3-pil git curl xz-utils qemu-user-static binfmt-support dnsmasq-base
```

`mkosi` (v25.3, rootfs builder) is fetched by `make inputs`.

## 2. External inputs (`inputs/`, never committed)

`make inputs` (`tools/fetch-inputs.sh`) downloads them and checks fixed SHA-256 sums:

| File | Source |
|---|---|
| `inputs/src/linux-6.6.145.tar.xz` | kernel.org |
| `inputs/src/kexec-tools-2.0.31.tar.xz` | kernel.org |
| `inputs/pfe-firmware/*_c2000*.elf` | network engine (PFE) firmware, pfe_13 set, from github.com/scpcom/linux (branch `ls1024a-6.1.y`, pinned commit). NXP/Freescale firmware without a stated license: you download it, this project does not redistribute it. It ends up in the system image only. |
| `inputs/mkosi/` | github.com/systemd/mkosi, v25.3 |

You provide two files yourself:

- **`inputs/keys/untrash-dev.sec`**: your secret key for signing system
  images.  Create a pair with `zt-sig`:

  ```
  gcc -O2 -Ithird_party/tweetnacl -o zt-sig os/loader/zt-sig.c third_party/tweetnacl/tweetnacl.c
  ./zt-sig keygen inputs/keys/untrash-dev.sec os/loader/keys/untrash-dev.pub
  ```

  The public key in `os/loader/keys/` goes into loader and system; a NAS only
  accepts system images signed with a key it knows.

- **`inputs/loader-base.cpio`**: BusyBox 1.19.4 and glibc 2.20 of the stock
  Zyxel firmware (GPL/LGPL).  The loader's initramfs is built on top of them.
  Extract `/bin/busybox` and `/lib/{ld,libc,libm}-2.20-2014.11.so` from the
  stock root file system (UBI volume `rootfs` in NAND `rootfs1`, or the
  official firmware download) into a newc cpio with these paths.  Replacing
  this base with a BusyBox built from source is an open task.

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
make loader              # build/loader.uImage (NAND loader) + offline contract check
make rootfs              # build/image/untrash-rootfs: Debian 13 armhf
make slot RELEASE=r1     # build/slot-r1.img: erofs + dm-verity, signed
make update RELEASE=r1   # build/untrash-r1-update.utslot for Desk -> Updates
make stick RELEASE=r1    # build/untrash-stick-r1.img: installer stick for a new NAS
```

The release profile has no SSH host keys (the NAS creates its own), no
authorized keys, no self-signed TLS key and no developer address; the build
stops if a private key would end up in the image.  The loader has no network.

Reproducibility: the system kernel from `linux-6.6.145.tar.xz` +
`kernel/patches` + `kernel/config/system.config` is bit-identical to the
hardware-tested kernel (release string `6.6.145+`, fixed timestamps); so are
the helpers in `nas-tools/` (`zt-kexec` up to its build ID).  The stick image is
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

## 5. Layout

| Path | Content |
|---|---|
| `kernel/` | patch series for Linux 6.6.145, full configs (system, loader), build script |
| `loader/` | loader initramfs: `rc.ssh`, `zt-init.c`, module list, build script |
| `os/loader/` | stage-1 loader `zt-loader`, `zt-blk.c` (md/LVM/dm), `zt-sig.c` (Ed25519), public keys, tests |
| `os/image/` | system image: mkosi config, `untrash-files/` (Desk, services, tools), slot builder, tests |
| `os/install/` | installer stick, PartnerKey hook, Barebox envfs, stock restore |
| `os/design/` | design system, icons, translations (DE/EN/FR) |
| `nas-tools/` | static helpers: fan, I2C, mount, blackbox, SMART |
| `tools/` | input fetcher, translations, user guide builder, loader cpio tool |
| `docs/` | user guide, architecture, hardware reference |
| `build/`, `inputs/` | generated / external, not in git |

## 6. Safety

The loader is written to NAND by the stock firmware (PartnerKey hook), only
after a full backup of the affected partitions onto the stick, and
`make check-loader` must pass first.  A loader built from this repository that
differs from the last hardware-tested one is a new candidate: test it on
hardware before it goes onto a release stick.
