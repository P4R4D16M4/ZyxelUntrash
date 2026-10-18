#!/usr/bin/env bash
# Put a built system slot into the installer's stick layout.
#   mk-stick-system.sh [--install] SLOT.img BUILD.log OUTDIR   -> OUTDIR/UNTRASH/system/
# --install also creates the marker UNTRASH/INSTALL: the loader then boots the
# installer from the stick; the installer removes the marker when a way is done.
# Files:
#   slot.utslot   slot FILE (I2): head (bytes 0 .. END) + trailer (last 8 KiB of
#                 the slot image, signed manifest).  The loader boots it from the
#                 stick (installer) or from /.untrash on a stock volume; the
#                 installer writes head and trailer to ut-sys-a/b or copies it.
#   slot.sha256   "<sha> slot.utslot", "<sha> slot.head", "<sha> slot.trailer",
#                 "<bytes> slot.head.length"
#   version
# END = end of the last payload (initrd if the manifest has one, else DTB).
set -Eeuo pipefail
MARK=0; [[ ${1:-} == --install ]] && { MARK=1; shift; }
IMG=${1:?slot.img}; LOG=${2:?build.log}; OUT=${3:?outdir}/UNTRASH/system
eval "$(grep -E '^(dtb|initrd)_(off|len)=' "$LOG")"
END=$(( dtb_off + dtb_len ))
[[ -n "${initrd_off:-}" ]] && END=$(( initrd_off + initrd_len ))
VER=$(sed -n 's/^version=//p' "$LOG" | head -1)
[[ -n "$VER" ]] || VER=$(basename "$IMG" .img)
mkdir -p "$OUT"
rm -f "$OUT/slot.head.gz" "$OUT/slot.trailer"	# format before I2
{ head -c "$END" "$IMG"; tail -c 8192 "$IMG"; } >"$OUT/slot.utslot"
{ echo "$(sha256sum <"$OUT/slot.utslot" | cut -d' ' -f1) slot.utslot"
  echo "$(head -c "$END" "$IMG" | sha256sum | cut -d' ' -f1) slot.head"
  echo "$(tail -c 8192 "$IMG" | sha256sum | cut -d' ' -f1) slot.trailer"
  echo "$END slot.head.length"; } >"$OUT/slot.sha256"
echo "$VER" >"$OUT/version"
((MARK == 0)) || : >"$OUT/../INSTALL"
cat "$OUT/slot.sha256" "$OUT/version"
