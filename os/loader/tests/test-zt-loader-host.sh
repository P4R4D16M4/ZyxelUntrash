#!/usr/bin/env bash
# PC test of os/loader/zt-loader (dry run: kexec is only logged), as root:
#   sudo test-zt-loader-host.sh TOOLROOT
# TOOLROOT: extracted Debian mdadm/lvm2/dmsetup debs (see test-zt-blk-host.sh).
# The loader runs under the host BusyBox with only the applets of the NAS
# loader's own BusyBox 1.37 (loader/busybox/, built for the PC) plus
# x86 builds of zt-blk, zt-mount and zt-sig.  Synthetic stock disks on loop
# files: md raid1 (2 members) with LVM (vg_info_area, lv_sys with /.untrash,
# lv_other), md raid1 (1 member) with ext4 directly, a FAT stick.
# Checks: stick INSTALL marker wins; slot file a from the LV with boot state
# a=2 booting=a written; tampered a -> b; degraded array -> boot without
# writing; no tries -> stick fallback; way D stage 1 (ROLLBACK: backup
# checked, RAM mark, reset; a second run = mark lost -> ROLLBACK_FAILED and
# normal boot; a bad backup -> nothing done); arrays stopped afterwards;
# volumes without /.untrash stay byte-identical.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
TR=$(readlink -f "${1:?toolroot}")
export LD_LIBRARY_PATH=$TR/lib/x86_64-linux-gnu:$TR/usr/lib/x86_64-linux-gnu
MDADM="$TR/sbin/mdadm"; LVM="$TR/sbin/lvm"; DMS="$TR/sbin/dmsetup"
LC='devices { scan = [ "/dev" ] filter = [ "a|^/dev/md1[0-9][0-9]$|", "r|.*|" ] use_devicesfile = 0 } activation { udev_sync = 0 udev_rules = 0 } global { use_lvmetad = 0 }'
lvm() { "$LVM" "$@" --config "$LC"; }
SEC=${ZT_SLOT_KEY:-$ROOT/inputs/keys/untrash-dev.sec}
W=$(mktemp -d); LOOPS=(); fail=0
mdstop_all() { for m in /sys/block/md1[0-9][0-9]; do [ -e "$m/md" ] || continue
	n=${m##*/}; "$DMS" ls 2>/dev/null | awk '/^vg_ztl/ {print $1}' | xargs -r -n1 "$DMS" remove --noudevsync
	"$MDADM" --stop /dev/$n >/dev/null 2>&1; done; true; }
cleanup() {
	trap - ERR
	set +e
	for m in /run/zt-vol /run/zt-stick /run/zt-slot; do mountpoint -q $m && umount $m; done
	"$DMS" ls 2>/dev/null | awk '/^vg_ztl/ {print $1}' | xargs -r -n1 "$DMS" remove --noudevsync
	mdstop_all
	for l in "${LOOPS[@]}"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done
	rm -rf "$W" /dev/vg_ztl /tmp/zt-loader-dry.log /tmp/zt-md.scan /tmp/zt-lv.scan
	rm -f /dev/mapper/vg_ztl-*
}
trap cleanup EXIT
trap 'echo "ERR line $LINENO: $BASH_COMMAND" >&2' ERR
# md gendisks of a previous run disappear asynchronously
for i in $(seq 50); do [ -e /sys/block/md150 ] || [ -e /sys/block/md151 ] || [ -e /sys/block/md110 ] || break; sleep 0.2; done
# opening /dev/mdN recreates a just-stopped md gendisk on the PC (udev, "block
# device autoloading"): mdadm then says "already in use" for a moment
again() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do "$@" && return 0; sleep 1; done; return 1; }
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
L=; mkloop() { truncate -s "$2" "$W/$1"; L=$(losetup -f --show "$W/$1"); LOOPS+=("$L"); }	# no subshell: LOOPS

# tools: BusyBox 1.19 applet set + x86 zt-*
B="$W/bin"; mkdir -p "$B"
# the loader's own BusyBox (loader/busybox/build.sh), built for the PC
HBB=$ROOT/build/busybox/host/busybox
[[ -x $HBB ]] || "$ROOT/loader/busybox/build.sh" >&2
while read -r a; do ln -s "$HBB" "$B/$a"; done <"$ROOT/build/busybox/applets.txt"
ln -sf "$HBB" "$B/sh"	# /bin/sh is a separate link in the loader image
gcc -O2 -o "$B/zt-blk" "$ROOT/os/loader/zt-blk.c"
gcc -O2 -o "$B/zt-mount" "$ROOT/nas-tools/zt-mount.c"
gcc -O2 -I"$ROOT/third_party/tweetnacl" -o "$B/zt-sig" "$ROOT/os/loader/zt-sig.c" "$ROOT/third_party/tweetnacl/tweetnacl.c"
mkdir -p "$W/keys"; cp "$ROOT/os/loader/keys/"*.pub "$W/keys/"

slotfile() {	# $1 = out, $2 = version: kernel/dtb/initrd blobs + signed trailer
	local d="$W/sf"; rm -rf "$d"; mkdir -p "$d"
	head -c 8192 /dev/urandom >"$d/k"; head -c 4096 /dev/urandom >"$d/d"; head -c 4096 /dev/urandom >"$d/i"
	cat >"$d/m" <<M
format=untrash-slot-2
version=$2
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
cmdline=root=/dev/dm-0 dm-mod.waitfor=PARTLABEL=@SLOT@
cmdline_file=console=ttyS0 init=/usr/lib/untrash/untrash-init untrash.verity=1,00,00
M
	"$B/zt-sig" sign "$SEC" "$d/m" "$d/s"
	{ head -c 4096 /dev/zero; cat "$d/k" "$d/d" "$d/i"
	  cat "$d/m"; head -c $((4096 - $(stat -c %s "$d/m"))) /dev/zero
	  cat "$d/s"; head -c $((4096 - 64)) /dev/zero; } >"$1"
}
runloader() {	# -> $W/out, dry log in $W/dry
	rm -f /tmp/zt-loader-dry.log
	mkdir -p "$W/scsi/host0"; : >"$W/scsi/host0/scan"
	env ZT_LOADER_DRY=1 ZT_LOADER_GRACE=0 ZT_LOADER_KEYS="$W/keys" ZT_LOADER_DEVPAT='loop*' ZT_LOADER_BIN="$B" \
		ZT_LOADER_DEVMEM="$W/ram" ZT_LOADER_SCSI="$W/scsi" ZT_LOADER_MDROUNDS=${MDROUNDS:-2} ZT_LOADER_MDWAIT=${MDWAIT:-2} ZT_LOADER_DISKWAIT=${DISKWAIT:-40} \
		"$B/sh" "$ROOT/os/loader/zt-loader" >"$W/out" 2>&1 || true
	cp /tmp/zt-loader-dry.log "$W/dry" 2>/dev/null || : >"$W/dry"
	sed 's/^/     | /' "$W/out"
}
online() {	# md150 + vg_ztl active (an inactive half-assembled md150 is stopped first)
	local st; st=$(cat /sys/block/md150/md/array_state 2>/dev/null || true)
	case $st in clean|active|active-idle|readonly|read-auto) ;; *)
		[ -n "$st" ] && "$MDADM" --stop /dev/md150 >/dev/null 2>&1
		again "$MDADM" --assemble --run /dev/md150 $(for l in "$A" "$B2"; do losetup "$l" >/dev/null 2>&1 && echo "$l"; done) >/dev/null 2>&1 ;;
	esac
	lvm vgchange -ay vg_ztl >/dev/null; }
bs() { online; mount -o ro /dev/mapper/vg_ztl-lv_sys "$W/m"; tr -d '\000' <"$W/m/.untrash/bootstate"; umount "$W/m"; }
bs_set() { online; mount /dev/mapper/vg_ztl-lv_sys "$W/m"
	{ printf '%s\n' "$1"; head -c $((511 - ${#1})) /dev/zero; } | dd of="$W/m/.untrash/bootstate" conv=notrunc status=none
	umount "$W/m"; }
offline() { lvm vgchange -an vg_ztl >/dev/null 2>&1; mdstop_all; }
busy_md() { ls -d /sys/block/md1[0-9][0-9]/md 2>/dev/null | while read -r m; do
	s=$(cat $m/array_state 2>/dev/null); [ -z "$s" ] || [ "$s" = clear ] || [ "$s" = inactive ] || echo "$m=$s"; done; }
idle() { local i b
	for i in 1 2 3 4 5; do b="$(busy_md)$("$DMS" ls 2>/dev/null | grep '^vg_ztl')"; [ -z "$b" ] && return 0; sleep 1; done
	echo "     still active: $b"; return 1; }

# --- synthetic stock disks
mkloop a.img 300M; A=$L; mkloop b.img 300M; B2=$L; mkloop c.img 120M; C=$L
again "$MDADM" --create /dev/md150 --run --metadata=1.2 --level=raid1 --assume-clean --force --raid-devices=2 "$A" "$B2" >/dev/null
lvm pvcreate -y -ff /dev/md150 >/dev/null; lvm vgcreate vg_ztl /dev/md150 >/dev/null
lvm lvcreate -y -L 60M -n vg_info_area vg_ztl >/dev/null; lvm lvcreate -y -L 100M -n lv_sys vg_ztl >/dev/null
lvm lvcreate -y -L 60M -n lv_other vg_ztl >/dev/null
for lv in vg_info_area lv_sys lv_other; do mkfs.ext4 -q /dev/mapper/vg_ztl-$lv; done
mkdir -p "$W/m"; mount /dev/mapper/vg_ztl-lv_sys "$W/m"; mkdir "$W/m/.untrash" "$W/m/Medien"
slotfile "$W/m/.untrash/slot-a.utslot" sys-a-1; slotfile "$W/m/.untrash/slot-b.utslot" sys-b-1
echo data >"$W/m/Medien/x"; umount "$W/m"; bs_set "ZTBS1 pref=a a=3 b=3 good=- booting=-"
SYS_UUID=$("$MDADM" --detail --export /dev/md150 | sed -n 's/^MD_UUID=//p' | tr -d :)
again "$MDADM" --create /dev/md151 --run --metadata=1.2 --level=raid1 --assume-clean --force --raid-devices=1 "$C" >/dev/null
mkfs.ext4 -q /dev/md151
offline
mkloop stick.img 64M; S=$L; mkfs.vfat -F 32 -i 4242ABCD "$S" >/dev/null
mount "$S" "$W/m"; mkdir -p "$W/m/UNTRASH/system"; slotfile "$W/m/UNTRASH/system/slot.utslot" installer-1
echo installer-1 >"$W/m/UNTRASH/system/version"; touch "$W/m/UNTRASH/INSTALL"; umount "$W/m"
sum_other() { online
	sha256sum </dev/mapper/vg_ztl-lv_other | cut -c1-16; sha256sum </dev/mapper/vg_ztl-vg_info_area | cut -c1-16
	offline; sha256sum <"$C" | cut -c1-16; }
OTHER=$(sum_other)

echo "--- 1: stick with INSTALL marker"
runloader
check "installer from stick" "grep -q 'installer from stick' $W/dry"
check "stick cmdline: vfat src, slot=stick, installer=1, initrd" "grep -q -- '--initrd=.*untrash.src=vfat:4242-ABCD untrash.file=/UNTRASH/system/slot.utslot untrash.slot=stick untrash.installer=1' $W/dry"
check "nothing left assembled" "idle"

echo "--- 2: slot file a from the LV"
mount "$S" "$W/m"; rm "$W/m/UNTRASH/INSTALL"; umount "$W/m"
runloader
check "slot file a booted" "grep -q 'slot file a on lv:$SYS_UUID:vg_ztl/lv_sys' $W/dry"
check "cmdline_file + src/file/slot appended" "grep -q 'untrash.verity=1,00,00 untrash.src=lv:$SYS_UUID:vg_ztl/lv_sys untrash.file=/.untrash/slot-a.utslot untrash.slot=a' $W/dry"
check "nothing left assembled" "idle"
check "boot state a=2 booting=a" "[ \"\$(bs)\" = 'ZTBS1 pref=a a=2 b=3 good=- booting=a' ]"; offline

echo "--- 3: slot a tampered -> b"
online; mount /dev/mapper/vg_ztl-lv_sys "$W/m"
printf 'X' | dd of="$W/m/.untrash/slot-a.utslot" bs=1 seek=5000 conv=notrunc status=none; umount "$W/m"; offline
runloader
check "a refused (hash), b booted" "grep -q 'kernel hash mismatch' $W/out && grep -q 'slot file b on' $W/dry"
check "boot state b=2 booting=b" "[ \"\$(bs)\" = 'ZTBS1 pref=a a=2 b=2 good=- booting=b' ]"; offline

echo "--- 4: degraded array (one member missing)"
bs_set "ZTBS1 pref=b a=2 b=3 good=b booting=b"; offline
losetup -d "$B2"
runloader
check "missing member: SATA/SCSI rescan, then go on" "grep -q 'MD incomplete .*rescan 2/2' $W/out && grep -q -- '- - -' $W/scsi/host0/scan && grep -q 'still incomplete' $W/out"
check "boots b although degraded" "grep -q 'slot file b on' $W/dry"
check "boot state NOT written" "grep -q 'degraded, boot state NOT written' $W/out"
check "nothing left assembled" "idle"
check "state unchanged" "[ \"\$(bs)\" = 'ZTBS1 pref=b a=2 b=3 good=b booting=b' ]"; offline
B2=$(losetup -f --show "$W/b.img"); LOOPS+=("$B2"); sleep 1

echo "--- 4b: member comes back during the wait (warm reset, slow disk)"
bs_set "ZTBS1 pref=b a=2 b=3 good=b booting=b"; offline
losetup -d "$B2"; sleep 1
# back after the first disk wait (3 s), during rescan round 1; the PC's udev
# auto-assembles a returning md member: stop exactly that array again
( sleep 6; losetup "$B2" "$W/b.img"; sleep 1
  for m in /sys/block/md*/slaves/"${B2##*/}"; do [ -e "$m" ] || continue
	n=${m#/sys/block/}; n=${n%%/*}; "$MDADM" --stop /dev/$n >/dev/null 2>&1; done ) &
DISKWAIT=3 MDWAIT=20 runloader; wait
check "waited, member found, array complete" "grep -q 'rescan 1/' $W/out && grep -q 'MD after rescan: complete' $W/out"
check "boots b, not degraded: boot state written" "grep -q 'slot file b on' $W/dry && ! grep -q 'degraded, boot state NOT written' $W/out"
check "nothing left assembled" "idle"
bs_set "ZTBS1 pref=b a=2 b=3 good=b booting=b"; offline

echo "--- 5: no tries left -> installer stick fallback"
bs_set "ZTBS1 pref=a a=0 b=0 good=- booting=b"; offline
runloader
check "falls back to the stick" "grep -q 'nothing else bootable' $W/out && grep -q 'installer from stick' $W/dry"
check "nothing left assembled" "idle"

echo "--- 6: way D stage 1 (UNTRASH/ROLLBACK on the stick)"
for i in 0 1 2 3 4 5 6 7; do echo 00000000; done >"$W/ram"
mount "$S" "$W/m"; R="$W/m/UNTRASH/install-20261010-120000"; mkdir -p "$R"
head -c 4096 /dev/urandom >"$R/mtd2-before-a.bin"; head -c 8192 /dev/urandom >"$R/mtd6-before-a.bin"
printf 'LOADER_SLOT=2\nLOADER_MTD=6\nENV_OLD_SHA256=%s\nKX_OLD_SHA256=%s\n' \
	"$(sha256sum <"$R/mtd2-before-a.bin" | cut -c1-64)" "$(sha256sum <"$R/mtd6-before-a.bin" | cut -c1-64)" >"$R/device.env"
echo "12:00:00 RESULT DONE loader in kernel2" >"$R/install.log"; touch "$W/m/UNTRASH/ROLLBACK"; umount "$W/m"
bs_set "ZTBS1 pref=a a=3 b=3 good=a booting=a"; offline
runloader
check "reset for the stock boot, no kexec" "grep -q 'reboot -f (rollback)' $W/dry && ! grep -q kexec $W/dry"
check "RAM mark = env words" "[ \"\$(tr '\n' ' ' <$W/ram)\" = '5a54726f 6c6c6261 636b2d31 8f1e2d3c 00000000 00000000 00000000 00000000 ' ]"
mount -o ro "$S" "$W/m"
check "stage1 noted on the stick" "grep -q '^stage1 .*source=install-20261010-120000 loader_slot=2' $W/m/UNTRASH/rollback-stage1.log"
umount "$W/m"
check "nothing left assembled" "idle"
echo "--- 7: loader runs again (mark lost) -> ROLLBACK_FAILED, normal boot"
for i in 0 1 2 3 4 5 6 7; do echo 00000000; done >"$W/ram"
runloader
mount -o ro "$S" "$W/m"
check "ROLLBACK_FAILED names the cause" "grep -q 'did not survive' $W/m/UNTRASH/ROLLBACK_FAILED"
umount "$W/m"
check "normal boot continues (stick still seen)" "grep -q 'slot file . on' $W/dry && grep -q 'STICK /dev/loop[0-9]* uuid=' $W/out"
echo "--- 8: bad backup -> nothing done"
mount "$S" "$W/m"; rm -f "$W/m/UNTRASH/ROLLBACK_FAILED" "$W/m/UNTRASH/rollback-stage1.log"
printf X | dd of="$R/mtd6-before-a.bin" bs=1 seek=10 conv=notrunc status=none; umount "$W/m"
for i in 0 1 2 3 4 5 6 7; do echo 00000000; done >"$W/ram"
runloader
check "no reset, RAM untouched" "! grep -q 'reboot -f' $W/dry && ! grep -q 5a54726f $W/ram"
mount -o ro "$S" "$W/m"
check "ROLLBACK_FAILED: backup does not verify" "grep -q 'does not verify' $W/m/UNTRASH/ROLLBACK_FAILED"
umount "$W/m"
check "nothing left assembled" "idle"

echo "--- volumes without /.untrash untouched"
check "lv_other, vg_info_area, md151 byte-identical" "[ \"\$(sum_other)\" = \"\$OTHER\" ]"
echo "ZT-LOADER HOST TEST $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
