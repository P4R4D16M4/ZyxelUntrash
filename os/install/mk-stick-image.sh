#!/usr/bin/env bash
# Build THE UntrashOS stick image (L1): one raw disk image for dd/Etcher that
# installs UntrashOS on any stock NAS542 with only a browser.
#   mk-stick-image.sh LOADER.uImage SLOT.img SLOT.build.log VERSION OUT.img [SIZE_MIB]
# SLOT.img + build log: os/image/mkslot-erofs.sh.  SIZE_MIB default 3400
# (fits every "4 GB" stick; the flash backup needs ~270 MB per PartnerKey
# run, the system slot ~160 MB).  Needs no root (mkfs.vfat on a file, mtools).
#
# Layout (as os/install/prepare-partnerkey-stick.sh made it by hand before):
#   bytes 0..19      blackbox header "ZTBLACKBOX1" (MBR boot-code area)
#   446..511         MBR, one partition type 0x0c from 32 MiB
#   1 .. 17 MiB      blackbox slots (nas-tools/zt-blackbox, zeroed)
#   32 MiB ..        FAT32 "UNTRASHPK", mounted by the stock rcS as
#                    /mnt/partnerkey:
#       nas5xx_check_file, diagnostic.sh, usb_key_func.sh   (PartnerKey)
#       UNTRASH/manifest.env, loader.uImage, ztpk            (mk-partnerkey.sh)
#       UNTRASH/system/slot.utslot, slot.sha256, version     (mk-stick-system.sh)
#       UNTRASH/INSTALL                                      (loader -> installer)
#       SHA256SUMS                                           (all of the above)
# Flow on the NAS: start 1 = stock firmware runs the PartnerKey (backup,
# loader, env, power off); start 2 = loader -> installer from the stick ->
# browser http://zyxel-untrash.local/ -> way A/B/C (or D later).
# SOURCE_DATE_EPOCH (default: 2026-01-01) fixes timestamps and the volume id.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LDR=${1:?loader uImage}; SLOT=${2:?slot.img}; SLOG=${3:?slot build log}; VER=${4:?version}
OUT=$(realpath -m "${5:?out.img}"); SIZE=${6:-3400}
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600}
MKFS=$(PATH=/usr/sbin:/sbin:$PATH command -v mkfs.vfat); SFDISK=$(PATH=/usr/sbin:/sbin:$PATH command -v sfdisk)
for t in mcopy mmd "$MKFS" "$SFDISK"; do command -v "$t" >/dev/null || { echo "missing $t (dosfstools, mtools, fdisk)" >&2; exit 1; }; done
((SIZE >= 1024)) || { echo "SIZE_MIB must be >= 1024" >&2; exit 1; }
# The loader goes to NAND: refuse one that fails the offline contract check
# (os/loader/tests/check-loader.py: DTB, modules, console, mount options).
python3 "$HERE/../loader/tests/check-loader.py" "$LDR" ${ZT_LOADER_BUILD:+--build "$ZT_LOADER_BUILD"} \
	${ZT_LOADER_REF:+--ref "$ZT_LOADER_REF"} >&2 || { echo "loader check FAILED: $LDR" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# 1. file tree
T="$W/tree"
"$HERE/mk-partnerkey.sh" "$T" "$LDR" "$VER" >/dev/null
"$HERE/mk-stick-system.sh" --install "$SLOT" "$SLOG" "$T" >/dev/null
cat >"$T/README.txt" <<R
UntrashOS $VER for the Zyxel NAS542

1. Switch the NAS off. Plug this stick into a USB port, switch the NAS on.
   The stock firmware saves the flash (UNTRASH/install-*/flash/, checked),
   installs the UntrashOS loader and switches the NAS off (a few minutes).
2. Switch the NAS on again (stick stays in). After a few minutes open
   http://zyxel-untrash.local/ in a browser and choose:
   A  new install on a wiped disk
   B  keep data, users, shares and settings (UntrashOS replaces the stock OS)
   C  keep data, new users and settings
   D  back to the stock firmware (later too, from the UntrashOS settings)
Keep this stick: it holds the backup of the stock state of THIS NAS.
R
(cd "$T" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + | sort -k2 >SHA256SUMS)
find "$T" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

# 2. FAT32 partition image
PSTART=$((32 * 1024 * 1024)); PSIZE=$(( SIZE * 1024 * 1024 - PSTART ))
truncate -s "$PSIZE" "$W/part.img"
VOLID=$(printf '%08x' $(( SOURCE_DATE_EPOCH & 0xffffffff )))
"$MKFS" -F 32 -n UNTRASHPK -i "$VOLID" --invariant "$W/part.img" >/dev/null 2>&1 ||
	"$MKFS" -F 32 -n UNTRASHPK -i "$VOLID" "$W/part.img" >/dev/null
export MTOOLS_SKIP_CHECK=1 MTOOLS_NO_VFAT=0
(cd "$T" && find . -mindepth 1 -type d | sort | while read -r d; do mmd -i "$W/part.img" "::${d#./}"; done)
(cd "$T" && find . -type f | sort | while read -r f; do mcopy -m -i "$W/part.img" "$f" "::${f#./}"; done)

# 3. disk image: MBR + blackbox, partition at 32 MiB
rm -f "$OUT"; truncate -s $(( SIZE * 1024 * 1024 )) "$OUT"
printf 'label: dos\nlabel-id: 0x%s\nstart=65536, type=c\n' "$VOLID" | "$SFDISK" -q "$OUT"
printf 'ZTBLACKBOX1\0\0\0\0\0\0\0\0\0' | dd of="$OUT" bs=1 count=20 conv=notrunc status=none
dd if="$W/part.img" of="$OUT" bs=1M seek=32 conv=notrunc,sparse status=none

# 4. self-check: read the files back out of the image
mkdir -p "$W/check"
(cd "$T" && find . -type f | sort | while read -r f; do
	mkdir -p "$W/check/$(dirname "$f")"; mcopy -n -i "$OUT@@$PSTART" "::${f#./}" "$W/check/$f"; done)
(cd "$W/check" && sha256sum -c --quiet SHA256SUMS) || { echo "image self-check FAILED" >&2; exit 1; }
[[ $(head -c 11 "$OUT") == ZTBLACKBOX1 ]] || { echo "blackbox header missing" >&2; exit 1; }
echo "STICK=$OUT version=$VER size=${SIZE}MiB sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
echo "files: $(wc -l <"$T/SHA256SUMS") ($(du -sh "$T" | cut -f1)), self-check OK"
echo "write: sudo os/install/write-stick.sh $OUT /dev/sdX   (or Etcher / dd)"
