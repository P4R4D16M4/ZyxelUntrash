#!/usr/bin/env bash
# PC dry run of the PartnerKey (install/partnerkey/usb_key_func.sh) on
# simulated flash: "any stock NAS542" -> install -> way D -> stock, bit-exact.
#   install/test-partnerkey-dryrun.sh [ENV_DUMP] [STOCK_UIMAGE] [STOCK_ROOTFS]
# ENV_DUMP     real env (gitignored), only used through tests/mk-test-env.py
#              (fake MAC/serial/IPs; factory shape or the project's dev env)
# STOCK_UIMAGE a stock kernel uImage (inputs/test/uImage-stock-kernel1)
# STOCK_ROOTFS extracted stock kernel initramfs (inputs/test/stock-rootfs):
#              the script then runs under the STOCK BusyBox 1.19 ash and the
#              ARM ztpk under qemu-arm (binfmt), as on the NAS; without it,
#              under the host busybox and an x86 ztpk.
# flash_erase/nandwrite are fakes on files (NANDWRITE_CORRUPT: one bad write).
# ZT_STICK_IMG=<untrash-stick-*.img>: the stick content is taken out of the
# finished image (install/mk-stick-image.sh) instead of a fresh tree.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
ENV=${1:-$ROOT/inputs/test/stock-env-mtd2.bin}
UIMG=${2:-$ROOT/inputs/test/uImage-stock-kernel1}
SROOT=${3:-$ROOT/inputs/test/stock-rootfs}
for f in "$ENV" "$UIMG"; do [[ -f $f ]] || { echo "SKIP: $f missing"; exit 0; }; done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
sha() { sha256sum "$1" | cut -d' ' -f1; }
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fail=1; fi; }

# --- shell + ztpk: stock BusyBox under qemu, or host
mkdir -p "$W/bin"
if [[ -x $SROOT/bin/busybox ]] && [[ -e /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
	SYS="$W/sysroot"; mkdir -p "$SYS/lib" "$SYS/bin"
	python3 - "$SROOT" "$SYS" <<'E'
import os, shutil, sys
src, dst = sys.argv[1:]
for f in os.listdir(os.path.join(src, 'lib')):
    p = os.path.join(src, 'lib', f)
    if not os.path.isfile(p):
        continue
    b = open(p, 'rb').read()
    if b.startswith(b'SYMLINK -> '):   # extracted cpio symlink placeholders
        os.symlink(b[11:].split(b'\0')[0].decode(), os.path.join(dst, 'lib', f))
    else:
        shutil.copy(p, os.path.join(dst, 'lib', f))
shutil.copy(os.path.join(src, 'bin', 'busybox'), os.path.join(dst, 'bin', 'busybox'))
E
	export QEMU_LD_PREFIX="$SYS" QEMU_UNAME=3.2.54
	SH=("$SYS/bin/busybox" sh)
	for a in $("$SYS/bin/busybox" --list); do ln -s "$SYS/bin/busybox" "$W/bin/$a"; done
	arm-linux-gnueabihf-gcc -static -O2 -o "$W/ztpk" "$HERE/ztpk.c"
	echo "shell: stock BusyBox $("$SYS/bin/busybox" | head -1 | cut -d' ' -f2) (qemu-arm), ztpk ARM"
else
	SH=(busybox sh)
	gcc -O2 -o "$W/ztpk" "$HERE/ztpk.c"
	echo "shell: host busybox, ztpk x86 (no stock rootfs at $SROOT)"
fi
for t in mount umount; do rm -f "$W/bin/$t"; done
cat >"$W/bin/flash_erase" <<'E'
#!/bin/sh
s=$(stat -c %s "$1"); head -c "$s" /dev/zero | tr '\0' '\377' >"$1"
E
cat >"$W/bin/nandwrite" <<'E'
#!/bin/sh
[ "$1" = -p ] && shift
if [ -e "$NANDWRITE_CORRUPT" ] && [ "$(basename "$1")" = "$(cat "$NANDWRITE_CORRUPT")" ]; then
	rm -f "$NANDWRITE_CORRUPT"; printf 'garbage' | dd of="$1" conv=notrunc 2>/dev/null; exit 0; fi
dd if="$2" of="$1" conv=notrunc 2>/dev/null
E
cat >"$W/bin/nanddump" <<'E'
#!/bin/sh
# --quiet --oob --bb=dumpbad -f OUT DEV: data + 64 bytes 0xff OOB per 2 KiB page
while [ $# -gt 1 ]; do [ "$1" = -f ] && { o=$2; shift; }; shift; done
python3 -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(b''.join(d[i:i+2048]+b'\xff'*64 for i in range(0,len(d),2048)))" "$1" "$o"
E
chmod +x "$W/bin/flash_erase" "$W/bin/nandwrite" "$W/bin/nanddump"
cat >"$W/proc-mtd" <<'E'
dev:    size   erasesize  name
mtd0: 00040000 00010000 "uloader"
mtd1: 00080000 00010000 "barebox"
mtd2: 00040000 00010000 "env"
mtd3: 00a00000 00020000 "config"
mtd4: 00a00000 00020000 "kernel1"
mtd5: 06e00000 00020000 "rootfs1"
mtd6: 00a00000 00020000 "kernel2"
mtd7: 06e00000 00020000 "rootfs2"
mtd8: 00600000 00020000 "reserved"
E

# --- inputs: stick tree with a fake loader, stock kernels, envs
python3 -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(d+b'\xff'*(10485760-len(d)))" "$UIMG" "$W/kstock"
head -c 3000000 /dev/urandom >"$W/lpay"
mkimage -A arm -O linux -T kernel -C none -a 0x0f008000 -e 0x0f008000 -n "ZT TEST LOADER 1" -d "$W/lpay" "$W/loader1" >/dev/null
head -c 3100000 /dev/urandom >"$W/lpay"
mkimage -A arm -O linux -T kernel -C none -a 0x0f008000 -e 0x0f008000 -n "ZT TEST LOADER 2" -d "$W/lpay" "$W/loader2" >/dev/null
"$HERE/mk-partnerkey.sh" "$W/tree" "$W/loader1" test-1 >/dev/null
if [[ -n ${ZT_STICK_IMG:-} ]]; then
	rm -rf "$W/tree"; mkdir -p "$W/tree"
	MTOOLS_SKIP_CHECK=1 mcopy -s -n -i "$ZT_STICK_IMG@@33554432" "::*" "$W/tree/"
	(cd "$W/tree" && sha256sum -c --quiet SHA256SUMS) || { echo "stick image content does not verify"; exit 1; }
	sed -i 's/^VERSION=.*/VERSION=test-1/' "$W/tree/UNTRASH/manifest.env"	# messages below name test-1
	echo "stick content from $ZT_STICK_IMG ($(grep -c . "$W/tree/SHA256SUMS") files)"
	# the stick's own ARM ztpk (under qemu, like on the NAS)
	[[ ${SH[0]} == busybox ]] || { cp "$W/tree/UNTRASH/ztpk" "$W/ztpk"; chmod 755 "$W/ztpk"; echo "ztpk: the stick's binary"; }
fi
"$HERE/mk-partnerkey.sh" --update "$W/tree-upd" "$W/loader2" test-2 >/dev/null
MK() { python3 "$HERE/tests/mk-test-env.py" "$ENV" "$@" >/dev/null; }
MK "$W/env-stock1" --pristine --seed nas1
MK "$W/env-stock2" --pristine --curr 2 --next 2 --seed nas2
MK "$W/env-dev" --seed dev
MK "$W/env-pending" --pristine --curr 1 --next 2 --seed nas3
MK "$W/env-nas520" --pristine --curr 2 --next 2 --seed nas4 --model B203

setup() {	# $1 = env: fresh stock NAS + fresh stick
	rm -rf "$W/dev" "$W/key" "$W/once"; mkdir -p "$W/dev" "$W/key"
	head -c 262144 /dev/urandom >"$W/dev/mtd0"; head -c 524288 /dev/urandom >"$W/dev/mtd1"
	cp "$1" "$W/dev/mtd2"
	for n in 3 5 7; do head -c 1048576 /dev/urandom >"$W/dev/mtd$n"; done	# (shortened)
	head -c 1048576 /dev/urandom >"$W/dev/mtd8"
	cp "$W/kstock" "$W/dev/mtd4"
	# kernel2: an older stock firmware (different bytes, valid uImage)
	python3 -c "import sys; d=bytearray(open(sys.argv[1],'rb').read()); d[-1]=0xfe; open(sys.argv[2],'wb').write(d)" "$W/kstock" "$W/dev/mtd6"
	cp -r "$W/tree"/. "$W/key/"
}
run() {	# extra env assignments as arguments
	rm -f "$W/once"
	env "$@" UNTRASH_TEST_PATH="$W/bin" UNTRASH_TEST_KEY="$W/key" UNTRASH_TEST_DEV="$W/dev" \
		UNTRASH_TEST_PROCMTD="${PROCMTD:-$W/proc-mtd}" UNTRASH_TEST_ONCE="$W/once" UNTRASH_TEST_ZTPK="$W/ztpk" \
		UNTRASH_TEST_CFGDIR="${CFGDIR:-}" NANDWRITE_CORRUPT="$W/corrupt" \
		PATH="$W/bin:$PATH" "${SH[@]}" "$HERE/partnerkey/usb_key_func.sh" || true
}
marker() { cat "$W/key/UNTRASH/$1" 2>/dev/null || echo "(none)"; }
lastrun() { ls -d "$W"/key/UNTRASH/$1-* | tail -1; }
. "$W/tree/UNTRASH/manifest.env"; L1=$LOADER_SHA256

echo "1. stock NAS, slot 1 active (factory env, other MAC/serial)"
setup "$W/env-stock1"; k4=$(sha "$W/dev/mtd4"); k6=$(sha "$W/dev/mtd6"); e=$(sha "$W/dev/mtd2")
mkdir -p "$W/cfg"; echo db >"$W/cfg/ugs_conf.db"; CFGDIR="$W/cfg" run
d=$(lastrun install)
check "INSTALL_DONE" "$(marker INSTALL_DONE)" "loader in kernel2, UntrashOS env active"
check "kernel2 = loader" "$(sha "$W/dev/mtd6")" "$L1"
check "kernel1 (stock) untouched" "$(sha "$W/dev/mtd4")" "$k4"
python3 "$HERE/envfs.py" untrash "$W/env-stock1" "$W/want" >/dev/null
check "env = this NAS's UntrashOS env (as envfs.py builds it)" "$(sha "$W/dev/mtd2")" "$(sha "$W/want")"
check "device.env LOADER_SLOT" "$(sed -n 's/^LOADER_SLOT=//p' "$d/device.env")" 2
check "device.env ENV_OLD" "$(sed -n 's/^ENV_OLD_SHA256=//p' "$d/device.env")" "$e"
check "device.env KX_OLD" "$(sed -n 's/^KX_OLD_SHA256=//p' "$d/device.env")" "$k6"
check "device.env ETH0_MAC = this NAS's ethaddr" "$(sed -n 's/^ETH0_MAC=//p' "$d/device.env")" "$("$W/ztpk" env-get "$W/env-stock1" ethaddr)"
check "device.env ETH1_MAC = eth2addr" "$(sed -n 's/^ETH1_MAC=//p' "$d/device.env")" "$("$W/ztpk" env-get "$W/env-stock1" eth2addr)"
check "MAC is the scrubbed test value" "$(sed -n 's/^ETH0_MAC=//p' "$d/device.env" | cut -c1-8)" "02:5A:54"
check "device.env MODEL_ID = modelid_1 of the env" "$(sed -n 's/^MODEL_ID=//p' "$d/device.env")" "$("$W/ztpk" env-get "$W/env-stock1" modelid_1)"
check "device.env FWVERSION = fwversion_1 without parentheses" "$(sed -n 's/^FWVERSION=//p' "$d/device.env")" "$("$W/ztpk" env-get "$W/env-stock1" fwversion_1 | tr '(' . | tr -d ')')"
check "flash backup 9 files, re-read" "$(cat "$d/flash/VERIFIED" | cut -d' ' -f1)" "files=9"
check "backup env bit-exact" "$(cd "$d/flash" && sha256sum -c --quiet SHA256SUMS && sha mtd2.raw.bin)" "$e"
check "etc-zyxel.tar saved" "$(tar -tf "$d/etc-zyxel.tar" | grep -c 'ugs_conf.db$')" 1
echo "2. repeated run does nothing"
n=$(ls -d "$W"/key/UNTRASH/install-* | wc -l); run
check "no second install run" "$(ls -d "$W"/key/UNTRASH/install-* | wc -l)" "$n"
echo "3. way D: Barebox skipped the loader (stage 1, RAM mark), stock PartnerKey restores (stage 2)"
: >"$W/key/UNTRASH/ROLLBACK"; echo "stage1 x" >"$W/key/UNTRASH/rollback-stage1.log"; sleep 1; run
check "ROLLBACK_DONE" "$(marker ROLLBACK_DONE | cut -c1-30)" "stock env and kernel2 restored"
check "env = original" "$(sha "$W/dev/mtd2")" "$e"
check "kernel2 = original" "$(sha "$W/dev/mtd6")" "$k6"
check "kernel1 untouched" "$(sha "$W/dev/mtd4")" "$k4"

echo "4. stock NAS, slot 2 active -> loader in kernel1"
setup "$W/env-stock2"; k4=$(sha "$W/dev/mtd4"); k6=$(sha "$W/dev/mtd6"); e=$(sha "$W/dev/mtd2"); run
check "INSTALL_DONE" "$(marker INSTALL_DONE)" "loader in kernel1, UntrashOS env active"
check "kernel1 = loader" "$(sha "$W/dev/mtd4")" "$L1"
check "kernel2 (stock) untouched" "$(sha "$W/dev/mtd6")" "$k6"
echo "4b. NAS520 (model id B203), slot 2 active: same way, model recorded"
setup "$W/env-nas520"; k6=$(sha "$W/dev/mtd6"); run; d=$(lastrun install)
check "INSTALL_DONE" "$(marker INSTALL_DONE)" "loader in kernel1, UntrashOS env active"
check "kernel2 (stock) untouched" "$(sha "$W/dev/mtd6")" "$k6"
check "device.env MODEL_ID" "$(sed -n 's/^MODEL_ID=//p' "$d/device.env")" "B203"
check "device.env FWVERSION is an AASZ firmware" "$(sed -n 's/^FWVERSION=V[0-9]*\.[0-9]*\.\([A-Z]*\)\..*/\1/p' "$d/device.env")" "AASZ"
setup "$W/env-stock2"; run
echo "5. update of the loader (installed NAS from 4)"
cp "$W/tree-upd/UNTRASH/"{manifest.env,loader.uImage} "$W/key/UNTRASH/"; ecur=$(sha "$W/dev/mtd2"); sleep 1; run
. "$W/tree-upd/UNTRASH/manifest.env"
check "UPDATE_DONE" "$(marker UPDATE_DONE)" "loader in kernel1 updated (test-2), env unchanged"
check "kernel1 = new loader" "$(sha "$W/dev/mtd4")" "$LOADER_SHA256"
check "env unchanged" "$(sha "$W/dev/mtd2")" "$ecur"
echo "6. rollback after the update -> stock"
sed -i '/^UPDATE=/d' "$W/key/UNTRASH/manifest.env"; : >"$W/key/UNTRASH/ROLLBACK"; sleep 1; run
check "ROLLBACK_DONE" "$(marker ROLLBACK_DONE | cut -c1-30)" "stock env and kernel1 restored"
check "env = original" "$(sha "$W/dev/mtd2")" "$e"
check "kernel1 = original" "$(sha "$W/dev/mtd4")" "$k4"

echo "7. project dev env (TFTP V6, our NAS after way D)"
setup "$W/env-dev"; run
check "INSTALL_DONE" "$(marker INSTALL_DONE)" "loader in kernel2, UntrashOS env active"
python3 "$HERE/envfs.py" untrash "$W/env-dev" "$W/want" >/dev/null
check "env = dev env + loader on TFTP failure" "$(sha "$W/dev/mtd2")" "$(sha "$W/want")"

echo "8. refusals write nothing"
for c in pending layout kernel installed; do
	case $c in
	pending) setup "$W/env-pending"; want="stock firmware slot switch pending" ;;
	layout) setup "$W/env-stock1"; sed 's/06e00000 00020000 "rootfs2"/06000000 00020000 "rootfs2"/' "$W/proc-mtd" >"$W/proc-mtd2"
		want="flash layout is not the NAS542 stock layout" ;;
	kernel) setup "$W/env-stock1"; printf 'XX' | dd of="$W/dev/mtd4" bs=1 seek=5000 conv=notrunc status=none
		want="active stock kernel1 is no valid uImage" ;;
	installed) setup "$W/env-stock1"; python3 "$HERE/envfs.py" untrash "$W/env-stock1" "$W/dev/mtd2" >/dev/null
		want="cannot build the UntrashOS env: REFUSED env already" ;;
	esac
	before=$(cat "$W"/dev/mtd* | sha256sum)
	if [[ $c == layout ]]; then PROCMTD="$W/proc-mtd2" run; else run; fi
	check "$c: INSTALL_FAILED" "$(marker INSTALL_FAILED | cut -c1-${#want})" "$want"
	check "$c: flash unchanged" "$(cat "$W"/dev/mtd* | sha256sum)" "$before"
done
echo "9. bad write -> restored"
for t in mtd6 mtd2; do
	setup "$W/env-stock1"; before=$(cat "$W"/dev/mtd* | sha256sum); echo $t >"$W/corrupt"; run
	check "$t: INSTALL_FAILED" "$(marker INSTALL_FAILED | cut -c1-15)" "$([[ $t == mtd6 ]] && echo 'kernel2 write/v' || echo 'env write/verif')"
	check "$t: flash = before" "$(cat "$W"/dev/mtd* | sha256sum)" "$before"
done
echo "10. tampered loader on the stick -> nothing written"
setup "$W/env-stock1"; printf x | dd of="$W/key/UNTRASH/loader.uImage" bs=1 seek=9000000 conv=notrunc status=none
before=$(cat "$W"/dev/mtd* | sha256sum); run
check "INSTALL_FAILED" "$(marker INSTALL_FAILED)" "loader.uImage hash mismatch"
check "flash unchanged" "$(cat "$W"/dev/mtd* | sha256sum)" "$before"
echo "11. loader update on an installed NAS via the way-D trigger (ROLLBACK + UPDATE=1)"
setup "$W/env-stock1"; run
e1=$(sha "$W/dev/mtd2"); k4=$(sha "$W/dev/mtd4")
cp "$W/tree-upd/UNTRASH/"{manifest.env,loader.uImage} "$W/key/UNTRASH/"
: >"$W/key/UNTRASH/ROLLBACK"; echo "stage1 x" >"$W/key/UNTRASH/rollback-stage1.log"; sleep 1; run
. "$W/tree-upd/UNTRASH/manifest.env"
check "UPDATE_DONE (not a rollback)" "$(marker UPDATE_DONE)" "loader in kernel2 updated (test-2), env unchanged"
check "no ROLLBACK_DONE" "$(marker ROLLBACK_DONE)" "(none)"
check "kernel2 = new loader" "$(sha "$W/dev/mtd6")" "$LOADER_SHA256"
check "env unchanged" "$(sha "$W/dev/mtd2")" "$e1"
check "kernel1 untouched" "$(sha "$W/dev/mtd4")" "$k4"
check "ROLLBACK trigger removed" "$([ -e "$W/key/UNTRASH/ROLLBACK" ] || [ -e "$W/key/UNTRASH/rollback-stage1.log" ] && echo left || echo gone)" "gone"
((fail == 0)) && echo "ALL_OK" || { echo "FAILED"; exit 1; }
