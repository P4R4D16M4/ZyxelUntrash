#!/usr/bin/env bash
# Prepare a USB stick as UntrashOS loader-installer PartnerKey + blackbox.
#   sudo install/prepare-partnerkey-stick.sh /dev/sdX TREE
# TREE = output of mk-partnerkey.sh (e.g. build/partnerkey).
#
# Layout: MBR with one FAT32 partition from 32 MiB (label UNTRASHPK, mounted by
# the stock firmware as /mnt/partnerkey); the blackbox (nas-tools/zt-blackbox)
# keeps its header in bytes 0..19 (MBR boot-code area, the partition table at
# 446.. is untouched) and its slots at 1..17 MiB, before the partition.
# ERASES THE WHOLE STICK.  The old first 17 MiB are saved to BACKUP first.
set -Eeuo pipefail
DEV=${1:?/dev/sdX}; TREE=${2:?tree}
BACKUP=${BACKUP:-$(dirname "$0")/../build/stick-backup-$(date +%Y%m%d-%H%M%S).bin}
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -b $DEV && $(lsblk -dno TRAN "$DEV") == usb ]] || { echo "$DEV is not a USB disk" >&2; exit 1; }
[[ -f $TREE/usb_key_func.sh && -f $TREE/UNTRASH/manifest.env ]] || { echo "bad tree $TREE" >&2; exit 1; }
if lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then echo "$DEV is mounted, unmount first" >&2; exit 1; fi
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL "$DEV"
read -r -p "ERASE $DEV completely? type YES: " a; [[ $a == YES ]] || exit 1

dd if="$DEV" of="$BACKUP" bs=1M count=17 status=none
echo "old first 17 MiB saved to $BACKUP"
wipefs -a -q "$DEV"
printf 'label: dos\nstart=65536, type=c\n' | sfdisk -q "$DEV"
partprobe "$DEV" 2>/dev/null || true; udevadm settle; sleep 1
mkfs.vfat -F 32 -n UNTRASHPK "${DEV}1" >/dev/null
# blackbox header (20 bytes, counter 0) and empty slots
printf 'ZTBLACKBOX1\0\0\0\0\0\0\0\0\0' | dd of="$DEV" bs=1 count=20 conv=notrunc,fsync status=none
dd if=/dev/zero of="$DEV" bs=1M seek=1 count=16 conv=notrunc,fsync status=none

M=$(mktemp -d)
mount "${DEV}1" "$M"
cp -r "$TREE"/. "$M"/
sync
(cd "$M" && sha256sum -c --quiet SHA256SUMS) && echo "PartnerKey files verified"
umount "$M"; rmdir "$M"
sfdisk -l "$DEV" | tail -1
[[ $(head -c 11 "$DEV") == ZTBLACKBOX1 ]] && echo "blackbox header present"
echo "done: $DEV = PartnerKey (FAT32 UNTRASHPK) + blackbox"
