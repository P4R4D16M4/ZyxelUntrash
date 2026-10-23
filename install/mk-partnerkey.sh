#!/usr/bin/env bash
# Assemble the UntrashOS PartnerKey tree (root of the FAT32 stick).
#   mk-partnerkey.sh [--update] OUTDIR LOADER_UIMAGE VERSION
# Nothing in it is device specific: the PartnerKey script checks the NAS by
# structure and builds that NAS's env itself (install/partnerkey/
# usb_key_func.sh, install/ztpk.c).  --update: an installed NAS only gets
# the new loader (manifest UPDATE=1).
#
# nas5xx_check_file: the stock /sbin/check_key runs its content as a shell
# command (the working July 2026 sticks carried exactly these 55 bytes), i.e.
# it starts /mnt/partnerkey/diagnostic.sh = usb_key_func.sh; rcS then runs
# usb_key_func.sh itself too (the script's run-once lock stops the second run).
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
UPD=0; [[ ${1:-} == --update ]] && { UPD=1; shift; }
OUT=${1:?outdir}; LDR=${2:?loader uImage}; VER=${3:?version}
mkdir -p "$OUT/UNTRASH"
printf '%s\n%s\n' '/mnt/partnerkey/diagnostic.sh' ">/dev/null; echo '-: OK'" >"$OUT/nas5xx_check_file"
cp "$HERE/partnerkey/usb_key_func.sh" "$OUT/usb_key_func.sh"
cp "$HERE/partnerkey/usb_key_func.sh" "$OUT/diagnostic.sh"
# uImage name must start with "ZT" (update and loader self-removal check it)
[[ $(dd if="$LDR" bs=1 skip=32 count=2 status=none) == ZT ]] || { echo "loader uImage name does not start with ZT" >&2; exit 1; }
# Pad to the full 10 MiB kernel partition with 0xff (erased NAND), so that the
# whole read-back can be verified by SHA-256.
python3 -c "import sys; d=open(sys.argv[1],'rb').read(); assert len(d)<=10485760; open(sys.argv[2],'wb').write(d+b'\xff'*(10485760-len(d)))" "$LDR" "$OUT/UNTRASH/loader.uImage"
# static ARM helper; SOURCE_DATE_EPOCH-independent, same toolchain = same bytes
arm-linux-gnueabihf-gcc -static -O2 -Wall -o "$OUT/UNTRASH/ztpk" "$HERE/ztpk.c"
arm-linux-gnueabihf-strip "$OUT/UNTRASH/ztpk"
cat >"$OUT/UNTRASH/manifest.env" <<M
VERSION=$VER
LOADER_SHA256=$(sha256sum "$OUT/UNTRASH/loader.uImage" | cut -d' ' -f1)
ZTPK_SHA256=$(sha256sum "$OUT/UNTRASH/ztpk" | cut -d' ' -f1)
M
((UPD == 0)) || echo "UPDATE=1" >>"$OUT/UNTRASH/manifest.env"
(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -path './UNTRASH/system/*' -exec sha256sum {} + | sort -k2 >SHA256SUMS)
cat "$OUT/UNTRASH/manifest.env"
