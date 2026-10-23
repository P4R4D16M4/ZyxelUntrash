#!/usr/bin/env bash
# BusyBox 1.37.0 for the loader, static, from busybox.net source (inputs/src,
# tools/fetch-inputs.sh) with loader/busybox/busybox-1.37.0.config.  The applet
# set is the one of the stock BusyBox 1.19.4 the loader used before (minus
# catv, now "cat -v"); passwd/group are parsed by BusyBox itself, so the
# static binary needs no glibc NSS modules.
#   build/busybox/arm/busybox    for the loader initramfs
#   build/busybox/host/busybox   same config for the PC tests (loader/slot/tests)
#   build/busybox/applets.txt    applet list (initramfs links, tests)
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export SOURCE_DATE_EPOCH=1767225600 TZ=UTC     # fixed banner date: reproducible
T=$ROOT/inputs/src/busybox-1.37.0.tar.bz2
[[ -f $T ]] || { echo "missing $T (tools/fetch-inputs.sh)" >&2; exit 1; }
O=$ROOT/build/busybox; mkdir -p "$O"
CFG=$ROOT/loader/busybox/busybox-1.37.0.config
STAMP=$(sha256sum "$CFG" "$T" | sha256sum | cut -c1-16)
[[ -f $O/.stamp && $(cat "$O/.stamp") == "$STAMP" && -x $O/arm/busybox ]] && exit 0
for kind in arm host; do
	S=$O/src-$kind; rm -rf "$S"; mkdir -p "$S" "$O/$kind"
	tar -C "$S" --strip-components=1 -xjf "$T"
	cp "$CFG" "$S/.config"
	cc=; [[ $kind == arm ]] && cc=arm-linux-gnueabihf-
	# "yes" dies of SIGPIPE when oldconfig is done: not an error
	(cd "$S" && set +o pipefail && yes "" | make -s oldconfig CROSS_COMPILE=$cc >/dev/null 2>&1)
	(cd "$S" && make -s -j"$(nproc)" CROSS_COMPILE=$cc >/dev/null 2>&1)
	cp "$S/busybox" "$O/$kind/busybox"
	"${cc}strip" "$O/$kind/busybox"
done
"$O/host/busybox" --list | sort >"$O/applets.txt"
echo "$STAMP" >"$O/.stamp"
echo "BUSYBOX=$O/arm/busybox $(wc -l <"$O/applets.txt") applets"
