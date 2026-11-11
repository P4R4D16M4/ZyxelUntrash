#!/bin/sh
###############################################################################
# UntrashOS PartnerKey (runs once under the stock Zyxel firmware as root,
# early in rcS, before the stock system starts; stock BusyBox 1.19, no Python).
#
# install (default), for ANY stock NAS542:
#   1. checks the flash layout (/proc/mtd) and the env structure (Barebox
#      envfs with CRCs, settled stock slot curr_bootfrom = next_bootfrom = A)
#      and that kernel<A> holds a valid uImage (CRC): nothing device specific
#      (MAC, serial, hashes) is compared against fixed values
#   2. backs up env and both kernel partitions twice each (compared), then
#      the whole flash (SPI raw, NAND with OOB) with SHA256SUMS, drops the
#      page cache and re-reads every backup file against SHA256SUMS
#   3. saves the stock configuration /etc/zyxel as etc-zyxel.tar (way B)
#   4. builds THIS device's UntrashOS env from its own env (ztpk env-untrash:
#      only /bin/init gains a call of the new /bin/untrash_loader, which boots
#      the loader from the INACTIVE kernel slot X; the stock boot follows when
#      that returns) and records everything in device.env (slots, hashes and
#      the stock MACs, which UntrashOS keeps)
#   5. writes the loader to kernel<X> and the new env, reading back both; on
#      any failure the backup is written back
#   6. powers the NAS off (the next start boots the loader -> installer)
#
# rollback (marker UNTRASH/ROLLBACK, way D; normally reached after the loader
# erased its own kernel<X>, so Barebox fell back to the stock boot):
#   writes env and kernel<X> of the install run back, checked against the
#   hashes that run recorded in device.env, reads back, powers off.
#
# update (manifest UPDATE=1): replaces only the loader in kernel<X> of an
#   installed NAS (env unchanged, must equal ENV_NEW of the install run).
#   On an installed NAS the stick also carries UNTRASH/ROLLBACK: the loader
#   then sets the RAM mark and resets, Barebox skips the loader, the stock
#   firmware runs this script; UPDATE=1 takes precedence and ROLLBACK goes.
#
# Every run first makes the full flash backup (UNTRASH/<mode>-<stamp>/flash/).
# A finished or failed run leaves <MODE>_DONE / <MODE>_FAILED; with either
# marker present the script does nothing (no repeated writes).
# Stick inputs (UNTRASH/): manifest.env (VERSION, LOADER_SHA256, ZTPK_SHA256,
# UPDATE), loader.uImage (padded to 10 MiB with 0xff), ztpk (static ARM).
###############################################################################
export PATH=${UNTRASH_TEST_PATH:+$UNTRASH_TEST_PATH:}/firmware/sbin:/firmware/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
KEY=${UNTRASH_TEST_KEY:-/mnt/partnerkey}
DEV=${UNTRASH_TEST_DEV:-/dev}		# test hooks (PC dry run only)
PROCMTD=${UNTRASH_TEST_PROCMTD:-/proc/mtd}
U="$KEY/UNTRASH"
ONCE=${UNTRASH_TEST_ONCE:-/tmp/untrash-install-ran}
[ -e "$ONCE" ] && exit 1
: >"$ONCE"
[ -f "$U/manifest.env" ] || exit 1
. "$U/manifest.env"
MODE=install
[ -e "$U/ROLLBACK" ] && MODE=rollback
# UPDATE=1 wins: on an installed NAS the stock firmware only runs after the
# loader's RAM mark, which the loader sets for UNTRASH/ROLLBACK (way D stage
# 1).  A stick with both asks for a loader update; ROLLBACK was only the way
# to the stock boot and is removed when the update run ends (see finish).
[ "${UPDATE:-0}" = 1 ] && MODE=update
MARK=$(echo $MODE | tr a-z A-Z)
[ -e "$U/${MARK}_DONE" ] || [ -e "$U/${MARK}_FAILED" ] || [ -e "$U/${MARK}_BUSY" ] && exit 1

STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null); [ -n "$STAMP" ] || STAMP="boot-$$"
OUT="$U/$MODE-$STAMP"
mkdir -p "$OUT" || exit 1
LOG="$OUT/install.log"
: >"$U/${MARK}_BUSY"
log() { echo "$(date +%T 2>/dev/null) $*" >>"$LOG"; sync; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
# The stock BusyBox ash lacks the POSIX builtin for tool lookup; search PATH.
tool() {
	IFS_SAVE=$IFS; IFS=:
	for d in $PATH; do [ -x "$d/$1" ] && { IFS=$IFS_SAVE; echo "$d/$1"; return 0; }; done
	IFS=$IFS_SAVE; return 1
}
finish() {	# $1 = DONE|FAILED, $2 = reason
	log "RESULT $1 $2"
	rm -f "$U/${MARK}_BUSY"; echo "$2" >"$U/${MARK}_$1"
	# the loader must not take a leftover ROLLBACK for a failed way D
	[ $MODE = update ] && rm -f "$U/ROLLBACK" "$U/rollback-stage1.log"
	sync; sync
	log "poweroff"
	[ -n "$UNTRASH_TEST_DEV" ] || { poweroff 2>/dev/null || halt 2>/dev/null; sleep 30; }
	exit 1	# 1 = let the stock boot continue if poweroff did not happen
}

log "UntrashOS PartnerKey mode=$MODE, stick version=$VERSION"

# ---------------------------------------------------------------- 1. layout
grep -q 'ZyXEL\|Zyxel\|NAS542\|B403' /proc/cmdline /etc/modelname /firmware/mnt/info/modelname 2>/dev/null || log "model string not found (continuing, layout check decides)"
cp $PROCMTD "$OUT/proc-mtd.txt"
LAYOUT='mtd0: 00040000 00010000 "uloader"
mtd1: 00080000 00010000 "barebox"
mtd2: 00040000 00010000 "env"
mtd3: 00a00000 00020000 "config"
mtd4: 00a00000 00020000 "kernel1"
mtd5: 06e00000 00020000 "rootfs1"
mtd6: 00a00000 00020000 "kernel2"
mtd7: 06e00000 00020000 "rootfs2"
mtd8: 00600000 00020000 "reserved"'
[ "$(grep '^mtd[0-9]*:' $PROCMTD)" = "$LAYOUT" ] || finish FAILED "flash layout is not the NAS542 stock layout (see proc-mtd.txt)"
FLASH_ERASE=$(tool flash_erase) || finish FAILED "flash_erase missing"
NANDWRITE=$(tool nandwrite) || finish FAILED "nandwrite missing"
NANDDUMP=$(tool nanddump) || NANDDUMP=
log "tools: $FLASH_ERASE $NANDWRITE ${NANDDUMP:-no-nanddump}"

# ztpk (static ARM helper) from the stick, checked, run from /tmp (the stick
# may be mounted noexec)
ZTPK=${UNTRASH_TEST_ZTPK:-/tmp/untrash-ztpk}
if [ -z "$UNTRASH_TEST_ZTPK" ]; then
	[ "$(sha "$U/ztpk")" = "$ZTPK_SHA256" ] || finish FAILED "ztpk hash mismatch"
	cp "$U/ztpk" $ZTPK && chmod 755 $ZTPK || finish FAILED "cannot copy ztpk to /tmp"
fi
$ZTPK env-check /dev/null >/dev/null 2>&1; [ $? = 1 ] || finish FAILED "ztpk does not run on this firmware"

# ------------------------------------------------------- 2. backups (twice)
backup2() {	# $1 = mtd number
	dd if=$DEV/mtd$1 of="$OUT/mtd$1-before-a.bin" bs=65536 2>>"$LOG" || finish FAILED "read mtd$1 failed"
	dd if=$DEV/mtd$1 of="$OUT/mtd$1-before-b.bin" bs=65536 2>>"$LOG" || finish FAILED "read mtd$1 failed"
	cmp -s "$OUT/mtd$1-before-a.bin" "$OUT/mtd$1-before-b.bin" || finish FAILED "mtd$1 reads differ"
	log "mtd$1 backup sha256=$(sha "$OUT/mtd$1-before-a.bin")"
}
backup2 2; backup2 4; backup2 6

# full flash backup (read-only): SPI raw, NAND with OOB incl. bad blocks
mkdir -p "$OUT/flash"
grep '^mtd[0-8]:' $PROCMTD | while IFS=: read -r m rest; do
	n=${m#mtd}
	if [ $n -le 2 ]; then
		dd if=$DEV/mtd$n of="$OUT/flash/$m.raw.bin" bs=65536 2>>"$LOG"
	elif [ -n "$NANDDUMP" ]; then
		"$NANDDUMP" --quiet --oob --bb=dumpbad -f "$OUT/flash/$m.nand-oob.bin" $DEV/mtd$n >>"$LOG" 2>&1 ||
			dd if=$DEV/mtd$n of="$OUT/flash/$m.data.bin" bs=65536 2>>"$LOG"
	else
		dd if=$DEV/mtd$n of="$OUT/flash/$m.data.bin" bs=65536 2>>"$LOG"
	fi
done
(cd "$OUT/flash" && sha256sum *.bin >SHA256SUMS) 2>>"$LOG"
# read everything back from the stick, not from the page cache
sync; (echo 3 >/proc/sys/vm/drop_caches) 2>/dev/null
bad=0; nf=0
while read -r h f; do
	nf=$((nf + 1))
	[ "$(sha "$OUT/flash/$f")" = "$h" ] || { log "backup re-read MISMATCH $f"; bad=1; }
done <"$OUT/flash/SHA256SUMS"
[ $nf = 9 ] && [ $bad = 0 ] || finish FAILED "flash backup on the stick does not verify ($nf files)"
echo "files=$nf verified=$(date +%Y%m%d-%H%M%S 2>/dev/null)" >"$OUT/flash/VERIFIED"
log "full flash backup: $nf files, $(du -sk "$OUT/flash" | cut -f1) KiB, re-read and verified"

# ------------------------------------------ 3. stock configuration (way B)
# rcS runs the PartnerKey before it mounts /etc/zyxel (UBIFS volume
# ubi_config on NAND "config"), so attach it here exactly like rcS does
# (ubiattach -m N -d N), mount it read-only, tar it, unmount and detach
# again.  A failure only costs way B (the config stays in NAND, nothing is
# written to it): it is logged, the run continues.  Every run of this script
# ends in poweroff, so rcS never mounts the config after us.
save_config() {
	if [ -n "$UNTRASH_TEST_CFGDIR" ]; then
		tar -cf "$OUT/etc-zyxel.tar" -C "$UNTRASH_TEST_CFGDIR" . 2>>"$LOG"; return $?
	fi
	[ -z "$UNTRASH_TEST_DEV" ] || return 1	# PC dry run: never touch the host's UBI
	n=3
	m=$(grep ' ubifs ' /proc/mounts | grep 'ubi_config' | cut -d' ' -f2 | head -1)
	if [ -n "$m" ]; then
		tar -cf "$OUT/etc-zyxel.tar" -C "$m" . 2>>"$LOG"; return $?
	fi
	att=0
	if [ ! -e /sys/class/ubi/ubi$n ]; then
		ubiattach -m $n -d $n >>"$LOG" 2>&1 || { log "config: ubiattach mtd$n failed"; return 1; }
		att=1
	fi
	mkdir -p /tmp/untrash-cfg
	r=1
	if mount -t ubifs -o ro ubi$n:ubi_config /tmp/untrash-cfg 2>>"$LOG"; then
		tar -cf "$OUT/etc-zyxel.tar" -C /tmp/untrash-cfg . 2>>"$LOG" && r=0
		umount /tmp/untrash-cfg 2>>"$LOG" || { log "config: umount failed"; r=1; }
	else
		log "config: mount ubi$n:ubi_config failed"
	fi
	[ $att = 1 ] && { ubidetach -m $n >>"$LOG" 2>&1 || log "config: ubidetach mtd$n failed"; }
	return $r
}
if [ $MODE != rollback ]; then
	if save_config && tar -tf "$OUT/etc-zyxel.tar" 2>/dev/null | grep -q 'ugs_conf.db$'; then
		sha "$OUT/etc-zyxel.tar" >"$OUT/etc-zyxel.tar.sha256"
		log "stock config saved: etc-zyxel.tar $(wc -c <"$OUT/etc-zyxel.tar" | tr -d ' ') bytes sha256=$(cat "$OUT/etc-zyxel.tar.sha256")"
	else
		rm -f "$OUT/etc-zyxel.tar"
		log "WARNING stock config NOT saved (way B needs it; the config stays untouched in NAND)"
	fi
fi

# ------------------------------------------------------------- write helpers
write_mtd() {	# $1 = mtd number, $2 = full-partition image; read back, compare
	"$FLASH_ERASE" $DEV/mtd$1 0 0 >>"$LOG" 2>&1 || return 1
	"$NANDWRITE" -p $DEV/mtd$1 "$2" >>"$LOG" 2>&1 || return 1
	sync
	dd if=$DEV/mtd$1 of="$OUT/mtd$1-readback.bin" bs=65536 2>>"$LOG" || return 1
	r=$(sha "$OUT/mtd$1-readback.bin"); i=$(sha "$2")
	log "verify mtd$1 readback=$r image=$i"
	[ "$r" = "$i" ]
}
restore() {	# $1 = mtd number: back to the state of this run's start
	log "RESTORE mtd$1 from backup"
	if write_mtd "$1" "$OUT/mtd$1-before-a.bin"; then log "RESTORE mtd$1 ok"
	else log "RESTORE mtd$1 FAILED - flash backup in $OUT/flash, see docs/recovery/p1-platform-backup-and-loader.md"; fi
}
envget() { $ZTPK env-get "$1" "$2" 2>/dev/null; }
# newest install run that completed (device.env written before its writes,
# result line DONE in its log)
install_run() {
	ls -d "$U"/install-* 2>/dev/null | while read -r d; do
		[ -f "$d/device.env" ] && grep -q 'RESULT DONE' "$d/install.log" 2>/dev/null && echo "$d"
	done | tail -1
}

# --------------------------------------------------------------- rollback
if [ $MODE = rollback ]; then
	SRC=$(install_run)
	[ -n "$SRC" ] || finish FAILED "no completed install run (install-*/device.env) on the stick"
	. "$SRC/device.env"
	log "rollback source $SRC: loader slot $LOADER_SLOT (mtd$LOADER_MTD), stock slot $ACTIVE_SLOT"
	[ "$(sha "$SRC/mtd2-before-a.bin")" = "$ENV_OLD_SHA256" ] || finish FAILED "saved env does not match its recorded hash"
	[ "$(sha "$SRC/mtd$LOADER_MTD-before-a.bin")" = "$KX_OLD_SHA256" ] || finish FAILED "saved kernel$LOADER_SLOT does not match its recorded hash"
	ecur=$(sha "$OUT/mtd2-before-a.bin"); kcur=$(sha "$OUT/mtd$LOADER_MTD-before-a.bin")
	log "rollback: current env $ecur kernel$LOADER_SLOT $kcur"
	if [ "$ecur" = "$ENV_OLD_SHA256" ] && [ "$kcur" = "$KX_OLD_SHA256" ]; then
		finish DONE "flash already in the stock state of $SRC"
	fi
	[ "$ecur" = "$ENV_NEW_SHA256" ] || [ "$ecur" = "$ENV_OLD_SHA256" ] ||
		finish FAILED "env was changed since the install (neither the UntrashOS nor the stock env), not touched"
	if [ "$kcur" != "$KX_OLD_SHA256" ]; then
		write_mtd $LOADER_MTD "$SRC/mtd$LOADER_MTD-before-a.bin" ||
			{ restore $LOADER_MTD; finish FAILED "kernel$LOADER_SLOT rollback write failed (state of this run restored)"; }
	fi
	if [ "$ecur" != "$ENV_OLD_SHA256" ]; then
		write_mtd 2 "$SRC/mtd2-before-a.bin" ||
			{ restore 2; finish FAILED "env rollback write failed (state of this run restored)"; }
	fi
	finish DONE "stock env and kernel$LOADER_SLOT restored from $(basename "$SRC")"
fi

# -------------------------------------------------- 4. inputs and structure
[ "$(sha "$U/loader.uImage")" = "$LOADER_SHA256" ] || finish FAILED "loader.uImage hash mismatch"
[ "$(wc -c <"$U/loader.uImage" | tr -d ' ')" = 10485760 ] || finish FAILED "loader.uImage is not padded to 10 MiB"
case $($ZTPK uimage-check "$U/loader.uImage") in OK*) ;; *) finish FAILED "loader.uImage is not a valid uImage" ;; esac
r=$($ZTPK env-check "$OUT/mtd2-before-a.bin"); log "env: $r"
case $r in OK*) ;; *) finish FAILED "env is not a valid Barebox envfs ($r)" ;; esac
A=$(envget "$OUT/mtd2-before-a.bin" curr_bootfrom); NB=$(envget "$OUT/mtd2-before-a.bin" next_bootfrom)
log "stock slot: curr_bootfrom=$A next_bootfrom=$NB"

if [ $MODE = update ]; then
	SRC=$(install_run)
	[ -n "$SRC" ] || finish FAILED "update: no completed install run on the stick"
	. "$SRC/device.env"
	[ "$(sha "$OUT/mtd2-before-a.bin")" = "$ENV_NEW_SHA256" ] || finish FAILED "update: env is not the UntrashOS env of $(basename "$SRC")"
	case $($ZTPK uimage-check "$OUT/mtd$LOADER_MTD-before-a.bin") in
	OK*name=ZT*) ;; *) finish FAILED "update: kernel$LOADER_SLOT holds no UntrashOS loader" ;; esac
	log "pre-update checks passed (loader slot $LOADER_SLOT)"
	write_mtd $LOADER_MTD "$U/loader.uImage" || { restore $LOADER_MTD; finish FAILED "kernel$LOADER_SLOT write/verify failed (old loader restored)"; }
	finish DONE "loader in kernel$LOADER_SLOT updated ($VERSION), env unchanged"
fi

case $A in 1) X=2 ;; 2) X=1 ;; *) finish FAILED "curr_bootfrom '$A' is not 1 or 2" ;; esac
[ "$NB" = "$A" ] || finish FAILED "stock firmware slot switch pending (next_bootfrom=$NB): start the stock firmware once without the stick"
AM=$((2 + 2 * A)); XM=$((2 + 2 * X))
r=$($ZTPK uimage-check "$OUT/mtd$AM-before-a.bin"); log "kernel$A (active): $r"
case $r in OK*) ;; *) finish FAILED "active stock kernel$A is no valid uImage ($r)" ;; esac
log "kernel$X (gets the loader, saved): $($ZTPK uimage-check "$OUT/mtd$XM-before-a.bin")"

r=$($ZTPK env-untrash "$OUT/mtd2-before-a.bin" "$OUT/env-untrash.bin"); log "new env: $r"
[ "$r" = "OK slot=$X" ] || finish FAILED "cannot build the UntrashOS env: $r"
case $($ZTPK env-check "$OUT/env-untrash.bin") in OK*) ;; *) finish FAILED "built env does not check" ;; esac
# stock MACs (Barebox ethaddr = eth0, eth2addr = eth1): UntrashOS keeps them
macok() { case $1 in [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) echo $1 ;; esac; }
M0=$(macok "$(envget "$OUT/mtd2-before-a.bin" ethaddr)"); M1=$(macok "$(envget "$OUT/mtd2-before-a.bin" eth2addr)")
[ -n "$M0" ] || log "WARNING no valid ethaddr in the env (UntrashOS falls back to the driver's MAC)"
# stock model (the stock update writes its firmware header's model id and
# version per slot: B203 NAS520, B103 NAS540, B403 NAS542); UntrashOS shows
# the model and sizes the bays from it (board/nas542 untrash_model.py).
# device.env is sourced by later runs: no shell metacharacters, so
# V5.21(ABAG.15) is stored as V5.21.ABAG.15
MID=$(envget "$OUT/mtd2-before-a.bin" modelid_$A | tr -cd 'A-Za-z0-9' | cut -c1-8)
FWV=$(envget "$OUT/mtd2-before-a.bin" fwversion_$A | tr '(' '.' | tr -cd 'A-Za-z0-9.' | cut -c1-32)
log "stock model id ${MID:-unknown}, firmware ${FWV:-unknown}"
cat >"$OUT/device.env" <<D
ETH0_MAC=$M0
ETH1_MAC=$M1
MODEL_ID=$MID
FWVERSION=$FWV
ACTIVE_SLOT=$A
LOADER_SLOT=$X
LOADER_MTD=$XM
ENV_OLD_SHA256=$(sha "$OUT/mtd2-before-a.bin")
KX_OLD_SHA256=$(sha "$OUT/mtd$XM-before-a.bin")
KA_SHA256=$(sha "$OUT/mtd$AM-before-a.bin")
ENV_NEW_SHA256=$(sha "$OUT/env-untrash.bin")
LOADER_SHA256=$LOADER_SHA256
INSTALL_VERSION=$VERSION
D
sync
log "pre-install checks passed: loader -> kernel$X (mtd$XM), stock stays in kernel$A"

# ------------------------------------------------------------ 5. write
log "write loader to kernel$X"
write_mtd $XM "$U/loader.uImage" || { restore $XM; finish FAILED "kernel$X write/verify failed (restored)"; }
log "kernel$X written and verified"
log "write UntrashOS env"
write_mtd 2 "$OUT/env-untrash.bin" || { restore 2; restore $XM; finish FAILED "env write/verify failed (env and kernel$X restored)"; }
log "env written and verified"
finish DONE "loader in kernel$X, UntrashOS env active"
