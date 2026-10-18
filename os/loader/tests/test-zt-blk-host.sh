#!/usr/bin/env bash
# PC test of os/loader/zt-blk.c against the real mdadm/lvm2 (run as root).
#   sudo test-zt-blk-host.sh ZT_BLK_BINARY TOOLROOT
# TOOLROOT: extracted Debian debs (mdadm lvm2 dmsetup libaio1, `dpkg-deb -x`),
# so nothing gets installed on the PC.  Uses loop files only (md120+, zt-test-*).
# Checks: md-scan vs mdadm --examine, md-assemble (read-auto) vs mdadm --detail,
# lvm-scan + dm-create give exactly lvm2's dm name/uuid/table (two-segment LV
# included) and lvm2 then reports the LV as active, probe, loop-attach, verity.
set -Eeuo pipefail
ZB=$(readlink -f "${1:?zt-blk}"); TR=$(readlink -f "${2:?toolroot}")
export LD_LIBRARY_PATH=$TR/lib/x86_64-linux-gnu:$TR/usr/lib/x86_64-linux-gnu
MDADM="$TR/sbin/mdadm"; LVM="$TR/sbin/lvm"; DMS="$TR/sbin/dmsetup"
LC='devices { scan = [ "/dev" ] filter = [ "a|^/dev/md12[0-9]$|", "r|.*|" ] use_devicesfile = 0 } activation { udev_sync = 0 udev_rules = 0 } global { use_lvmetad = 0 }'
lvm() { "$LVM" "$@" --config "$LC"; }
W=$(mktemp -d); LOOPS=(); fail=0
cleanup() {
	set +e
	for n in zt-test-root zt-test-v-lv_data zt-test-v-vg_info_area vg_zt--test-lv_data vg_zt--test-vg_info_area; do
		"$DMS" remove --noudevsync "$n" 2>/dev/null; done
	for m in md120 md121 md122; do [ -e /dev/$m ] && "$MDADM" --stop /dev/$m >/dev/null 2>&1; done
	for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done
	rm -rf "$W" /dev/vg_zt-test; rm -f /dev/mapper/vg_zt--test-*
}
trap cleanup EXIT
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
L=; mkloop() { truncate -s "$2" "$W/$1"; L=$(losetup -f --show "$W/$1"); LOOPS+=("$L"); }	# no subshell: LOOPS

mkloop a.img 300M; A=$L; mkloop b.img 300M; B=$L; mkloop c.img 200M; C=$L
"$MDADM" --create /dev/md120 --run --metadata=1.2 --level=raid1 --assume-clean --force --raid-devices=2 \
	--homehost=NAS542 --name=2 "$A" "$B" >/dev/null 2>&1
"$MDADM" --create /dev/md121 --run --metadata=1.2 --level=raid1 --assume-clean --force --raid-devices=1 \
	--homehost=NAS542 --name=3 "$C" >/dev/null 2>&1
U120=$("$MDADM" --examine --export "$A" | sed -n 's/^MD_UUID=//p' | tr -d :)
U121=$("$MDADM" --examine --export "$C" | sed -n 's/^MD_UUID=//p' | tr -d :)
# VG name with '-' to test the dm name mangling; second LV extended -> 2 segments
lvm pvcreate -y -ff /dev/md120 >/dev/null
lvm vgcreate vg_zt-test /dev/md120 >/dev/null
lvm lvcreate -y --addtag ext4 -L 100M -n vg_info_area vg_zt-test >/dev/null
lvm lvcreate -y --addtag ext4 -L 40M -n lv_data vg_zt-test >/dev/null
lvm lvextend -L +20M vg_zt-test/vg_info_area >/dev/null
lvm lvextend -L +60M vg_zt-test/lv_data >/dev/null
mkfs.ext4 -q -L zttest /dev/vg_zt-test/lv_data 2>/dev/null || mkfs.ext4 -q -L zttest "/dev/mapper/vg_zt--test-lv_data"
"$DMS" table >"$W/lvm.table"; "$DMS" info -c --noheadings -o name,uuid >"$W/lvm.info"
DATA_SHA=$(sha256sum </dev/mapper/vg_zt--test-lv_data | cut -c1-64)
lvm vgchange -an vg_zt-test >/dev/null
mkfs.ext4 -q -L ztmd /dev/md121
"$MDADM" --stop /dev/md120 >/dev/null; "$MDADM" --stop /dev/md121 >/dev/null

echo "--- md-scan"
"$ZB" md-scan | grep -F -e "$A " -e "$B " -e "$C " | tee "$W/scan"
check "md-scan sees 3 members" "[ \$(wc -l <$W/scan) = 3 ]"
check "md-scan uuid md120 (2 members)" "[ \$(grep -c uuid=$U120 $W/scan) = 2 ]"
check "md-scan uuid md121, level 1, 1 disk" "grep -q 'uuid=$U121 name=NAS542:3 level=1 disks=1' $W/scan"

echo "--- md-assemble"
"$ZB" md-assemble md122 read-auto "$A" "$B"
check "md122 assembled with md120's uuid" "\"$MDADM\" --detail --export /dev/md122 | tr -d : | grep -q MD_UUID=$U120"
check "md122 is read-auto" "[ \$(cat /sys/block/md122/md/array_state) = read-auto ]"
check "md122 has 2 members" "[ \$(ls /sys/block/md122/slaves | wc -l) = 2 ]"
check "probe md member" "\"$ZB\" probe $A | grep -qx TYPE=linux_raid_member"
check "probe PV" "\"$ZB\" probe /dev/md122 | grep -qx TYPE=LVM2_member"

echo "--- lvm-scan"
"$ZB" lvm-scan /dev/md122 | tee "$W/lv"
declare -A DEV
for lv in vg_info_area lv_data; do
	L=$(grep " lv=$lv " "$W/lv")
	name=$(sed 's/.* name=\([^ ]*\).*/\1/' <<<"$L"); uuid=$(sed 's/.* uuid=\([^ ]*\).*/\1/' <<<"$L")
	table=$(sed 's/.* table=//' <<<"$L")
	check "$lv: dm name/uuid as lvm2" "grep -qx '$name:$uuid' $W/lvm.info"
	# lvm2 tables name the PV by major:minor; ours by path -> compare after substitution
	want=$(grep "^$name: " "$W/lvm.table" | sed "s/^$name: //" | sed "s/ [0-9]*:[0-9]* / PV /")
	got=$(tr ';' '\n' <<<"$table" | sed "s# /dev/md122 # PV #")
	check "$lv: table identical ($(wc -l <<<"$want") segments)" "[ \"\$want\" = \"\$got\" ]"
	DEV[$lv]=$("$ZB" dm-create "$name" "$uuid" rw "$table")
done
check "lvm2 sees the zt-blk LVs as active" "[ \$(lvm lvs --noheadings -o lv_active vg_zt-test | grep -c active) = 2 ]"
check "LV content identical" "[ \$(sha256sum <${DEV[lv_data]} | cut -c1-64) = $DATA_SHA ]"
check "probe ext4 on LV" "\"$ZB\" probe ${DEV[lv_data]} | grep -qx LABEL=zttest"
"$DMS" remove --noudevsync vg_zt--test-lv_data; "$DMS" remove --noudevsync vg_zt--test-vg_info_area
"$ZB" md-stop md122
check "md-stop" "[ ! -e /sys/block/md122/md ] || [ \$(cat /sys/block/md122/md/array_state 2>/dev/null || echo clear) = clear ]"

echo "--- loop-attach + verity"
head -c 8M /dev/urandom >"$W/data.img"
VOUT=$(/usr/sbin/veritysetup format --no-superblock --data-block-size=4096 --hash-block-size=4096 "$W/data.img" "$W/hash.img")
RH=$(sed -n 's/^Root hash:[[:space:]]*//p' <<<"$VOUT"); SALT=$(sed -n 's/^Salt:[[:space:]]*//p' <<<"$VOUT")
cat "$W/data.img" "$W/hash.img" >"$W/slot.img"
LD=$("$ZB" loop-attach "$W/slot.img" ro); LOOPS+=("$LD")
check "loop is read-only" "[ \$(cat /sys/block/${LD#/dev/}/ro) = 1 ]"
VD=$("$ZB" dm-create zt-test-root - ro "0 16384 verity 1 $LD $LD 4096 4096 2048 2048 sha256 $RH $SALT")
check "verity device content = data" "[ \"\$(sha256sum <$VD | cut -c1-64)\" = \"\$(sha256sum <$W/data.img | cut -c1-64)\" ]"
"$DMS" remove --noudevsync zt-test-root
VD=$("$ZB" dm-create zt-test-root - ro "0 16384 verity 1 $LD $LD 4096 4096 2048 2048 sha256 ${RH/a/b} $SALT")
check "verity with a wrong root hash refuses reads" "! dd if=$VD of=/dev/null bs=4096 count=1 2>/dev/null"
"$DMS" remove --noudevsync zt-test-root
"$ZB" loop-detach "$LD"
check "probe ext4 on md121 member (md 1.2 superblock wins)" "\"$ZB\" probe $C | grep -qx TYPE=linux_raid_member"
echo "ZT-BLK HOST TEST $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
