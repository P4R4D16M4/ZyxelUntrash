#!/usr/bin/env bash
# PC test of os/install/ztpk.c (PartnerKey env/uImage helper) against the
# reference os/install/envfs.py: the ARM build under qemu-arm (as on the
# stock NAS) and an x86 build must give byte-identical envs.
#   os/install/test-ztpk.sh [ENV_DUMP] [STOCK_UIMAGE]
# ENV_DUMP (gitignored, real device values; the test only uses scrubbed
# copies): default inputs/test/stock-env-mtd2.bin
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
SRC=${1:-$ROOT/inputs/test/stock-env-mtd2.bin}
UIMG=${2:-$ROOT/inputs/test/uImage-stock-kernel1}
[[ -f $SRC ]] || { echo "SKIP: no env dump $SRC"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
gcc -O2 -Wall -o "$W/ztpk-x86" "$HERE/ztpk.c"
arm-linux-gnueabihf-gcc -static -O2 -Wall -o "$W/ztpk-arm" "$HERE/ztpk.c"
# qemu reports the stock kernel's release, so a static glibc that needs a
# newer kernel would fail here as it would on the NAS
ARM() { QEMU_UNAME=3.2.54 qemu-arm-static "$W/ztpk-arm" "$@"; }
PY() { python3 "$HERE/envfs.py" "$@"; }
MK() { python3 "$HERE/tests/mk-test-env.py" "$@" >/dev/null; }

MK "$SRC" "$W/dev.bin" --seed dev                                  # project dev env V6 (our NAS)
MK "$SRC" "$W/stock1.bin" --pristine --seed n1                     # factory shape, slot 1 active
MK "$SRC" "$W/stock2.bin" --pristine --curr 2 --next 2 --seed n2   # other NAS, slot 2 active
MK "$SRC" "$W/pending.bin" --pristine --curr 1 --next 2 --seed n3  # firmware switch pending
for e in dev stock1 stock2; do
	py=$(PY untrash "$W/$e.bin" "$W/$e.py.bin"); arm=$(ARM env-untrash "$W/$e.bin" "$W/$e.arm.bin")
	x86=$("$W/ztpk-x86" env-untrash "$W/$e.bin" "$W/$e.x86.bin")
	check "$e: python '$py' = arm '$arm' = x86 '$x86'" "[[ '$py' == '$arm' && '$arm' == '$x86' ]]"
	check "$e: identical bytes" "cmp -s '$W/$e.py.bin' '$W/$e.arm.bin' && cmp -s '$W/$e.arm.bin' '$W/$e.x86.bin'"
	check "$e: result is a valid env" "[[ \$(ARM env-check '$W/$e.arm.bin') == OK* ]] && PY check '$W/$e.arm.bin' >/dev/null"
done
check "stock1 -> loader slot 2" "[[ \$(ARM env-untrash '$W/stock1.bin' '$W/x') == 'OK slot=2' ]]"
check "stock2 -> loader slot 1" "[[ \$(ARM env-untrash '$W/stock2.bin' '$W/x') == 'OK slot=1' ]]"
PY extract "$W/stock2.arm.bin" "$W/s2"
check "stock2: loader boots kernel1" "grep -qx $'\tbootm /dev/nand0.kernel1.bb' '$W/s2/bin/untrash_loader'"
check "stock2: init = loader, then stock boot" "[[ \$(tail -2 '$W/s2/bin/init' | tr '\n' ' ') == '/env/bin/untrash_loader boot ' ]]"
PY extract "$W/stock2.bin" "$W/s2o"
check "stock2: config and other files unchanged" "diff -r -x init -x untrash_loader -x .envfs-order '$W/s2o' '$W/s2' >/dev/null"
check "pending switch refused" "[[ \$(ARM env-untrash '$W/pending.bin' '$W/x') == REFUSED* ]]"
check "installed env refused (no double install)" "[[ \$(ARM env-untrash '$W/stock1.arm.bin' '$W/x') == REFUSED*already* ]]"
cp "$W/stock1.bin" "$W/bad.bin"; printf 'X' | dd of="$W/bad.bin" bs=1 seek=100 conv=notrunc status=none
check "corrupt env refused (crc)" "[[ \$(ARM env-check '$W/bad.bin') == 'BAD data crc mismatch' ]]"
check "env-get curr_bootfrom" "[[ \$(ARM env-get '$W/stock2.bin' curr_bootfrom) == 2 ]]"
check "python and arm crc32 agree" "[[ \$(ARM crc32 '$W/stock1.bin') == \$(python3 -c 'import zlib,sys; print(\"%08x\" % zlib.crc32(open(sys.argv[1],\"rb\").read()))' '$W/stock1.bin') ]]"
if [[ -f $UIMG ]]; then
	check "stock uImage valid" "[[ \$(ARM uimage-check '$UIMG') == OK*name=Linux-3.2.54 ]]"
	head -c 2000000 "$UIMG" >"$W/trunc"
	check "truncated uImage refused" "[[ \$(ARM uimage-check '$W/trunc') == BAD* ]]"
	python3 -c "import sys; open(sys.argv[1],'wb').write(b'\xff'*10485760)" "$W/erased"
	check "erased kernel partition refused" "[[ \$(ARM uimage-check '$W/erased') == BAD* ]]"
fi
((fail == 0)) && echo ALL_OK || { echo FAILED; exit 1; }
