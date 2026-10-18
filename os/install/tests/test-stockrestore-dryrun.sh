#!/usr/bin/env bash
# PC dry run: development NAS (env V7, loader in kernel2) -> stock via the
# PartnerKey rollback with a prepared rollback source -> fresh install from a
# release stick, as on any stock NAS542.  Real usb_key_func.sh under the stock
# BusyBox 1.19 (qemu-arm) with the stick's ARM ztpk; flash = files.
#   test-stockrestore-dryrun.sh STICK_UNTRASH_DIR RESTORE_SRC_DIR ENV_CUR K1_CUR K2_CUR NEW_LOADER
# STICK_UNTRASH_DIR  UNTRASH/ of the stick (manifest.env, ztpk, install-*)
# RESTORE_SRC_DIR    install-<stamp>-stockrestore (device.env, mtd2/mtd6-before-a.bin)
# ENV_CUR/K1_CUR/K2_CUR  the NAS's current env, kernel1, kernel2 (backups)
# NEW_LOADER         loader uImage for the release-stick install (step 3)
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$HERE/../.." && pwd)
SU=${1:?stick UNTRASH dir}; SRC=${2:?restore source}; ENVC=${3:?}; K1C=${4:?}; K2C=${5:?}; NL=${6:?}
SROOT=$ROOT/inputs/test/stock-rootfs
[[ -x $SROOT/bin/busybox && -e /proc/sys/fs/binfmt_misc/qemu-arm ]] || { echo "SKIP: stock BusyBox or qemu-arm binfmt missing"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
sha() { sha256sum "$1" | cut -d' ' -f1; }
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fail=1; fi; }

SYS="$W/sysroot"; mkdir -p "$SYS/lib" "$SYS/bin" "$W/bin"
python3 - "$SROOT" "$SYS" <<'E'
import os, shutil, sys
src, dst = sys.argv[1:]
for f in os.listdir(os.path.join(src, 'lib')):
    p = os.path.join(src, 'lib', f)
    if not os.path.isfile(p): continue
    b = open(p, 'rb').read()
    if b.startswith(b'SYMLINK -> '): os.symlink(b[11:].split(b'\0')[0].decode(), os.path.join(dst, 'lib', f))
    else: shutil.copy(p, os.path.join(dst, 'lib', f))
shutil.copy(os.path.join(src, 'bin', 'busybox'), os.path.join(dst, 'bin', 'busybox'))
E
export QEMU_LD_PREFIX="$SYS" QEMU_UNAME=3.2.54
SH=("$SYS/bin/busybox" sh)
for a in $("$SYS/bin/busybox" --list); do ln -s "$SYS/bin/busybox" "$W/bin/$a"; done
for t in mount umount; do rm -f "$W/bin/$t"; done
cat >"$W/bin/flash_erase" <<'E'
#!/bin/sh
s=$(stat -c %s "$1"); head -c "$s" /dev/zero | tr '\0' '\377' >"$1"
E
cat >"$W/bin/nandwrite" <<'E'
#!/bin/sh
[ "$1" = -p ] && shift
dd if="$2" of="$1" conv=notrunc 2>/dev/null
E
cat >"$W/bin/nanddump" <<'E'
#!/bin/sh
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
cp "$SU/ztpk" "$W/ztpk"; chmod 755 "$W/ztpk"
run() {
	rm -f "$W/once"
	env UNTRASH_TEST_PATH="$W/bin" UNTRASH_TEST_KEY="$W/key" UNTRASH_TEST_DEV="$W/dev" \
		UNTRASH_TEST_PROCMTD="$W/proc-mtd" UNTRASH_TEST_ONCE="$W/once" UNTRASH_TEST_ZTPK="$W/ztpk" \
		PATH="$W/bin:$PATH" "${SH[@]}" "$W/key/usb_key_func.sh" || true
}
marker() { cat "$W/key/UNTRASH/$1" 2>/dev/null || echo "(none)"; }

# --- the NAS today
mkdir -p "$W/dev"
head -c 262144 /dev/urandom >"$W/dev/mtd0"; head -c 524288 /dev/urandom >"$W/dev/mtd1"
cp "$ENVC" "$W/dev/mtd2"; cp "$K1C" "$W/dev/mtd4"; cp "$K2C" "$W/dev/mtd6"
for n in 3 5 7 8; do head -c 1048576 /dev/urandom >"$W/dev/mtd$n"; done
k1=$(sha "$W/dev/mtd4")
# --- rollback stick: current stick tree + restore source + ROLLBACK
mkdir -p "$W/key/UNTRASH"
cp "$ROOT/os/install/partnerkey/usb_key_func.sh" "$W/key/"
cp "$SU/manifest.env" "$SU/ztpk" "$W/key/UNTRASH/"
for d in "$SU"/install-*; do mkdir -p "$W/key/UNTRASH/${d##*/}"; cp "$d"/device.env "$d"/install.log "$d"/mtd*-before-a.bin "$W/key/UNTRASH/${d##*/}/"; done
cp -r "$SRC" "$W/key/UNTRASH/"
: >"$W/key/UNTRASH/ROLLBACK"

echo "1. rollback with the stock-restore source"
run
log=$(ls -d "$W"/key/UNTRASH/rollback-* | tail -1)/install.log
check "ROLLBACK_DONE" "$(marker ROLLBACK_DONE)" "stock env and kernel2 restored from ${SRC##*/}"
check "source chosen" "$(grep -o 'rollback source [^:]*' "$log" | sed 's|.*/||')" "${SRC##*/}"
check "env = stock env" "$(sha "$W/dev/mtd2")" "$(sha "$SRC/mtd2-before-a.bin")"
check "kernel2 = stock kernel2" "$(sha "$W/dev/mtd6")" "$(sha "$SRC/mtd6-before-a.bin")"
check "kernel1 untouched" "$(sha "$W/dev/mtd4")" "$k1"
check "flash backup of the rollback run verified" "$(cut -d' ' -f1 "${log%/*}/flash/VERIFIED")" "files=9"
check "env passes ztpk env-check" "$("$W/ztpk" env-check "$W/dev/mtd2" | cut -c1-2)" "OK"
check "stock slot settled (curr=next=1)" "$("$W/ztpk" env-get "$W/dev/mtd2" curr_bootfrom)$("$W/ztpk" env-get "$W/dev/mtd2" next_bootfrom)" "11"
echo "2. repeated run does nothing"
before=$(cat "$W"/dev/mtd* | sha256sum); run
check "flash unchanged" "$(cat "$W"/dev/mtd* | sha256sum)" "$before"

echo "3. release stick on the restored NAS (like any stock NAS542)"
rm -rf "$W/key"; "$HERE/mk-partnerkey.sh" "$W/key" "$NL" release-test >/dev/null
cp "$W/key/UNTRASH/ztpk" "$W/ztpk"; chmod 755 "$W/ztpk"
e0=$(sha "$W/dev/mtd2"); k2=$(sha "$W/dev/mtd6"); run
. "$W/key/UNTRASH/manifest.env"
d=$(ls -d "$W"/key/UNTRASH/install-* | tail -1)
check "INSTALL_DONE" "$(marker INSTALL_DONE)" "loader in kernel2, UntrashOS env active"
check "kernel2 = new loader" "$(sha "$W/dev/mtd6")" "$LOADER_SHA256"
check "kernel1 untouched" "$(sha "$W/dev/mtd4")" "$k1"
python3 "$HERE/envfs.py" untrash "$SRC/mtd2-before-a.bin" "$W/want" >/dev/null
check "env = stock env + /bin/untrash_loader" "$(sha "$W/dev/mtd2")" "$(sha "$W/want")"
check "device.env ENV_OLD = stock env" "$(sed -n 's/^ENV_OLD_SHA256=//p' "$d/device.env")" "$e0"
check "device.env KX_OLD = stock kernel2" "$(sed -n 's/^KX_OLD_SHA256=//p' "$d/device.env")" "$k2"
[[ $fail = 0 ]] && echo "ALL_OK" || { echo "FAILED"; exit 1; }
