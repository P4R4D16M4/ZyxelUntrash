#!/usr/bin/env bash
# Write the UntrashOS stick image to a USB stick (the same as dd/Etcher, with
# checks).  ERASES THE STICK.
#   sudo install/write-stick.sh untrash-stick-<ver>.img /dev/sdX
set -Eeuo pipefail
IMG=${1:?image}; DEV=${2:?/dev/sdX}
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -b $DEV && $(lsblk -dno TRAN "$DEV") == usb ]] || { echo "$DEV is not a USB disk" >&2; exit 1; }
if lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then echo "$DEV is mounted, unmount first" >&2; exit 1; fi
isz=$(stat -c %s "$IMG"); dsz=$(blockdev --getsize64 "$DEV")
((dsz >= isz)) || { echo "stick too small: $dsz < $isz bytes" >&2; exit 1; }
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL "$DEV"
read -r -p "ERASE $DEV completely and write $(basename "$IMG")? type YES: " a; [[ $a == YES ]] || exit 1
wipefs -a -q "$DEV"
dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync
want=$(sha256sum "$IMG" | cut -d' ' -f1)
got=$(head -c "$isz" "$DEV" | sha256sum | cut -d' ' -f1)
[[ $got == "$want" ]] && echo "written and verified: $DEV" || { echo "VERIFY FAILED" >&2; exit 1; }
partprobe "$DEV" 2>/dev/null || true
