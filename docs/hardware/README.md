# Zyxel NAS542 — hardware reference

The NAS542 as UntrashOS uses it: SoC, memory and register map, boot chain,
flash layout, board peripherals and the pitfalls of the platform.  It is meant
to save a successor project (another kernel generation, another distribution)
the reverse-engineering.

Facts carry their evidence: `[HW]` observed on the NAS, `[DUMP]` taken from the
stock flash/firmware, `[DEC]` from disassembling stock binaries, `[DERIVED]`
computed from those, `[HYP]` plausible but unconfirmed.  Installation-specific
values (MAC addresses, IP addresses, serials) are deliberately left out.

The kernel side of everything below is in `kernel/patches/` (Linux 6.6.145):
patch 0001 is the reconstructed platform (clocks, reset, timer, pinctrl, GPIO,
NAND, I2C, SerDes, PCIe, USB3, watchdog, poweroff, device tree), the rest are
single features.  The device tree is `arch/arm/boot/dts/mindspeed/zyxel-nas542.dts`.

## 1. SoC

- Mindspeed **Comcerto 2000 ("C2K")**, later Freescale/NXP **QorIQ LS1024A**:
  dual **ARM Cortex-A9 r2p1** (ARMv7-A, MIDR `0x412fc091`), SMP, PL310 L2
  256 KiB 8-way (CACHE_ID `0x410000c8`), on-chip **PFE** (Packet Forwarding
  Engine) as the network datapath.  `[HW]`
- Stock software: Barebox "Barebox-C2K" with a `uloader` first stage, Linux
  3.2.54 (`Machine: Comcerto 2000 EVM`), BusyBox userland.  `[HW]/[DUMP]`
- CPU 1.2 GHz (PLL0 2400 MHz / 2), A9 peripheral clock 600 MHz (TWD 300 MHz),
  DDR3 533 MHz (PLL3 1066 / 2), **250 MHz peripheral clock** for timer and UART,
  GEMAC 125 MHz, `axi` 250 MHz, `hfe_core` 500 MHz.  `[HW]/[DERIVED]`

## 2. Memory map

| Region | Physical | Note |
|---|---|---|
| DRAM | 1 GiB, Linux System RAM `0x04000000–0x2fffffff` in 6.6 | `[HW]` |
| Kernel base / `zreladdr` | **`0x04008000`** | uImage load/entry **`0x0f008000`** (transport copy) `[HW]` |
| PFE DDR (reserve!) | `0x03400000–0x03ffffff` (12 MiB) | stock window; Barebox uses the top 8 MiB `0x03800000` `[HW]` |
| Clock/reset controller | `0x904b0000` | resets at `+0x54` (PFE = bit 3, assert = set) `[HW]` |
| GPIO + pinmux | **`0x90470000`** | pinmux `+0x58`, output `+0xD0` `[HW]` |
| PWM (fan, buzzer) | `0x90458000` | `+0x00` clkdiv/enable; PWM4 fan `+0x28/+0x2C`; PWM5 buzzer `+0x30/+0x34` `[HW]` |
| Timer block | `0x90450000` | Comcerto timer; AXI watchdog at `+0xd0` `[HW]` |
| UART0 (ttyS0) | `0x96400000` | **Synopsys DW APB UART** (`snps,dw-apb-uart`), 250 MHz, GIC 59 `[HW]` |
| SPI0 / SPI1 | `0x90498000` / `0x96500000` | `[HW]` |
| AHCI (2 ports) | `0x9d000000`, GIC 48 | two of the four bays (which ones: §9) `[HW]` |
| xHCI | `0x9f000000`, GIC 54 | internal ASMedia hub `174c:2074/3074` `[HW]` |
| PCIe root port | `0x98000000` | ASM1061 behind it, see §5 `[HW]` |
| PFE CBUS (host view) | `0x9c000000` (16 MiB) | `apb 0x90500000`, `iram 0x83000000`, `ipsec 0x9a000000`, IRQ `hif` = GIC SPI 4 `[HW]/[DUMP]` |

**Pitfall: there is no uniform virtual→physical I/O offset.**  Each block has its
own static mapping in the stock kernel (`0x96500000`→`0xC0808000`,
`0x90498000`→`0xC080A000`, `0xf0970000`→`0x90470000`).  Assuming one offset
put GPIO at a wrong address and caused an external abort.  Cross-check every
MMIO base against something proven on hardware (the Barebox `mw` commands of
the stock environment work).

PFE: the PE firmware sees CBUS at `0xc0000000 + offset`; only values written
*into* PE registers use that domain (`pfe = host - 0x9c000000 + 0xc0000000`).
Port mapping `[DUMP]`: eth0 = GEMAC1, FPP physical port 0, MDIO bus 0, **PHY 4
(Realtek RTL8211E, `0x001cc915`)**; eth1 = GEMAC2, port 1, PHY 6; MDIO divider 96.

## 3. Flash and boot chain

SPI NOR `[DUMP]`: `256k(uloader)ro, 512k(barebox)ro, 256k(env)`.
NAND `[DUMP]` (Spansion S34ML02G1, 256 MiB, 2 KiB pages, 128 KiB blocks):

```
10M(config) 10M(kernel1) 110M(rootfs1) 10M(kernel2) 110M(rootfs2) -(reserved)
```

Stock boots `kernel<curr_bootfrom>` (1 or 2, from the env) with root on UBI
(`ubi.mtd=2,2048`).  The Barebox environment is a **Barebox envfs** in the SPI
`env` partition: header magic, CRC32 over data and superblock, one inode per
file (`install/envfs.py` reads and writes it).  The stock environment
carries the device MAC addresses; keep dumps of it private.

**UntrashOS boot chain** `[HW]`:

1. Barebox runs the UntrashOS environment script (`install/envfs.py`, LOADER
   template).  It switches fan and GPIOs on (the same `mw` writes as stock) and
   boots the **loader** from `kernel2` with `bootm`.
2. The loader (Linux 6.6 + initramfs, `loader/`) powers the disk bays like the
   stock `platform_init` (§5), assembles the stock md/LVM volumes **read-only**,
   finds `/.untrash/bootstate`, verifies the signed slot file (Ed25519,
   `untrashos/slot/zt-sig.c`) and **kexec**s the system kernel.
3. The system kernel boots the erofs + dm-verity root of the slot
   (`untrashos/image/`), with state on an ext4 image file on the data volume.
4. A/B slots: `/.untrash/bootstate` (`pref`, tries per slot, `good`); a slot
   that does not confirm itself (`untrash-mark-good`) loses a try, after three
   the loader takes the other slot.

**Way back to stock without UART** (`[HW]`, "way D"): the loader writes a
16-byte mark into RAM at **`0x2e000000`** and resets; the environment script
compares it with Barebox `memcmp` and then skips the loader, so the unchanged
stock firmware boots.  Its PartnerKey hook (below) then performs a loader update
or the full restore.  RAM survives the reset of this board.

**PartnerKey** `[DEC]`: the stock firmware runs `usb_key_func.sh` from a USB
stick that also carries `nas5xx_check_file`.  UntrashOS uses this as its
installer entry (`install/partnerkey/`): backup of env/kernel partitions to
the stick, write of the loader into `kernel2`, read-back verification.

## 4. Watchdog, reset, power

- **AXI watchdog** in the timer block (`+0xd0`), driver `ls1024a_wdt`,
  **maximum timeout ~17 s** (32-bit counter at 250 MHz).  It stays armed across
  kexec; feed it early (the loader's BusyBox `watchdog`, `untrash-init` until
  `exec systemd`, then `untrash-wdt`).  `[HW]`
- **Pitfall:** systemd does not feed the watchdog while PID 1 is busy with a
  `daemon-reload`.  Under load a reload took >15 s and reset the NAS.  UntrashOS
  therefore feeds it from a real-time process (`untrashos/image/tools/untrash-wdt.c`)
  and keeps only the reboot watchdog in systemd.  `[HW]`
- **Reset:** the stock global reset (clock/reset controller) restarts the
  board but does **not** power-cycle the disks.  After such a warm reset the
  disk in bay 1 was not ready in time (SATA link down after 22 s); the loader
  now waits and re-probes the ports (`/sys/class/scsi_host/*/scan`).  `[HW]`
- **Power off:** GPIO15 high (driver in patch 0001).  `[HW]`
- **Board MCU** at I2C bus 0 address `0x0a` `[DEC]/[HW]`: temperature register
  `0x07`, fan tachometer `0x08`; SMBus word write to register `0x0a` =
  (command, value): command `0x07` power on after power loss (`0x0107` on,
  `0x0007` off), command `0x06` Wake-on-LAN (`0x0006` on, `0x0306` off); query
  by writing the command to `0x0b` and reading `0x0b`.
- **RTC** at I2C bus 0 `0x68`: **HT1382**, not DS1307/DS1337 (with rtc-ds1307
  date, month and weekday were shifted).  Registers 0–6 BCD, `0x07` bit 7 write
  protect; alarm `0x0b` min, `0x0c` hour, `0x0d` date (bit 7 = compare), reading
  `0x08` clears the flag.  The alarm is wired to the MCU (scheduled power-on),
  not to the SoC.  Driver `rtc-ht1382` (patches 0011, 0014).  `[HW]/[DEC]`

## 5. Disks, PCIe and USB

- Bays `[HW]`: detect GPIO 0–3 (low = present); power HD1 = GPIO8+54,
  HD2 = GPIO9+52, HD3 = GPIO10+50, HD4 = GPIO11+48.  Stock order: HD1+HD3, wait
  6 s, HD2+HD4, wait 6 s.  LEDs: `hdd1..4-green` = GPIO 48/50/52/54,
  `hdd1..4-red` = 49/51/53/55 (device tree).
- **Two bays on the SoC AHCI, two behind an ASMedia ASM1061** (PCIe x1, 2-port
  AHCI, `1b21:0612`) on the backplane (PCB `45-403-000031`); the stock firmware
  drives all four bays.  On the bench without the backplane there is no PCIe
  endpoint, so any kernel logs a failed link there ("PCIe0: Link Up Failed").
  Linux 6.6 needs **bit 0 of `SD_CMU_CTL`
  set for PCIe too** (patch 0015); then CMU, root port and endpoint come up and
  the generic `ahci` driver serves the other two bays.  The PCIe and AHCI
  modules must be loaded by the loader **and** the slot initrd.  `[HW]`
  Every system start therefore goes through the slot initrd, a slot partition
  (way A) as well (`cmdline_part`, `untrash.part=`).
- USB: xHCI with an internal hub; USB power = GPIO14 (stock drives it high).
- Buttons `[HW]`: GPIO4 power (`KEY_POWER`), GPIO5 RESET (`KEY_RESTART`, active
  low), GPIO6 COPY (`KEY_PROG1`, active low); stock meaning: RESET 2 s = network
  and admin password, 7 s = factory defaults; COPY = USB copy/sync.

## 6. Fan and buzzer

- **Fan:** PWM4 on GPIO12; the stock environment starts it with
  `mw 0x90458000 0x80000001; mw 0x90458028 0x80001388; mw 0x9045802C 0x00000fa0`
  (period 5000, low time 4000).  Temperature from the MCU (§4).  `zt-fan`
  (`nas-tools/zt-fan.c`) regulates it.  Start the fan early in every boot path.
- **Buzzer:** **passive**, PWM5 on GPIO13.  `[DEC]` stock `set_buzzer` toggles
  bits `0xb000` of `0x90458034` with `udelay(500)` = 1 kHz.  A melody needs
  exact busy-wait timing: with HZ=100 and no high-resolution timers an hrtimer
  waveform was inaudible.  Driver `nas542-buzzer` (patch 0013, sysfs `play`
  "hz ms").

## 7. Network (PFE)

The vendor PFE driver `pfe_ctrl` (13_00_2, from the scpcom LS1024A kernel,
patches 0003/0004/0008) runs on Linux 6.6.  Driver and PE firmware share
memory (sections `.class_dmem_sh`, `.tmu_dmem_sh`, `.util_dmem_sh`,
`.class_pe_lmem_sh`, `.util_ddr_sh`, each variable in its own section, sorted
by name, 8-byte aligned by `control_link.lds`); that layout must match the
firmware byte for byte.

- The stock firmware is **pfe_12_00_2** (with stock driver
  `pfe_ctrl_12_00_2`; GPL source of that version: Synology,
  github.com/scpcom/linux branch `dsgpl-3.2.y-comcerto2k`).  It is only in the
  initramfs of the stock kernel (NAND `kernel1` or `kernel2`: uImage, zImage with a gzip
  kernel image that carries the initramfs as a second gzip stream,
  `lib/firmware/*_c2000*.elf`), on every NAS542.  The stock root file system
  (NAND `rootfs1`, UBI volume `ubi_rootfs1`) does **not** contain it `[HW]`.
- pfe_13 adds three `resume` words, a GRE tunnel cache and a bigger tunnel
  context (352 instead of 328 bytes); everything behind them moves.
  `CONFIG_PFE_CTRL_FW12` (patch 0016) restores the pfe_12 layout;
  `tools/pfe/check-fw12-layout.py` compares a built `pfe.ko` with the stock
  `pfe.ko` (whose symbol table survived) section by section.
- UntrashOS extracts the stock set once to `/state/firmware/pfe`
  (`untrash-pfe-firmware` + `untrash-pfe-extract`, before the driver loads;
  source: the stock kernel copy the install run saved to the stick
  (`install-*/mtd<4|6>-before-a.bin`); the installer seeds the state of the
  installed system with it; reading `kernel<ACTIVE_SLOT>` from the NAND is
  only the fallback, because the NAND driver cannot yet correct ECC errors;
  log in `/state/firmware/pfe.log`) and accepts only version `pfe_12_00_2`
  with the expected `.dmem_sh` sizes `[HW]`.
- The system kernel is started by kexec from the loader, which has read the
  NAND already: the ECC engine is then in the read state, not in the Barebox
  write/generate state.  The NAND driver accepts exactly that state (patch
  0017); before it, the system kernel had no NAND at all `[HW]`.
- The PFE must stop its DMA before kexec/reboot (patch 0008).  The stock
  `pfe.ko` itself cannot be loaded under 6.6 (163 unresolved symbols).

## 8. Software pitfalls

1. `zreladdr` **must** be `0x04008000`, uImage load/entry `0x0f008000`; never
   enable `CONFIG_AUTO_ZRELADDR`; always `ARCH=arm`.
2. No uniform I/O offset (§2).
3. Never `usleep_range()`/`fsleep()` in early probe paths of a kernel that
   only has the jiffies clocksource and low-resolution timers: it never returns
   and looks like a hard hang (patch 0009 is one instance).
4. UART0 is a DesignWare UART: without `SERIAL_8250_DW` there is no console.
   Stopping a getty on ttyS0 while the console is busy wedges the CPU.
5. The loader's modules are **not** the system's: every driver the loader needs
   (AHCI, PCIe, md, dm, FAT and its NLS charsets) must be in its initramfs; the
   slot initrd sees the system kernel's defaults.  `make check-loader` checks
   the loader contract offline.
6. Go binaries (rclone) need `CONFIG_KUSER_HELPERS=y` on this ARMv7.
7. Debian `minidlna` rescans the whole library on every start (`-r`) and drops
   its database when its `media_dir` set changes; start it only after the data
   volumes are mounted.
8. A stock md array that is already active must not get `mdadm --readwrite`
   again (EBUSY); check `array_state` first.  An LV made by the initrd has no
   `/dev/vg/lv` node until `vgmknodes`.

## 9. Open points

- Physical bay ↔ controller port mapping and the ASM1061 PERST#/power net are
  not traced.
- RTC alarm (scheduled power-on) is implemented but not observed on hardware.
- GIC/SCU base addresses are taken from the working reconstruction, not read
  from hardware.
