#!/usr/bin/env bash
# Download the external build inputs from their official sources into
# inputs/ (not part of the repository) and check them against fixed SHA-256
# sums.  Nothing here is redistributed by UntrashOS.
#
#   tools/fetch-inputs.sh          fetch what is missing, verify everything
#
# inputs/src/linux-6.6.145.tar.xz          kernel.org (kernel source)
# inputs/src/kexec-tools-2.0.31.tar.xz     kernel.org (kexec for the loader)
# inputs/pfe-firmware/*_c2000.elf          PFE network engine firmware, set
#                                          pfe_13 matching the vendor driver
#                                          (github.com/scpcom/linux, branch
#                                          ls1024a-6.1.y, firmware/)
#
# Not downloadable, see docs/build.md: inputs/loader-base.cpio (BusyBox +
# glibc of the stock firmware) and inputs/keys/untrash-dev.sec (your slot
# signing key).
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IN=$ROOT/inputs
PFE_COMMIT=a8447d65994c4d66dccb501282f4e58fb22a3d70
PFE_URL=https://raw.githubusercontent.com/scpcom/linux/$PFE_COMMIT/firmware

# path  url  sha256
LIST=(
	"src/linux-6.6.145.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.145.tar.xz de100e33d8ad8b6f4b3d2335b179e961be3c00ae7a39efdb052182a8d8bf0126"
	"src/kexec-tools-2.0.31.tar.xz https://kernel.org/pub/linux/utils/kernel/kexec/kexec-tools-2.0.31.tar.xz 8a8f350ddc66e1c905a3ab525a7e9ba96c81e04e70ef69397b0155b67b922c31"
	"pfe-firmware/class_c2000.elf $PFE_URL/class_c2000.elf a88363f9f4e840aed95f95e0eba8054219cf840659a51eca4db9d0f2c79cf89b"
	"pfe-firmware/tmu_c2000.elf $PFE_URL/tmu_c2000.elf b874d8ad4d2d0142f9c6f31e00b7d650cca8c13eb5dae781f3387bc825ccd7d8"
	"pfe-firmware/util_c2000.elf $PFE_URL/util_c2000.elf 5d45b6715e21a148a69121e3d4f19ae42b62ccdf8a49ec597a1b18d7c2ebbf4b"
	"pfe-firmware/util_c2000_revA0.elf $PFE_URL/util_c2000_revA0.elf 68680f3a3c6777f058fe634cdaece26a5d133945cf962ab909899ca3477ee5ef"
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
for p in loader-base.cpio; do
	[[ -f $IN/$p ]] && echo "ok    $p" || echo "missing $p (see docs/build.md)"
done
[[ -f $IN/keys/untrash-dev.sec ]] && echo "ok    keys/untrash-dev.sec" || echo "missing keys/untrash-dev.sec (zt-sig keygen, docs/build.md)"
exit $fail
