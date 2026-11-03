.PHONY: help inputs nas-tools busybox kernel loader check-loader rootfs slot update stick test test-root test-services manual docs-check

# UntrashOS for the Zyxel NAS542 (docs/build.md).  Everything is built from
# this repository, the UntrashOS submodule (untrashos/, the device-independent
# part; untrashos/docs/board-interface.md), the board files (board/nas542/) plus the external inputs of tools/fetch-inputs.sh (kernel and
# kexec-tools and BusyBox source, PFE firmware, mkosi) and your slot signing key
# (inputs/keys/untrash-dev.sec).
# Output goes to build/.  Do not call this VERSION: GNU make forwards
# command-line variables to the kernel sub-make, where VERSION is Linux'.
RELEASE  ?= dev
B        := build
SLOT_IMG := $(B)/slot-$(RELEASE).img
UPDATE   := $(B)/untrash-$(RELEASE)-update.utslot
STICK    := $(B)/untrash-stick-$(RELEASE).img
MKOSI    ?= $(CURDIR)/inputs/mkosi/bin/mkosi
OS       := untrashos
BOARD    := board/nas542

help:
	@echo "UntrashOS for the Zyxel NAS542"
	@echo "  make inputs        download + verify external inputs (inputs/)"
	@echo "  make stick         loader + kernel + rootfs + slot -> $(STICK)"
	@echo "  make update        signed update file for Desk -> Updates -> $(UPDATE)"
	@echo "  make nas-tools|busybox|kernel|loader|rootfs|slot   single steps"
	@echo "  make check-loader  offline contract check of build/loader.uImage [LOADER_REF=x.uImage]"
	@echo "  make test          PC tests (no root)"
	@echo "  make test-root     PC tests that need sudo (md/LVM/loop), TOOLROOT=<dir>"
	@echo "  make test-services WebDAV (real Apache) + cloud (real rclone)"
	@echo "  make manual        user guide -> docs/user-guide/manual.html + PDF"
	@echo "  make docs-check    privacy check of the public docs"

inputs:
	tools/fetch-inputs.sh

nas-tools:
	nas-tools/build.sh

busybox:
	loader/busybox/build.sh

kernel:
	kernel/build-kernel.sh system

loader: nas-tools busybox
	kernel/build-kernel.sh loader
	$(MAKE) check-loader

# Offline contract check of the NAND loader: appended DTB, modules and their
# deps, console/FAT drivers, rc.ssh module list, zt-mount options
check-loader:
	python3 loader/slot/tests/check-loader.py $(B)/loader.uImage --build $(B)/kernel-loader $(if $(LOADER_REF),--ref $(LOADER_REF))

rootfs:
	cd $(OS)/image && $(MKOSI) -f build

slot: nas-tools
	ZT_PROFILE=release ZT_BOARD=$(BOARD) ZT_TOP=$(CURDIR) $(OS)/image/mkslot-erofs.sh $(B)/image/untrash-rootfs $(B)/kernel-system \
		$(RELEASE) $(SLOT_IMG) >$(SLOT_IMG:.img=.build.log)
	@grep -E "verity self-check|SLOT=" $(SLOT_IMG:.img=.build.log)

update: slot
	rm -rf $(B)/update-tree && mkdir -p $(B)/update-tree
	install/mk-stick-system.sh --install $(SLOT_IMG) $(SLOT_IMG:.img=.build.log) $(B)/update-tree >/dev/null
	cp $(B)/update-tree/UNTRASH/system/slot.utslot $(UPDATE)
	@echo "UPDATE=$(UPDATE)"

stick: loader kernel rootfs slot
	ZT_LOADER_BUILD=$(B)/kernel-loader install/mk-stick-image.sh $(B)/loader.uImage $(SLOT_IMG) \
		$(SLOT_IMG:.img=.build.log) $(RELEASE) $(STICK)

manual:
	python3 tools/manual/build.py

docs-check:
	@python3 $(OS)/tools/check_public_docs.py .

test:
	@if [ -f inputs/test/stock-env-mtd2.bin ]; then install/test-ztpk.sh && install/test-partnerkey-dryrun.sh; \
	 else echo "skip PartnerKey dry runs (needs inputs/test/, docs/build.md)"; fi
	$(MAKE) -C $(OS) test BOARD_ROOTFS=$(CURDIR)/$(BOARD)/rootfs
	python3 $(OS)/image/tests/test_exec_bits.py $(BOARD)/rootfs
	python3 $(BOARD)/tests/test_boot_health_pfe_host.py
	@if [ -f inputs/test/stock-pfe.ko -a -f $(B)/kernel-system/drivers/pfe_ctrl/pfe.ko ]; then \
	  python3 tools/pfe/check-fw12-layout.py $(B)/kernel-system/drivers/pfe_ctrl/pfe.ko inputs/test/stock-pfe.ko; \
	 else echo "skip PFE firmware layout check (needs make kernel + inputs/test/stock-pfe.ko)"; fi
	python3 tools/manual/build.py --check
	python3 $(BOARD)/tests/test_bays.py

# APACHEROOT: unpacked apache2-bin libapr1 libaprutil1 libapache2-mod-authnz-external
# debs; RCLONEROOT: unpacked rclone deb (apt-get download + dpkg-deb -x)
test-services:
	@test -n "$(APACHEROOT)" -a -n "$(RCLONEROOT)" || { echo "APACHEROOT=<dir> RCLONEROOT=<dir> needed"; exit 1; }
	python3 $(OS)/image/tests/test-webdav-host.py $(APACHEROOT)
	python3 $(OS)/image/tests/test-cloud-host.py $(RCLONEROOT)
	python3 $(OS)/image/tests/test-copybtn-host.py $(RCLONEROOT)

# TOOLROOT: unpacked mdadm/lvm2/dmsetup debs (loader/slot/tests/test-zt-blk-host.sh)
test-root:
	@test -n "$(TOOLROOT)" || { echo "TOOLROOT=<dir> needed"; exit 1; }
	sudo loader/slot/tests/test-zt-loader-host.sh $(TOOLROOT)
	sudo $(BOARD)/tests/test-installer-keep-host.sh $(TOOLROOT)
	sudo ZT_BOARD_ROOTFS=$(CURDIR)/$(BOARD)/rootfs $(OS)/image/tests/test-storage-host.sh $(TOOLROOT)
	sudo python3 $(OS)/image/tests/test-iscsi-host.py
	python3 $(OS)/image/tests/test_mesh_firewall_root.py
