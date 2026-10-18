#!/usr/bin/env bash
# Build the initramfs of the NAND loader (called by kernel/build-kernel.sh).
#   GEN=<gen_init_cpio> build-initramfs.sh MODDIR OUT
#
# Content: BusyBox 1.19 + glibc 2.20 of the stock firmware (inputs/loader-base.cpio,
# see docs/build.md), the static zt-init, rc.ssh,
# zt-loader + zt-blk + the slot signing public keys, the nas-tools and the
# kernel modules of MODDIR (loaded by rc.ssh, list loader/initramfs/modules.list).
# The release loader has no network, no SSH and no device MACs; rc.ssh then
# skips network and SSH.  ZT_LOADER_DIAG=1 (default) lets the loader copy its
# log onto an installer stick when no system was found.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MODDIR=${1:?module dir}; OUT=${2:?output cpio}
IN=$ROOT/inputs; NT=$ROOT/build/nas-tools; LDR=$ROOT/os/loader
BASE=$IN/loader-base.cpio
for f in "$BASE" "$NT/zt-mount"; do
	[[ -f $f ]] || { echo "missing $f (tools/fetch-inputs.sh, nas-tools/build.sh, docs/build.md)" >&2; exit 1; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
(cd "$W" && mkdir base && cd base && cpio -id --quiet --nonmatching "dev/*" <"$BASE")
arm-linux-gnueabihf-gcc -static -O2 -Wall -o "$W/zt-init" "$HERE/zt-init.c"
arm-linux-gnueabihf-strip "$W/zt-init"
arm-linux-gnueabihf-gcc -static -O2 -Wall -o "$W/zt-blk" "$LDR/zt-blk.c"
arm-linux-gnueabihf-strip "$W/zt-blk"
L="$W/list"
{
	for d in /bin /dev /etc /etc/dropbear /lib /lib/firmware /proc /run /sbin /sys /tmp /tmp/ubifs-ro \
		/usr /usr/bin /usr/sbin /var /var/log /var/run /root /root/.ssh; do
		m=755; [[ $d == /root || $d == /root/.ssh ]] && m=700; [[ $d == /tmp ]] && m=1777
		echo "dir $d $m 0 0"
	done
	echo "nod /dev/console 600 0 0 c 5 1"
	echo "nod /dev/null 666 0 0 c 1 3"
	echo "file /bin/busybox $W/base/bin/busybox 755 0 0"
	echo "slink /bin/sh /bin/busybox 777 0 0"
	# BusyBox 1.19.4 has no --install: link every applet at build time
	while read -r a; do echo "slink /bin/$a /bin/busybox 777 0 0"; done <"$HERE/busybox-1.19.4-applets.txt"
	for f in ld-2.20-2014.11.so libc-2.20-2014.11.so libm-2.20-2014.11.so; do
		echo "file /lib/$f $W/base/lib/$f 755 0 0"; done
	echo "slink /lib/ld-linux-armhf.so.3 /lib/ld-2.20-2014.11.so 777 0 0"
	echo "slink /lib/libc.so.6 /lib/libc-2.20-2014.11.so 777 0 0"
	echo "slink /lib/libm.so.6 /lib/libm-2.20-2014.11.so 777 0 0"
	# no PFE firmware: the release loader has no network (rc.ssh loads pfe.ko
	# only for a developer key), and nothing built in requests firmware
	echo "file /sbin/zt-poweroff $HERE/zt-poweroff 755 0 0"
	echo "slink /sbin/poweroff /bin/busybox 777 0 0"
	echo "slink /sbin/reboot /bin/busybox 777 0 0"
	echo "file /init $W/zt-init 755 0 0"
	echo "file /etc/rc.ssh $HERE/rc.ssh 755 0 0"
	printf 'root:x:0:0:root:/root:/bin/sh\n' >"$W/passwd"
	printf 'root:*:1::::::\n' >"$W/shadow"
	printf 'root:x:0:\ntty:x:5:\n' >"$W/group"
	printf '/bin/sh\n' >"$W/shells"
	printf 'zt542\n' >"$W/hostname"
	echo "file /etc/passwd $W/passwd 644 0 0"
	echo "file /etc/shadow $W/shadow 600 0 0"
	echo "file /etc/group $W/group 644 0 0"
	echo "file /etc/shells $W/shells 644 0 0"
	echo "file /etc/hostname $W/hostname 644 0 0"
	if [[ ${ZT_LOADER_DIAG:-1} = 1 ]]; then
		: >"$W/zt-loader-diag"
		echo "file /etc/zt-loader-diag $W/zt-loader-diag 644 0 0"
	fi
	# static NAS helpers (nas-tools/build.sh)
	for t in "$NT"/zt-*; do echo "file /bin/$(basename "$t") $t 755 0 0"; done
	# stage-1 loader, its md/LVM/dm/loop helper and the slot-signing public keys
	echo "file /bin/zt-loader $LDR/zt-loader 755 0 0"
	echo "file /bin/zt-blk $W/zt-blk 755 0 0"
	echo "dir /etc/untrash 755 0 0"
	for k in "$LDR"/keys/*.pub; do echo "file /etc/untrash/$(basename "$k") $k 644 0 0"; done
	echo "dir /lib/modules 755 0 0"
	echo "dir /lib/modules/zt 755 0 0"
	for m in "$MODDIR"/*.ko; do echo "file /lib/modules/zt/$(basename "$m") $m 644 0 0"; done
} >"$L"
"${GEN:?GEN=gen_init_cpio}" "$L" >"$OUT"
echo "INITRAMFS=$OUT $(sha256sum "$OUT" | cut -c1-16)"
