#!/usr/bin/env bash
# PC test of loader/slot/zt-slotinit.c in test mode (run as root):
#   sudo test-zt-slotinit-host.sh ZT_SLOTINIT_BINARY TOOLROOT
# Builds a mini slot (erofs + verity + trailer), puts it as a slot file into
# three containers -- FAT stick, ext4 on md raid1, ext4 on an LVM LV on md --
# and checks that zt-slotinit finds each one, mounts it (vfat ro, ext4 rw),
# brings up the verity root from the file and writes boot.env; a slot file
# with one flipped byte must not yield readable root data.
set -Eeuo pipefail
ZS=$(readlink -f "${1:?zt-slotinit}"); TR=$(readlink -f "${2:?toolroot}")
export LD_LIBRARY_PATH=$TR/lib/x86_64-linux-gnu:$TR/usr/lib/x86_64-linux-gnu
MDADM="$TR/sbin/mdadm"; LVM="$TR/sbin/lvm"; DMS="$TR/sbin/dmsetup"
LC='devices { scan = [ "/dev" ] filter = [ "a|^/dev/md12[0-9]$|", "r|.*|" ] use_devicesfile = 0 } activation { udev_sync = 0 udev_rules = 0 } global { use_lvmetad = 0 }'
lvm() { "$LVM" "$@" --config "$LC"; }
W=$(mktemp -d); LOOPS=(); fail=0
undo() {	# tear down what one zt-slotinit run set up
	set +e
	# root -> verity -> loop -> slot file on the container: lazy unmount breaks the cycle
	mountpoint -q "$W/root/newroot" && umount -l "$W/root/newroot"
	mountpoint -q "$W/root/host" && umount -l "$W/root/host"
	sleep 0.5
	"$DMS" remove --noudevsync untrash-root 2>/dev/null
	losetup -a | grep -F "slot-a.utslot" | cut -d: -f1 | while read -r l; do losetup -d "$l"; done
	for n in $("$DMS" ls 2>/dev/null | awk '/^vg_ztst/ {print $1}'); do "$DMS" remove --noudevsync "$n"; done
	[ -e /sys/block/md120/md/array_state ] && "$MDADM" --stop /dev/md120 >/dev/null 2>&1
	set -e
}
cleanup() { undo; set +e; umount "$W/root"; for m in md121; do [ -e /dev/$m ] && "$MDADM" --stop /dev/$m >/dev/null 2>&1; done
	for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done; rm -rf "$W" /dev/vg_ztst; rm -f /dev/mapper/vg_ztst-*; }
trap cleanup EXIT
mkdir -p "$W/root"; mount -t tmpfs tmpfs "$W/root"; mount --make-private "$W/root"
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
L=; mkloop() { truncate -s "$2" "$W/$1"; L=$(losetup -f --show "$W/$1"); LOOPS+=("$L"); }	# no subshell: LOOPS

# mini slot: erofs root with a marker, verity, compact trailer (8 KiB)
mkdir -p "$W/rfs/run" "$W/rfs/dev" "$W/rfs/proc" "$W/rfs/sys" "$W/rfs/etc"
echo "zt-slotinit-marker" >"$W/rfs/etc/untrash-version"
mkfs.erofs --quiet "$W/root.erofs" "$W/rfs" >/dev/null
truncate -s $(( ($(stat -c %s "$W/root.erofs") + 4095) / 4096 * 4096 )) "$W/root.erofs"
N=$(( $(stat -c %s "$W/root.erofs") / 4096 ))
VOUT=$(/usr/sbin/veritysetup format --no-superblock --data-block-size=4096 --hash-block-size=4096 \
	--data-blocks="$N" "$W/root.erofs" "$W/root.hash")
RH=$(sed -n 's/^Root hash:[[:space:]]*//p' <<<"$VOUT"); SALT=$(sed -n 's/^Salt:[[:space:]]*//p' <<<"$VOUT")
truncate -s $(( ($(stat -c %s "$W/root.hash") + 4095) / 4096 * 4096 )) "$W/root.hash"
cat "$W/root.erofs" "$W/root.hash" >"$W/slot.utslot"; head -c 8192 /dev/zero >>"$W/slot.utslot"
put() {	# $1 = device, $2 = fstype: slot file into /.untrash
	mkdir -p "$W/m"; mount -t "$2" "$1" "$W/m"; mkdir -p "$W/m/.untrash"
	cp "$W/slot.utslot" "$W/m/.untrash/slot-a.utslot"; umount "$W/m"
}
run() {	# $1 = untrash.src
	echo "console=ttyS0 untrash.src=$1 untrash.file=/.untrash/slot-a.utslot untrash.verity=$N,$RH,$SALT untrash.slot=a init=/usr/lib/untrash/untrash-init" >"$W/cmdline"
	ZT_SLOTINIT_TEST="$W/root" ZT_SLOTINIT_CMDLINE="$W/cmdline" "$ZS" >"$W/log" 2>&1; local r=$?
	sed 's/^/     | /' "$W/log"; return $r
}

echo "--- FAT stick"
mkloop fat.img 64M; F=$L; mkfs.vfat -F 32 -i 1234ABCD "$F" >/dev/null; put "$F" vfat
run vfat:1234-ABCD && r=0 || r=1
check "vfat: zt-slotinit ok" "[ $r = 0 ]"
check "vfat: root marker readable" "grep -q zt-slotinit-marker $W/root/newroot/etc/untrash-version"
check "vfat: container ro at /run/untrash/host" "findmnt -no OPTIONS $W/root/newroot/run/untrash/host | grep -q '^ro'"
check "vfat: boot.env" "grep -qx ZT_HOST_FS=vfat $W/root/newroot/run/untrash/boot.env && grep -qx ZT_SLOT=a $W/root/newroot/run/untrash/boot.env"
undo

echo "--- ext4 on md raid1 (2 members)"
mkloop a.img 200M; A=$L; mkloop b.img 200M; B=$L
"$MDADM" --create /dev/md121 --run --metadata=1.2 --level=raid1 --assume-clean --force --raid-devices=2 "$A" "$B" >/dev/null 2>&1
mkfs.ext4 -q /dev/md121; put /dev/md121 ext4
MU=$("$MDADM" --detail --export /dev/md121 | sed -n 's/^MD_UUID=//p' | tr -d :)
"$MDADM" --stop /dev/md121 >/dev/null
run md:$MU && r=0 || r=1
check "md: zt-slotinit ok" "[ $r = 0 ]"
check "md: root marker readable" "grep -q zt-slotinit-marker $W/root/newroot/etc/untrash-version"
check "md: container rw" "findmnt -no OPTIONS $W/root/newroot/run/untrash/host | grep -q '^rw'"
check "md: assembled as md120 with 2 members, active" "[ \$(ls /sys/block/md120/slaves | wc -l) = 2 ] && grep -qE 'clean|active' /sys/block/md120/md/array_state"
undo

echo "--- ext4 on LVM LV on md (degraded: 1 of 2 members)"
mkloop c.img 300M; C=$L; mkloop d.img 300M; D=$L
"$MDADM" --create /dev/md121 --run --metadata=1.2 --level=raid1 --assume-clean --force --raid-devices=2 "$C" "$D" >/dev/null 2>&1
lvm pvcreate -y -ff /dev/md121 >/dev/null; lvm vgcreate vg_ztst /dev/md121 >/dev/null
lvm lvcreate -y -L 100M -n vg_info_area vg_ztst >/dev/null; lvm lvcreate -y -L 120M -n lv_sys vg_ztst >/dev/null
mkfs.ext4 -q /dev/mapper/vg_ztst-lv_sys; put /dev/mapper/vg_ztst-lv_sys ext4
MU=$("$MDADM" --detail --export /dev/md121 | sed -n 's/^MD_UUID=//p' | tr -d :)
lvm vgchange -an vg_ztst >/dev/null; "$MDADM" --stop /dev/md121 >/dev/null
losetup -d "$D"; LOOPS=("${LOOPS[@]/$D}")	# second member missing
SECONDS=0; run lv:$MU:vg_ztst/lv_sys && r=0 || r=1
check "lv: zt-slotinit ok (degraded, after the 20 s wait: ${SECONDS}s)" "[ $r = 0 ]"
check "lv: root marker readable" "grep -q zt-slotinit-marker $W/root/newroot/etc/untrash-version"
check "lv: dm name as lvm2" "[ -e /sys/block/\$(basename \$(readlink -f /dev/mapper/vg_ztst-lv_sys 2>/dev/null || echo none))/dm ] || $DMS ls | grep -q '^vg_ztst-lv_sys'"
undo

echo "--- tampered slot file"
mkloop fat2.img 64M; F2=$L; mkfs.vfat -F 32 -i 5678ABCD "$F2" >/dev/null
printf '\xff' | dd of="$W/slot.utslot" bs=1 seek=1100 conv=notrunc status=none; put "$F2" vfat
run vfat:5678-ABCD && r=0 || r=1
check "tampered: root unreadable (zt-slotinit fails or the marker is unreadable)" "[ $r != 0 ] || ! cat $W/root/newroot/etc/untrash-version >/dev/null 2>&1"
undo
echo "ZT-SLOTINIT HOST TEST $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
