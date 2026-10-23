#!/usr/bin/env bash
# Build the initramfs of the NAND loader (called by kernel/build-kernel.sh).
#   GEN=<gen_init_cpio> build-initramfs.sh MODDIR OUT
#
# Content: a static BusyBox 1.37 (loader/busybox/build.sh), the static zt-init, rc.ssh,
# zt-loader + zt-blk + the slot signing public keys, the nas-tools and the
# kernel modules of MODDIR (loaded by rc.ssh, list loader/initramfs/modules.list).
# The release loader has no network, no SSH and no device MACs; rc.ssh then
# skips network and SSH.  ZT_LOADER_DIAG=1 (default) lets the loader copy its
# log onto an installer stick when no system was found.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MODDIR=${1:?module dir}; OUT=${2:?output cpio}
IN=$ROOT/inputs; NT=$ROOT/build/nas-tools; LDR=$ROOT/loader/slot
BB=$ROOT/build/busybox
for f in "$BB/arm/busybox" "$BB/applets.txt" "$NT/zt-mount"; do
	[[ -f $f ]] || { echo "missing $f (loader/busybox/build.sh, nas-tools/build.sh)" >&2; exit 1; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
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
	echo "file /bin/busybox $BB/arm/busybox 755 0 0"
	echo "slink /bin/sh /bin/busybox 777 0 0"
	# every applet as a link in /bin (as with the stock BusyBox before)
	while read -r a; do
		case $a in sh|poweroff|reboot) continue ;; esac
		echo "slink /bin/$a /bin/busybox 777 0 0"
	done <"$BB/applets.txt"
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
	for k in "$ROOT"/untrashos/slot/keys/*.pub; do echo "file /etc/untrash/$(basename "$k") $k 644 0 0"; done
	echo "dir /lib/modules 755 0 0"
	echo "dir /lib/modules/zt 755 0 0"
	for m in "$MODDIR"/*.ko; do echo "file /lib/modules/zt/$(basename "$m") $m 644 0 0"; done
} >"$L"
# reproducible archive: every entry gets the mtime SOURCE_DATE_EPOCH (kernel
# build: 0).  gen_init_cpio -t covers dirs, nodes and links; regular files keep
# the mtime of their source, so they go in as copies stamped with that time.
EPOCH=${SOURCE_DATE_EPOCH:-0}
mkdir "$W/stage"; n=0
while read -r t name src rest; do
	if [[ $t == file ]]; then
		n=$((n + 1)); cp "$src" "$W/stage/$n"; touch -d "@$EPOCH" "$W/stage/$n"
		src=$W/stage/$n
	fi
	echo "$t $name $src $rest"
done <"$L" >"$L.repro"
"${GEN:?GEN=gen_init_cpio}" -t "$EPOCH" "$L.repro" >"$OUT"
echo "INITRAMFS=$OUT $(sha256sum "$OUT" | cut -c1-16)"
