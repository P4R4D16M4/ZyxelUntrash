#!/usr/bin/env bash
# Build an UntrashOS system slot image (format untrash-slot-1, ext4).
#   mkslot.sh ZIMAGE DTB VERSION OUT.img [SIZE_MIB]
# ZIMAGE must be a plain zImage (no appended DTB): the loader passes DTB via
# kexec --dtb, with /chosen/untrash,stage = "system" added here so that the
# started kernel does not run the loader again.  The manifest is signed with
# inputs/keys/untrash-dev.sec (not in git); the public key is untrashos/slot/keys/.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
ZI=${1:?zImage}; DTB=${2:?dtb}; VER=${3:?version}; OUT=${4:?out}; SIZE=${5:-64}
SEC=${ZT_SLOT_KEY:-$ROOT/inputs/keys/untrash-dev.sec}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
gcc -O2 -I"$ROOT/untrashos/third_party/tweetnacl" -o "$W/zt-sig" "$ROOT/untrashos/slot/zt-sig.c" "$ROOT/untrashos/third_party/tweetnacl/tweetnacl.c"
mkdir -p "$W/root/boot" "$W/root/untrash"
cp "$ZI" "$W/root/boot/zImage"
cp "$DTB" "$W/root/boot/dtb"
fdtput -t s "$W/root/boot/dtb" /chosen untrash,stage system
[[ $(fdtget "$W/root/boot/dtb" /chosen untrash,stage) == system ]]
cat >"$W/root/untrash/manifest" <<M
format=untrash-slot-1
version=$VER
kernel=boot/zImage
kernel_sha256=$(sha256sum "$W/root/boot/zImage" | cut -d' ' -f1)
dtb=boot/dtb
dtb_sha256=$(sha256sum "$W/root/boot/dtb" | cut -d' ' -f1)
M
"$W/zt-sig" sign "$SEC" "$W/root/untrash/manifest" "$W/root/untrash/manifest.sig"
"$W/zt-sig" verify "$ROOT/untrashos/slot/keys/untrash-dev.pub" "$W/root/untrash/manifest" "$W/root/untrash/manifest.sig" >/dev/null
rm -f "$OUT"
/usr/sbin/mkfs.ext4 -q -F -L "ut-slot" -E root_owner=0:0 -d "$W/root" "$OUT" "${SIZE}M"
echo "SLOT=$OUT"
echo "SLOT_SHA256=$(sha256sum "$OUT" | cut -d' ' -f1)"
cat "$W/root/untrash/manifest"
