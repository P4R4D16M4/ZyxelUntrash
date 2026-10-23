#!/usr/bin/env bash
# Download the external build inputs from their official sources into
# inputs/ (not part of the repository) and check them against fixed SHA-256
# sums.  Nothing here is redistributed by UntrashOS.
#
#   tools/fetch-inputs.sh          fetch what is missing, verify everything
#
# inputs/src/linux-6.6.145.tar.xz          kernel.org (kernel source)
# inputs/src/kexec-tools-2.0.31.tar.xz     kernel.org (kexec for the loader)
# inputs/src/busybox-1.37.0.tar.bz2        busybox.net (loader userland)
# The PFE network engine firmware is not an input: every NAS542 carries it
# in its stock firmware, UntrashOS copies it from there on the NAS
# (board/nas542/rootfs/usr/lib/untrash/untrash-pfe-firmware).
#
# Yours, see docs/build.md: inputs/keys/untrash-dev.sec (slot signing key).
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IN=$ROOT/inputs

# path  url  sha256
LIST=(
	"src/linux-6.6.145.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.145.tar.xz de100e33d8ad8b6f4b3d2335b179e961be3c00ae7a39efdb052182a8d8bf0126"
	"src/busybox-1.37.0.tar.bz2 https://busybox.net/downloads/busybox-1.37.0.tar.bz2 3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4"
	"src/kexec-tools-2.0.31.tar.xz https://kernel.org/pub/linux/utils/kernel/kexec/kexec-tools-2.0.31.tar.xz 8a8f350ddc66e1c905a3ab525a7e9ba96c81e04e70ef69397b0155b67b922c31"
)
fail=0
for e in "${LIST[@]}"; do
	read -r path url sum <<<"$e"
	f=$IN/$path
	mkdir -p "$(dirname "$f")"
	if [[ ! -f $f ]]; then
		echo "fetch $path"
		curl -fsSL --retry 3 -o "$f.part" "$url" && mv "$f.part" "$f"
	fi
	if [[ $(sha256sum <"$f" | cut -d' ' -f1) == "$sum" ]]; then
		echo "ok    $path"
	else
		echo "BAD   $path (SHA-256 differs; delete it and run again)" >&2; fail=1
	fi
done
# mkosi v25.3 (rootfs builder), pinned commit
MKOSI_COMMIT=54c625c380ef5500f17460981a3c67b109b6a847
if [[ ! -d $IN/mkosi/.git ]]; then
	echo "fetch mkosi v25.3"
	git clone -q https://github.com/systemd/mkosi.git "$IN/mkosi"
fi
if [[ $(git -C "$IN/mkosi" rev-parse HEAD) != "$MKOSI_COMMIT" ]]; then
	git -C "$IN/mkosi" fetch -q origin && git -C "$IN/mkosi" checkout -q "$MKOSI_COMMIT"
fi
[[ $(git -C "$IN/mkosi" rev-parse HEAD) == "$MKOSI_COMMIT" ]] && echo "ok    mkosi v25.3" || { echo "BAD   mkosi" >&2; fail=1; }
[[ -f $IN/keys/untrash-dev.sec ]] && echo "ok    keys/untrash-dev.sec" || echo "missing keys/untrash-dev.sec (zt-sig keygen, docs/build.md)"
exit $fail
