#!/usr/bin/env bash
# Build the UntrashOS GPT for an empty disk of SECTORS 512-byte sectors.
#   mkgpt.sh SECTORS OUTDIR
# Writes OUTDIR/gpt-head.bin (LBA 0..33), OUTDIR/gpt-tail.bin (last 33 LBAs)
# and OUTDIR/layout.txt.  The NAS writes head/tail with dd after checking the
# disk size (no partitioning tool needed in the BusyBox 1.19 initramfs).
# Layout (docs/architecture/untrash-os-concept.md §4): ut-sys-a 1 GiB,
# ut-sys-b 1 GiB, ut-state 4 GiB, ut-swap 1 GiB, ut-data rest; partition 6
# ut-bootstate (sectors 40..2047, raw, loader boot counters) uses the gap
# before the 1 MiB-aligned partitions, so adding it leaves 1..5 untouched.
set -Eeuo pipefail
N=${1:?sectors}; OUT=${2:?outdir}; mkdir -p "$OUT"
IMG="$OUT/disk.sparse"; rm -f "$IMG"
truncate -s $((N * 512)) "$IMG"
/usr/sbin/sgdisk -Z "$IMG" >/dev/null
/usr/sbin/sgdisk -a 2048 \
	-n 1:0:+1G -t 1:8300 -c 1:ut-sys-a \
	-n 2:0:+1G -t 2:8300 -c 2:ut-sys-b \
	-n 3:0:+4G -t 3:8300 -c 3:ut-state \
	-n 4:0:+1G -t 4:8200 -c 4:ut-swap \
	-n 5:0:0   -t 5:fd00 -c 5:ut-data "$IMG" >/dev/null
/usr/sbin/sgdisk -a 8 -n 6:40:2047 -t 6:8300 -c 6:ut-bootstate "$IMG" >/dev/null
/usr/sbin/sgdisk -p "$IMG" >"$OUT/layout.txt"
dd if="$IMG" of="$OUT/gpt-head.bin" bs=512 count=34 status=none
dd if="$IMG" of="$OUT/gpt-tail.bin" bs=512 skip=$((N - 33)) count=33 status=none
rm -f "$IMG"
sha256sum "$OUT"/gpt-*.bin
cat "$OUT/layout.txt"
