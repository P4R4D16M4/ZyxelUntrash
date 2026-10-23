#!/usr/bin/env bash
# PC end-to-end test of installer ways B, C and A, as root:
#   sudo test-installer-keep-host.sh TOOLROOT
# TOOLROOT: extracted Debian mdadm/lvm2/dmsetup debs (loader/slot/tests/test-zt-blk-host.sh).
# Runs in a private mount namespace.  A synthetic stock disk (GPT p1/p2/p3,
# md raid1 "basic" on p3, LVM vg_<uuid8> with vg_info_area and lv_<id>, stock
# mkfs flags, sysvol marker, data) and a test stick directory (signed mini
# slot.utslot, INSTALL marker, stock ugs_conf.db) go through the real
# untrash-installer HTTP API (plan -> start "KEEP" -> job done).  Checks:
# /.untrash content (both slots byte-identical to the stick, state.img, swap
# signature, bootstate, stock-config, takeover-pending), user data unchanged,
# nothing left assembled, INSTALL marker gone; then the loader (dry run)
# boots slot file a from that volume.  The stock config comes as
# etc-zyxel.tar(.sha256) like the PartnerKey script saves it.
# Way C on the same volume: bad password refused; new config (admin with the
# NT hash and a SHA-512 crypt of the chosen password, one share per top-level
# folder) staged for the importer, which plans/renders it.  Way A on a second
# (empty, sparse) loop disk: UntrashOS layout, both slots, bootstate, exact
# tail backup (backup GPT), INSTALL marker removed.
set -Eeuo pipefail
[[ -n "${ZT_IN_NS:-}" ]] || exec unshare -m --propagation private env ZT_IN_NS=1 "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
TR=$(readlink -f "${1:?toolroot}")
W=$(mktemp -d); LOOPS=(); fail=0; SRV=
export LD_LIBRARY_PATH=$TR/lib/x86_64-linux-gnu:$TR/usr/lib/x86_64-linux-gnu
# tool dir: mdadm, lvm commands without udev (PC has no lvm/md udev rules)
T="$W/tools"; mkdir -p "$T"
ln -s "$TR/sbin/mdadm" "$T/mdadm"; ln -s "$TR/sbin/dmsetup" "$T/dmsetup"
# lvm2 config via LVM_SYSTEM_DIR (the importer passes its own --config)
mkdir -p "$W/lvm"; printf 'devices {\n filter = [ "a|^/dev/md|", "r|.*|" ]\n use_devicesfile = 0\n}\nactivation {\n udev_sync = 1\n udev_rules = 0\n verify_udev_operations = 1\n}\n' >"$W/lvm/lvm.conf"
export LVM_SYSTEM_DIR="$W/lvm"
for c in lvm pvcreate vgcreate lvcreate vgchange pvs lvs vgs; do ln -s "$TR/sbin/lvm" "$T/$c"; done
export PATH="$T:/usr/sbin:/usr/bin:/sbin:/bin"
cleanup() {
	rc=$?
	set +e
	if [ "$rc$fail" != 00 ] && [ -f "$W/installer.log" ]; then echo "--- installer.log (tail)"; tail -40 "$W/installer.log"; fi
	[ -n "$SRV" ] && kill "$SRV" 2>/dev/null
	for m in $(findmnt -rn -o TARGET | grep -E "^$W|^/run/untrash/target|^/run/untrash/vg_info_area|^/run/zt-" | sort -r); do umount "$m"; done
	vgchange -an 2>/dev/null >/dev/null
	for d in $(dmsetup ls 2>/dev/null | awk -v v="vg_${U8:-none}-" 'index($1, v) == 1 {print $1}'); do dmsetup remove "$d"; done
	for m in /dev/md/zyx-* /dev/md/zt-ik /dev/md11[0-9]; do [ -e "$m" ] && mdadm --stop "$m" >/dev/null 2>&1; done
	for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done
	rm -rf "$W" /tmp/zt-loader-dry.log
}
trap cleanup EXIT
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
again() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do "$@" && return 0; sleep 1; done; return 1; }

echo "--- synthetic stock disk"
truncate -s 9G "$W/disk.img"; DISK=$(losetup -f --show -P "$W/disk.img"); LOOPS+=("$DISK")
parted -s "$DISK" mklabel gpt mkpart primary 1MiB 101MiB mkpart primary 101MiB 201MiB mkpart primary 201MiB 100%
for n in 1 2 3; do parted -s "$DISK" set $n raid on; done
partprobe "$DISK"; sleep 1
again mdadm --create /dev/md/zt-ik --run --metadata=1.2 --level=raid1 --assume-clean --force --raid-devices=1 "${DISK}p3" >/dev/null 2>&1
U8=$(mdadm --detail --export /dev/md/zt-ik | sed -n 's/^MD_UUID=//p' | tr -d : | cut -c1-8)
pvcreate -y -ff /dev/md/zt-ik >/dev/null; vgcreate "vg_$U8" /dev/md/zt-ik >/dev/null
lvcreate -y --addtag ext4 -L 100M -n vg_info_area "vg_$U8" >/dev/null
lvcreate -y --addtag ext4 -l 100%FREE -n lv_0a1b2c3d "vg_$U8" >/dev/null
for lv in vg_info_area lv_0a1b2c3d; do
	mkfs.ext4 -E stride=16,stripe-width=16 -b 4096 -q -j -m 0 -O large_file,extents,uninit_bg "/dev/vg_$U8/$lv"
done
mkdir -p "$W/m"; mount "/dev/vg_$U8/lv_0a1b2c3d" "$W/m"
mkdir -p "$W/m/.system" "$W/m/Medien"; echo Volume1 >"$W/m/.system/name_label"; : >"$W/m/.system/sysvol_001122334455"
head -c 20M /dev/urandom >"$W/m/Medien/film.bin"; DATA=$(sha256sum <"$W/m/Medien/film.bin" | cut -c1-64)
umount "$W/m"; vgchange -an "vg_$U8" >/dev/null; mdadm --stop /dev/md/zt-ik >/dev/null 2>&1

echo "--- test stick"
S="$W/stick/UNTRASH"; mkdir -p "$S/system" "$S/install-20261009-000000" "$W/cfg"
python3 - "$W/cfg/ugs_conf.db" "$HERE" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("t", sys.argv[2] + "/test_import_zyxel.py")
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t); t.make_db(sys.argv[1])
PY
CT="$S/install-20261009-000000/etc-zyxel.tar"
tar -cf "$CT" -C "$W/cfg" .; sha256sum <"$CT" | cut -c1-64 >"$CT.sha256"
# completed PartnerKey install run (flash backup, device.env with test MACs)
I0="$S/install-20261009-000000"; mkdir -p "$I0/flash"; head -c 4096 /dev/urandom >"$I0/flash/mtd2.raw.bin"
(cd "$I0/flash" && sha256sum *.bin >SHA256SUMS)
printf 'ETH0_MAC=02:5A:54:11:22:33\nETH1_MAC=02:5A:54:11:22:34\nLOADER_SLOT=2\nLOADER_MTD=6\n' >"$I0/device.env"
echo "00:00:00 RESULT DONE loader in kernel2, UntrashOS env active" >"$I0/install.log"
# signed mini slot: kernel/dtb/initrd blobs + manifest/signature trailer
gcc -O2 -I"$ROOT/untrashos/third_party/tweetnacl" -o "$T/zt-sig" "$ROOT/untrashos/slot/zt-sig.c" "$ROOT/untrashos/third_party/tweetnacl/tweetnacl.c"
d="$W/sf"; mkdir -p "$d"
head -c 8192 /dev/urandom >"$d/k"; head -c 4096 /dev/urandom >"$d/d"; head -c 4096 /dev/urandom >"$d/i"
cat >"$d/m" <<M
format=untrash-slot-2
version=ik-test-1
kernel_off=4096
kernel_len=8192
kernel_sha256=$(sha256sum <"$d/k" | cut -c1-64)
dtb_off=12288
dtb_len=4096
dtb_sha256=$(sha256sum <"$d/d" | cut -c1-64)
initrd_off=16384
initrd_len=4096
initrd_sha256=$(sha256sum <"$d/i" | cut -c1-64)
verity_root=00112233445566778899aabbccddeeff
cmdline_file=console=ttyS0 untrash.verity=1,00,00
M
"$T/zt-sig" sign "${ZT_SLOT_KEY:-$ROOT/inputs/keys/untrash-dev.sec}" "$d/m" "$d/s"
{ head -c 4096 /dev/zero; cat "$d/k" "$d/d" "$d/i"; cat "$d/m"; head -c $((4096 - $(stat -c %s "$d/m"))) /dev/zero
  cat "$d/s"; head -c $((4096 - 64)) /dev/zero; } >"$S/system/slot.utslot"
SL=$(stat -c %s "$S/system/slot.utslot")
{ echo "$(sha256sum <"$S/system/slot.utslot" | cut -c1-64) slot.utslot"
  echo "$(head -c $((SL - 8192)) "$S/system/slot.utslot" | sha256sum | cut -c1-64) slot.head"
  echo "$(tail -c 8192 "$S/system/slot.utslot" | sha256sum | cut -c1-64) slot.trailer"
  echo "$((SL - 8192)) slot.head.length"; } >"$S/system/slot.sha256"
echo ik-test-1 >"$S/system/version"; touch "$S/INSTALL"

echo "--- installer way B through the HTTP API"
mkdir -p "$W/i-data" "$W/e-data"
PORT=18093
INST() { env ZT_INSTALLER_TEST=1 ZT_INSTALLER_NOKEY=1 ZT_INSTALLER_STICKDIR="$W/stick" ZT_INSTALLER_PORT=$PORT \
	ZT_INSTALLER_BIND=127.0.0.1 ZT_INSTALLER_RUNDIR="$W/run" ZT_IMPORT_TOOL="$ROOT/untrashuntrashos/image/rootfs/usr/sbin/untrash-import-zyxel" \
	ZT_IMPORT_IDATA="$W/i-data" ZT_IMPORT_EDATA="$W/e-data" \
	python3 "$ROOT/untrashuntrashos/image/rootfs/usr/lib/untrash/untrash-installer" >>"$W/installer.log" 2>&1 & SRV=$!
	for i in $(seq 30); do curl -s "http://127.0.0.1:$PORT/api/job" >/dev/null && break; sleep 0.5; done; }
wait_job() { for i in $(seq 180); do st=$(curl -s "http://127.0.0.1:$PORT/api/job" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'); [[ $st == done || $st == failed ]] && break; sleep 1; done
	curl -s "http://127.0.0.1:$PORT/api/job" | python3 -c 'import json,sys; [print("     |", l) for l in json.load(sys.stdin)["log"]]' | grep -v '^     | [0-9:]* \$ \|^     | [0-9:]*   ' | tail -8 || true; }
INST
api() { curl -s -X POST -d "$2" "http://127.0.0.1:$PORT/api/$1"; }
PLAN=$(api plan '{"mode":"B"}')
echo "$PLAN" | python3 -c 'import json,sys; p=json.load(sys.stdin); [print("     plan:", s) for s in p["steps"]]; [print("     problem:", s) for s in p["problems"]]; print("     volumes:", [(v["key"], v["name"], v["sysvol"]) for v in p["volumes"] or []])'
VKEY=$(echo "$PLAN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"][0]["key"])')
check "plan: no problems, phrase KEEP, sysvol first" "echo '$PLAN' | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if not p[\"problems\"] and p[\"phrase\"]==\"KEEP\" and p[\"volumes\"][0][\"sysvol\"] else 1)'"
api start "{\"mode\":\"B\",\"volume\":\"$VKEY\",\"phrase\":\"KEEP\"}" >/dev/null
for i in $(seq 120); do st=$(curl -s "http://127.0.0.1:$PORT/api/job" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'); [[ $st == done || $st == failed ]] && break; sleep 1; done
curl -s "http://127.0.0.1:$PORT/api/job" | python3 -c 'import json,sys; [print("     |", l) for l in json.load(sys.stdin)["log"]]' | grep -v '^     | [0-9:]* \$ \|^     | [0-9:]*   ' | tail -12
check "job done" "[ $st = done ]"
kill "$SRV"; SRV=

echo "--- result on the volume"
sleep 1
check "nothing left assembled" "! ls /dev/md/ 2>/dev/null | grep -q . && [ -z \"\$(dmsetup ls 2>/dev/null | grep vg_)\" ]"
again mdadm --assemble --run /dev/md/zt-ik "${DISK}p3" >/dev/null 2>&1; vgchange -ay "vg_$U8" >/dev/null
mount -o ro "/dev/vg_$U8/lv_0a1b2c3d" "$W/m"
U="$W/m/.untrash"; WANT=$(sed -n 's/ slot.utslot$//p' "$S/system/slot.sha256")
check "slot-a/b identical to the stick" "[ \$(sha256sum <$U/slot-a.utslot | cut -c1-64) = $WANT ] && [ \$(sha256sum <$U/slot-b.utslot | cut -c1-64) = $WANT ]"
check "state.img 4 GiB, swap.img 1 GiB swap" "[ \$(stat -c %s $U/state.img) = 4294967296 ] && [ \$(blkid -o value -s TYPE $U/swap.img) = swap ]"
check "bootstate" "[ \"\$(tr -d '\\000' <$U/bootstate)\" = 'ZTBS1 pref=a a=3 b=3 good=- booting=-' ]"
check "stock-config (from etc-zyxel.tar) + takeover-pending (way B)" "cmp -s $U/stock-config/ugs_conf.db $W/cfg/ugs_conf.db && [ -f $U/takeover-pending ]"
check "/.untrash mode 700" "[ \$(stat -c %a $U) = 700 ]"
check "user data unchanged" "[ \$(sha256sum <$W/m/Medien/film.bin | cut -c1-64) = $DATA ]"
check "INSTALL marker removed from the stick" "[ ! -e $S/INSTALL ]"
check "disk metadata backup on the stick" "ls -d $S/disk-backup-B-* >/dev/null 2>&1"
check "stock MACs in /.untrash/device.env" "[ \"\$(cat $U/device.env | tr '\n' ' ')\" = 'ETH0_MAC=02:5A:54:11:22:33 ETH1_MAC=02:5A:54:11:22:34 ' ]"
umount "$W/m"; vgchange -an "vg_$U8" >/dev/null; mdadm --stop /dev/md/zt-ik >/dev/null 2>&1; sleep 1

echo "--- installer way C on the same volume"
INST
PLAN=$(api plan '{"mode":"C"}')
echo "$PLAN" | python3 -c 'import json,sys; p=json.load(sys.stdin); [print("     plan:", s) for s in p["steps"]]; [print("     problem:", s) for s in p["problems"]]'
check "plan C lists the share Medien" "echo '$PLAN' | grep -q 'Medien'"
R=$(api start "{\"mode\":\"C\",\"volume\":\"$VKEY\",\"phrase\":\"KEEP\",\"netname\":\"testnas\",\"password\":\"kurz\",\"password2\":\"kurz\"}")
check "short password refused" "echo '$R' | grep -q '8 Zeichen'"
PW='Geheim-Test-42'
api start "{\"mode\":\"C\",\"volume\":\"$VKEY\",\"phrase\":\"KEEP\",\"netname\":\"testnas\",\"password\":\"$PW\",\"password2\":\"$PW\"}" >/dev/null
wait_job
check "job C done" "[ $st = done ]"
check "password not in the job log" "! curl -s http://127.0.0.1:$PORT/api/job | grep -q '$PW'"
kill "$SRV"; SRV=; sleep 1
again mdadm --assemble --run /dev/md/zt-ik "${DISK}p3" >/dev/null 2>&1; vgchange -ay "vg_$U8" >/dev/null
mount -o ro "/dev/vg_$U8/lv_0a1b2c3d" "$W/m"
C="$U/stock-config"
check "C: state.img kept, takeover-pending, config mode 700" "[ \$(stat -c %s $U/state.img) = 4294967296 ] && [ -f $U/takeover-pending ] && [ \$(stat -c %a $C) = 700 ]"
check "C: admin = no-LM + NT hash of the password" "[ \"\$(sqlite3 $C/ugs_conf.db \"select passwd from smb_user where uname='admin'\" 2>/dev/null || python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"select passwd from smb_user where uname=\x27admin\x27\").fetchone()[0])' $C/ugs_conf.db)\" = \"\$(python3 -c 'import sys; print(\"X\"*32+\":\"+sys.argv[1])' \$(printf %s '$PW' | iconv -t UTF-16LE | openssl dgst -md4 -provider default -provider legacy 2>/dev/null | sed 's/.*= //' | tr a-f A-F))\" ]"
SH=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select value from ugs_misc where key=\"admin_shadow_passwd\"").fetchone()[0])' $C/ugs_conf.db)
SALT=$(echo "$SH" | cut -d'$' -f3)
[[ $SH == '$6$'* && "$SH" == "$(printf %s "$PW" | openssl passwd -6 -salt "$SALT" -stdin)" ]] && r=0 || r=1
check "C: admin shadow = sha512-crypt of the password" "[ $r = 0 ]"
# share paths are the volume's /i-data path, as in the installed system
IV="$W/i-data/0a1b2c3d"; mkdir -p "$IV"; mount --bind "$W/m" "$IV"
REND=$("$ROOT/untrashuntrashos/image/rootfs/usr/sbin/untrash-import-zyxel" render "$C" 2>&1 || true)
umount "$IV"
echo "$REND" | grep -A4 '^\[Medien\]' | sed 's/^/     | /'
check "C: importer renders [Medien] for admin and netbios name" "echo \"\$REND\" | grep -q '^\[Medien\]' && echo \"\$REND\" | grep -q 'netbios name = testnas'"
check "C: no stock users taken over" "! python3 -c 'import sqlite3,sys; sys.exit(0 if sqlite3.connect(sys.argv[1]).execute(\"select count(*) from smb_user where uname in (\x27alice\x27,\x27bob\x27)\").fetchone()[0] else 1)' $C/ugs_conf.db"
check "C: user data unchanged" "[ \$(sha256sum <$W/m/Medien/film.bin | cut -c1-64) = $DATA ]"
umount "$W/m"; vgchange -an "vg_$U8" >/dev/null; mdadm --stop /dev/md/zt-ik >/dev/null 2>&1; sleep 1

echo "--- loader (dry run) on the installed volume"
B="$W/bin"; mkdir -p "$B"
# the loader's own BusyBox (loader/busybox/build.sh), built for the PC
HBB=$ROOT/build/busybox/host/busybox
[[ -x $HBB ]] || "$ROOT/loader/busybox/build.sh" >&2
while read -r a; do ln -s "$HBB" "$B/$a"; done <"$ROOT/build/busybox/applets.txt"
ln -sf "$HBB" "$B/sh"
gcc -O2 -o "$B/zt-blk" "$ROOT/loader/slot/zt-blk.c"
gcc -O2 -o "$B/zt-mount" "$ROOT/nas-tools/zt-mount.c"
cp "$T/zt-sig" "$B/"
rm -f /tmp/zt-loader-dry.log
env ZT_LOADER_DRY=1 ZT_LOADER_GRACE=0 ZT_LOADER_KEYS="$ROOT/untrashos/slot/keys" ZT_LOADER_DEVPAT='loop*' ZT_LOADER_BIN="$B" \
	"$B/sh" "$ROOT/loader/slot/zt-loader" 2>&1 | sed 's/^/     | /'
check "loader boots slot file a from the stock LV" "grep -q 'slot file a on lv:.*:vg_$U8/lv_0a1b2c3d' /tmp/zt-loader-dry.log"

echo "--- installer way A on a second, empty disk"
truncate -s 20000000000 "$W/disk2.img"; DISK2=$(losetup -f --show -P "$W/disk2.img"); LOOPS+=("$DISK2")
N2=${DISK2#/dev/}; touch "$S/INSTALL"
head -c 1048576 /dev/urandom >"$W/tail.bin"; dd if="$W/tail.bin" of="$DISK2" bs=1M oflag=seek_bytes seek=$((20000000000 - 1048576)) conv=fsync status=none
TAIL=$(sha256sum <"$W/tail.bin" | cut -c1-64)
INST
PLAN=$(api plan "{\"mode\":\"A\",\"disk\":\"$N2\"}")
check "plan A: phrase DELETE $N2, no problems" "echo '$PLAN' | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if not p[\"problems\"] and p[\"phrase\"]==\"DELETE $N2\" else 1)'"
api start "{\"mode\":\"A\",\"disk\":\"$N2\",\"phrase\":\"DELETE $N2\"}" >/dev/null
wait_job
check "job A done" "[ $st = done ]"
kill "$SRV"; SRV=; sleep 1
check "A: GPT ut-sys-a/b, ut-state, ut-swap, ut-data, ut-bootstate" "[ \"\$(sgdisk -p $DISK2 | awk '/^ +[0-9]/ {print \$7}' | sort | tr '\n' ' ')\" = 'ut-bootstate ut-data ut-state ut-swap ut-sys-a ut-sys-b ' ]"
check "A: bootstate" "[ \"\$(head -c 512 ${DISK2}p6 | tr -d '\000')\" = 'ZTBS1 pref=a a=3 b=3 good=- booting=-' ]"
check "A: ut-data btrfs" "[ \"\$(blkid -p -o value -s TYPE ${DISK2}p5)\" = btrfs ]"
check "A: stock MACs in block 1 of ut-bootstate" "[ \"\$(dd if=${DISK2}p6 bs=4096 skip=1 count=1 status=none | tr -d '\000' | tr '\n' ' ')\" = 'ETH0_MAC=02:5A:54:11:22:33 ETH1_MAC=02:5A:54:11:22:34 ' ]"
TB=$(ls -d $S/disk-backup-A-$N2-*)
check "A: tail backup = last MiB of the disk before the wipe" "[ $TAIL = \$(sha256sum <$TB/tail-1MiB.bin | cut -c1-64) ]"
check "A: INSTALL marker removed" "[ ! -e $S/INSTALL ]"
INST
check "B/C now refused while an UntrashOS disk is present" "api plan '{\"mode\":\"B\"}' | grep -q 'UntrashOS-Partitionen'"
kill "$SRV"; SRV=

echo "--- way D (back to stock): completed install run with verified flash backup"
R="$S/install-20261010-080000"; mkdir -p "$R/flash"
head -c 262144 /dev/urandom >"$R/mtd2-before-a.bin"; head -c 1048576 /dev/urandom >"$R/mtd6-before-a.bin"
cp "$R/mtd2-before-a.bin" "$R/flash/mtd2.raw.bin"; (cd "$R/flash" && sha256sum *.bin >SHA256SUMS && echo "files=9" >VERIFIED)
printf 'ACTIVE_SLOT=1\nLOADER_SLOT=2\nLOADER_MTD=6\nENV_OLD_SHA256=%s\nKX_OLD_SHA256=%s\n' \
	"$(sha256sum <"$R/mtd2-before-a.bin" | cut -c1-64)" "$(sha256sum <"$R/mtd6-before-a.bin" | cut -c1-64)" >"$R/device.env"
echo "08:00:00 RESULT DONE loader in kernel2, UntrashOS env active" >"$R/install.log"
echo "failed: old" >"$S/ROLLBACK_FAILED"
mkdir -p "$S/update-20261010-090000/flash"; cp "$R/flash/"* "$S/update-20261010-090000/flash/"
INST
check "scan: stock backup listed as stock + verified" "curl -s http://127.0.0.1:$PORT/api/scan | python3 -c 'import json,sys; b=[x for x in json.load(sys.stdin)[\"backups\"] if x[\"name\"]==\"install-20261010-080000\"]; sys.exit(0 if b and b[0][\"stock\"] and b[0][\"verified\"] else 1)'"
PLAN=$(api plan '{"mode":"D","backup":"install-20261010-080000"}')
check "plan D: phrase STOCK, no problems, no PC/TFTP step" "echo '$PLAN' | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if not p[\"problems\"] and p[\"phrase\"]==\"STOCK\" and not any(\"TFTP\" in s for s in p[\"steps\"]) else 1)'"
check "plan D refuses an update run" "api plan '{\"mode\":\"D\",\"backup\":\"update-20261010-090000\"}' | grep -q 'keine abgeschlossene'"
api start '{"mode":"D","backup":"install-20261010-080000","phrase":"STOCK"}' >/dev/null
wait_job
check "job D done" "[ $st = done ]"
check "D: ROLLBACK set, old ROLLBACK_FAILED moved away" "[ -e $S/ROLLBACK ] && [ ! -e $S/ROLLBACK_FAILED ] && ls $S/ROLLBACK_FAILED.old-* >/dev/null"
printf X | dd of="$R/mtd6-before-a.bin" bs=1 seek=3 conv=notrunc status=none; rm -f "$S/ROLLBACK"
api start '{"mode":"D","backup":"install-20261010-080000","phrase":"STOCK"}' >/dev/null
wait_job
check "D: tampered backup -> failed, no ROLLBACK" "[ $st = failed ] && [ ! -e $S/ROLLBACK ]"
kill "$SRV"; SRV=
echo "INSTALLER WAYS B/C/A HOST TEST $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
