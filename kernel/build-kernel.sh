#!/usr/bin/env bash
# Build the NAS542 kernels from linux-6.6.145 (kernel.org) + kernel/patches.
#
#   kernel/build-kernel.sh system           slot kernel, modules, DTB
#                                           -> build/kernel-system/
#   kernel/build-kernel.sh loader           NAND loader: kernel + embedded
#                                           initramfs (loader/initramfs) + DTB
#                                           -> build/loader.uImage
#
# Inputs (tools/fetch-inputs.sh): inputs/src/linux-6.6.145.tar.xz; for the
# loader also inputs/loader-base.cpio and build/nas-tools/ (nas-tools/build.sh).
# Contract (docs/hardware/README.md, traps): ARCH=arm, ZRELADDR=0x04008000,
# uImage load/entry 0x0f008000, never CONFIG_AUTO_ZRELADDR.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KIND=${1:?system|loader}
KVER=6.6.145
B=$ROOT/build; IN=$ROOT/inputs
SRC=$B/linux-$KVER
O=$B/kernel-$KIND
MK=(make -C "$SRC" O="$O" LOCALVERSION="${ZT_LOCALVERSION-+}" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- ZRELADDR=0x04008000 -j"$(nproc)")
# "+" = the release string 6.6.145+ (as built in a git tree); with it the
# build is reproducible bit for bit.
export TZ=UTC KBUILD_BUILD_USER=zt KBUILD_BUILD_HOST=zt KBUILD_BUILD_VERSION=1
if [[ $KIND == system ]]; then
	export SOURCE_DATE_EPOCH=1767225600 KBUILD_BUILD_TIMESTAMP="2026-01-01 00:00:00 UTC"
else
	export SOURCE_DATE_EPOCH=0 KBUILD_BUILD_TIMESTAMP="1970-01-01"
fi

# source tree: tarball + patch series (re-created when the series changes)
SERIES=$(cat "$ROOT"/kernel/patches/*.patch | sha256sum | cut -c1-16)
if [[ ! -f $SRC/.untrash-series || $(cat "$SRC/.untrash-series") != "$SERIES" ]]; then
	T=$IN/src/linux-$KVER.tar.xz
	[[ -f $T ]] || { echo "missing $T (tools/fetch-inputs.sh)" >&2; exit 1; }
	rm -rf "$SRC"; mkdir -p "$B"
	tar -C "$B" -xf "$T"
	for p in "$ROOT"/kernel/patches/*.patch; do
		patch -d "$SRC" -p1 --quiet --forward <"$p" || { echo "patch failed: $p" >&2; exit 1; }
	done
	echo "$SERIES" >"$SRC/.untrash-series"
fi

mkdir -p "$O"
cp "$ROOT/kernel/config/$KIND.config" "$O/.config"
DTB=$O/arch/arm/boot/dts/mindspeed/zyxel-nas542.dtb
if [[ $KIND == loader ]]; then
	# pass 1 builds the modules the initramfs carries; pass 2 embeds it
	"$SRC/scripts/config" --file "$O/.config" --set-str INITRAMFS_SOURCE ""
fi
"${MK[@]}" olddefconfig >/dev/null
grep -q '^CONFIG_AUTO_ZRELADDR=y' "$O/.config" && { echo "CONFIG_AUTO_ZRELADDR must stay off" >&2; exit 1; }
"${MK[@]}" zImage modules dtbs >/dev/null </dev/null

if [[ $KIND == system ]]; then
	rm -rf "$O/modules-staging"
	"${MK[@]}" INSTALL_MOD_PATH="$O/modules-staging" INSTALL_MOD_STRIP=1 modules_install >/dev/null
else
	MODDIR=$(mktemp -d); trap 'rm -rf "$MODDIR"' EXIT
	while read -r m; do
		[[ -z $m || $m == \#* ]] && continue
		f=$(find "$O" -name "$m.ko" -print -quit)
		[[ -n $f ]] || { echo "module missing: $m" >&2; exit 1; }
		arm-linux-gnueabihf-strip --strip-debug -o "$MODDIR/$m.ko" "$f"
	done <"$ROOT/loader/initramfs/modules.list"
	CPIO=$B/loader-initramfs.cpio
	gcc -O2 -o "$B/gen_init_cpio" "$SRC/usr/gen_init_cpio.c"
	GEN=$B/gen_init_cpio "$ROOT/loader/initramfs/build-initramfs.sh" "$MODDIR" "$CPIO"
	"$SRC/scripts/config" --file "$O/.config" --set-str INITRAMFS_SOURCE "$CPIO"
	"${MK[@]}" olddefconfig >/dev/null      # new INITRAMFS_* symbols, never ask
	"${MK[@]}" zImage >/dev/null </dev/null
	cat "$O/arch/arm/boot/zImage" "$DTB" >"$O/zImage-dtb"
	mkimage -A arm -O linux -T kernel -C none -a 0x0f008000 -e 0x0f008000 \
		-n "ZT UNTRASHOS LOADER" -d "$O/zImage-dtb" "$B/loader.uImage" >/dev/null
	echo "UIMAGE=$B/loader.uImage $(sha256sum "$B/loader.uImage" | cut -c1-16)"
fi
grep -q -- '--defsym zreladdr=0x04008000' "$O/arch/arm/boot/compressed/.vmlinux.cmd" ||
	{ echo "zreladdr is not 0x04008000" >&2; exit 1; }
echo "KERNEL=$(strings "$O/vmlinux" | grep -m1 '^Linux version')"
