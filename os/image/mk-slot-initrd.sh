#!/usr/bin/env bash
# Build the slot initrd (boots a slot from a file on a stick or a stock volume).
#   mk-slot-initrd.sh MODDIR OUT.cpio.gz
# MODDIR = lib/modules/<release> of the slot kernel (modules-staging of
# tools/zt-build-system-kernel.sh).  Content: /init = os/loader/zt-slotinit
# (static), /bin/zt-blackbox (USB boot log), the modules for md/LVM/loop/FAT
# and the watchdog, and
# /lib/modules/load.list (dependency order; "@watchdog" = start feeding).
# Storage drivers (SoC AHCI, USB, sd, dm, ext4, erofs) are built into the
# kernel; PCIe + PCI AHCI (bays 2/4) are modules loaded here.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
MODS=${1:?moddir}; OUT=${2:?out}
GEN="$ROOT/build/gen_init_cpio"
[ -x "$GEN" ] || gcc -O2 -o "$GEN" "$ROOT/build/linux-6.6.145/usr/gen_init_cpio.c"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
arm-linux-gnueabihf-gcc -static -O2 -Wall -Wno-unused-function -Wno-format-truncation \
	-o "$W/init" "$ROOT/os/loader/zt-slotinit.c"
arm-linux-gnueabihf-strip "$W/init"

# modules in dependency order (modules.dep: "path: dep dep ...")
declare -A seen
ORDER=()
add() {	# $1 = module path relative to MODDIR
	[[ -n "${seen[$1]:-}" ]] && return; seen[$1]=1
	local d
	for d in $(sed -n "s#^$1: *##p" "$MODS/modules.dep"); do add "$d"; done
	ORDER+=("$1")
}
mod() { local p; p=$(grep -o "^[^:]*/$1\.ko[^:]*" "$MODS/modules.dep" | head -1)
	[[ -n "$p" ]] || { echo "module $1 missing" >&2; exit 1; }; add "$p"; }
mod watchdog; mod ls1024a_wdt
NWDT=${#ORDER[@]}
# nls_utf8: the system kernel mounts FAT with FAT_DEFAULT_IOCHARSET="utf8"
for m in md-mod linear raid0 raid1 raid10 raid456 loop fat vfat nls_cp437 nls_iso8859-1 nls_utf8; do mod "$m"; done
# Bays 2 and 4 sit behind the ASM1061 (PCIe x1 AHCI): a stock array over
# four disks only assembles once it is up.  SoC AHCI and the SerDes PHY are
# built in; the system's untrash-pcie.service then finds both loaded.
for m in pcie-ls1024a ahci; do mod "$m"; done

{
	for d in /dev /proc /sys /run /lib /lib/modules /host /newroot; do echo "dir $d 755 0 0"; done
	echo "nod /dev/console 600 0 0 c 5 1"
	echo "nod /dev/kmsg 644 0 0 c 1 11"
	echo "file /init $W/init 755 0 0"
	echo "dir /bin 755 0 0"
	echo "file /bin/zt-blackbox $ROOT/build/nas-tools/zt-blackbox 755 0 0"
	for p in "${ORDER[@]}"; do
		b=$(basename "$p"); b=${b%.xz}; b=${b%.gz}
		case $p in *.xz) xz -dc "$MODS/$p" >"$W/$b" ;; *.gz) gzip -dc "$MODS/$p" >"$W/$b" ;; *) cp "$MODS/$p" "$W/$b" ;; esac
		echo "file /lib/modules/$b $W/$b 644 0 0"
	done
	echo "file /lib/modules/load.list $W/load.list 644 0 0"
} >"$W/list"
i=0
for p in "${ORDER[@]}"; do
	b=$(basename "$p"); echo "/lib/modules/${b%.[gx]z}"
	i=$((i + 1)); [[ $i == "$NWDT" ]] && echo "@watchdog"
done >"$W/load.list"
"$GEN" "$W/list" | gzip -9n >"$OUT"
echo "INITRD=$OUT $(stat -c %s "$OUT") bytes sha256 $(sha256sum "$OUT" | cut -c1-16)"
sed 's/^/  /' "$W/load.list"
