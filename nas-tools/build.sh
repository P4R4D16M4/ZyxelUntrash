#!/usr/bin/env bash
# Static ARM builds of the NAS helpers -> build/nas-tools/ (loader initramfs,
# slot image).  zt-sig comes from untrashos/slot/zt-sig.c (+ TweetNaCl), zt-kexec
# is kexec-tools 2.0.31 (inputs/src, tools/fetch-inputs.sh).
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
O=$ROOT/build/nas-tools; mkdir -p "$O"
CC=(arm-linux-gnueabihf-gcc -static -O2 -Wall)
for c in "$ROOT"/nas-tools/zt-*.c; do
	n=$(basename "${c%.c}")
	"${CC[@]}" -o "$O/$n" "$c"
	arm-linux-gnueabihf-strip "$O/$n"
done
"${CC[@]}" -I"$ROOT/untrashos/third_party/tweetnacl" -o "$O/zt-sig" "$ROOT/untrashos/slot/zt-sig.c" "$ROOT/untrashos/third_party/tweetnacl/tweetnacl.c"
arm-linux-gnueabihf-strip "$O/zt-sig"
if [[ ! -f $O/zt-kexec ]]; then
	T=$ROOT/inputs/src/kexec-tools-2.0.31.tar.xz
	[[ -f $T ]] || { echo "missing $T (tools/fetch-inputs.sh)" >&2; exit 1; }
	K=$ROOT/build/kexec-tools-2.0.31; rm -rf "$K"; tar -C "$ROOT/build" -xf "$T"
	(cd "$K" && ./configure --host=arm-linux-gnueabihf --without-zlib --without-lzma --without-xen \
		LDFLAGS=-static >/dev/null && make -j"$(nproc)" >/dev/null)
	arm-linux-gnueabihf-strip -o "$O/zt-kexec" "$K/build/sbin/kexec"
fi
ls "$O"
