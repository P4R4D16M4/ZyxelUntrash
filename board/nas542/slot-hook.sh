#!/usr/bin/env bash
# NAS542 steps of the slot build (untrashos/docs/board-interface.md).
#   slot-hook.sh check KBUILD        kernel build usable for this board?
#   slot-hook.sh root ROOT KBUILD    board tools + services into the slot tree
set -Eeuo pipefail
TOP=${ZT_TOP:?ZT_TOP}
case ${1:-} in
check)
	# the network driver must use the stock PE firmware of the NAS
	# (untrash-pfe-firmware); no firmware is shipped in the image
	grep -q '^CONFIG_PFE_CTRL_FW12=y' "$2/.config" || { echo "kernel without CONFIG_PFE_CTRL_FW12" >&2; exit 1; }
	;;
root)
	R=$2
	# USB blackbox (kernel log to a ZTBLACKBOX1 stick) and fan control
	# (MCU temperature -> PWM4, stock app_wd table), nas-tools/
	cp "$TOP/build/nas-tools/zt-blackbox" "$TOP/build/nas-tools/zt-fan" "$R/usr/lib/untrash/"
	ln -sf /usr/lib/systemd/system/untrash-blackbox.service "$R/etc/systemd/system/sysinit.target.wants/"
	# power-loss mode + WoL (board MCU), PCIe ASM1061 bays after PFE start
	for u in untrash-power untrash-pcie; do
		ln -sf /usr/lib/systemd/system/$u.service "$R/etc/systemd/system/multi-user.target.wants/"
	done
	;;
*)
	echo "usage: slot-hook.sh check KBUILD | root ROOT KBUILD" >&2; exit 2 ;;
esac
