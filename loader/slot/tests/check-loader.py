#!/usr/bin/env python3
"""Offline contract check for an UntrashOS NAND loader uImage (no hardware).

  check-loader.py LOADER.uImage [--build DIR] [--ref REF.uImage] [--repo ROOT]

Each rule covers a failure that would otherwise only show on the NAS:
  - console or FAT/NLS driver missing (rc.ssh dies at the console redirect,
    the FAT stick is invisible)
  - FAT mount with the VFS flag "rw" passed as filesystem data
  - modules missing from the initramfs (rc.ssh skips them silently: no USB,
    AHCI, md/dm, watchdog or I2C) or no device tree appended to the zImage
  - PCIe (ASM1061, bays 2+4) and PCI ahci loaded only with an operator key:
    the release loader would see 2/4 stock array members
  - zreladdr / load address
The loader's own initramfs is extracted from the uImage itself (not from a
cpio file next to it), so the check sees exactly what NAND will boot.
--build DIR  the kernel build dir: .config (built-in or module) and zreladdr
--ref        a known-good loader: module set must not shrink
Exit 0 = all checks passed; every failure is printed.
"""
import argparse, os, re, struct, sys, zlib

FAIL = []
def fail(msg): FAIL.append(msg); print('FAIL', msg)
def ok(msg): print('ok  ', msg)
def warn(msg): print('WARN', msg)

LOAD = 0x0f008000
SLOT_BYTES = 10 * 1024 * 1024

# Modules the release loader needs at run time (rc.ssh + zt-loader).  Each is
# satisfied by a .ko in lib/modules/zt or by the matching CONFIG_*=y.
NEEDED = {
    # USB stick (blackbox, installer slot, way D notes)
    'usbcore': 'USB', 'xhci-hcd': 'USB_XHCI_HCD', 'xhci-plat-hcd': 'USB_XHCI_PLATFORM',
    'dwc3': 'USB_DWC3', 'phy-ls1024a-usb3': None, 'usb-storage': 'USB_STORAGE',
    'sd_mod': 'BLK_DEV_SD',
    # FAT stick
    'fat': 'FAT_FS', 'vfat': 'VFAT_FS',
    # SATA disks
    'phy-ls1024a-serdes': None, 'libahci': 'SATA_AHCI', 'libahci_platform': 'SATA_AHCI_PLATFORM',
    'ahci_platform': 'SATA_AHCI_PLATFORM',
    # stock arrays and LVM (zt-blk uses the kernel md/dm ioctls)
    'md-mod': 'BLK_DEV_MD', 'linear': 'MD_LINEAR', 'raid1': 'MD_RAID1',
    'raid456': 'MD_RAID456', 'dm-mod': 'BLK_DEV_DM',
    # watchdog, I2C (fan MCU), LEDs
    'watchdog': 'WATCHDOG_CORE', 'ls1024a_wdt': None, 'i2c-ls1024a': None,
    # bays 2 and 4: PCIe -> ASM1061 -> generic PCI AHCI
    'pcie-ls1024a': None, 'ahci': 'SATA_AHCI',
}
BUILTIN = ['SERIAL_8250', 'SERIAL_8250_CONSOLE', 'SERIAL_8250_DW', 'BLK_DEV_INITRD',
           'KEXEC', 'DEVMEM', 'EXT4_FS', 'MTD_NAND_COMCERTO']
FILES = ['init', 'etc/rc.ssh', 'bin/busybox', 'bin/zt-loader', 'bin/zt-mount', 'bin/zt-blk',
         'bin/zt-kexec', 'bin/zt-sig', 'bin/zt-blackbox', 'bin/zt-fan', 'sbin/zt-poweroff']
APPLETS = ['sh', 'insmod', 'devmem', 'sha256sum', 'sed', 'grep', 'dd', 'cut', 'sort', 'wc',
           'tr', 'cat', 'ls', 'mkdir', 'sleep', 'dmesg', 'watchdog', 'sync', 'cp', 'rm']
# VFS flags: mount(8) turns them into MS_* flags, mount(2) data must not carry
# them (vfat: 'Unrecognized mount option "rw"')
VFS_FLAGS = {'rw', 'defaults', 'noatime', 'nodiratime', 'relatime', 'strictatime', 'sync',
             'async', 'exec', 'noexec', 'suid', 'nosuid', 'dev', 'nodev', 'remount', 'bind',
             'auto', 'noauto', 'user', 'nouser'}


# ------------------------------------------------------------------ helpers
def uimage(path):
    b = open(path, 'rb').read()
    magic, hcrc, _t, size, load, ep, dcrc, _os, arch, typ, comp = struct.unpack('>7I4B', b[:32])
    name = b[32:64].split(b'\0')[0].decode(errors='replace')
    h = bytearray(b[:64]); h[4:8] = b'\0\0\0\0'
    payload = b[64:64 + size]
    r = dict(magic=magic, hcrc_ok=zlib.crc32(h) == hcrc, size=size, load=load, ep=ep,
             dcrc_ok=zlib.crc32(payload) == dcrc and len(payload) == size, arch=arch,
             typ=typ, comp=comp, name=name, payload=payload, total=len(b), raw=b)
    return r

def gunzip_at(b, i):
    return zlib.decompressobj(16 + 15).decompress(b[i:])

def kernel_image(zimage):
    i = zimage.find(b'\x1f\x8b\x08')
    if i < 0: return None
    return gunzip_at(zimage, i)

def find_initramfs(vmlinux):
    best = None
    for m in re.finditer(b'\x1f\x8b\x08\x00', vmlinux):
        try: c = gunzip_at(vmlinux, m.start())
        except Exception: continue
        if c[:6] == b'070701' and (best is None or len(c) > len(best)): best = c
    return best

def cpio(b):
    o, out = 0, {}
    while o + 110 <= len(b):
        h = b[o:o + 110]
        if h[:6] != b'070701': break
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        mode, fsz, nsz = f[1], f[6], f[11]
        name = b[o + 110:o + 110 + nsz - 1].decode(errors='replace')
        d0 = (o + 110 + nsz + 3) & ~3
        data = b[d0:d0 + fsz]
        o = (d0 + fsz + 3) & ~3
        if name == 'TRAILER!!!': break
        out[name.lstrip('./') or '.'] = dict(mode=mode, data=data, rdev=(f[9], f[10]))
    return out

def elf_section(b, want):
    if b[:4] != b'\x7fELF' or b[4] != 1: return None
    shoff, = struct.unpack_from('<I', b, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x2e)
    secs = [struct.unpack_from('<10I', b, shoff + i * shentsize) for i in range(shnum)]
    stro = secs[shstrndx][4]
    for s in secs:
        n = b[stro + s[0]:b.index(b'\0', stro + s[0])].decode()
        if n == want: return b[s[4]:s[4] + s[5]]
    return None

def modinfo(b):
    sec = elf_section(b, '.modinfo') or b''
    d = {}
    for kv in sec.split(b'\0'):
        if b'=' in kv:
            k, v = kv.split(b'=', 1); d.setdefault(k.decode(), v.decode(errors='replace'))
    return d

def kconfig(build):
    cfg = {}
    for l in open(os.path.join(build, '.config')):
        m = re.match(r'CONFIG_(\w+)=(.*)', l)
        if m: cfg[m.group(1)] = m.group(2).strip('"')
    return cfg


# -------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('loader'); ap.add_argument('--build'); ap.add_argument('--ref')
    ap.add_argument('--repo', default=os.path.normpath(os.path.join(os.path.dirname(__file__), '../../..')))
    a = ap.parse_args()

    u = uimage(a.loader)
    print(f'== {a.loader}\n   name "{u["name"]}", {u["total"]} bytes')
    if u['magic'] != 0x27051956: fail('no uImage magic'); return
    (ok if u['hcrc_ok'] and u['dcrc_ok'] else fail)('uImage header/data CRC')
    (ok if u['load'] == LOAD and u['ep'] == LOAD else fail)(f'load/entry {u["load"]:#x}/{u["ep"]:#x} (want {LOAD:#x})')
    (ok if u['arch'] == 2 and u['typ'] == 2 and u['comp'] == 0 else fail)('ARM kernel, uncompressed uImage')
    (ok if u['name'].startswith('ZT ') else fail)('image name starts with "ZT " (PartnerKey update check)')
    padded = u['raw'][64 + u['size']:]
    if u['total'] > SLOT_BYTES: fail(f'larger than the 10 MiB kernel slot')
    elif padded and padded.strip(b'\xff'): fail('trailing bytes after the image are not 0xff padding')
    else: ok(f'fits the 10 MiB NAND slot ({u["total"] - len(padded)} bytes used)')

    vm = kernel_image(u['payload'])
    if vm is None: fail('no gzip kernel inside the zImage'); return
    ver = re.search(rb'Linux version (\S+)', vm)
    kver = ver.group(1).decode() if ver else '?'
    ok(f'kernel {kver}')
    # appended DTB: the FDT must end exactly at the end of the payload
    pl = u['payload']; i = pl.rfind(b'\xd0\x0d\xfe\xed')
    tot = struct.unpack_from('>I', pl, i + 4)[0] if i >= 0 else 0
    if i < 0 or i + tot != len(pl):
        fail('no device tree appended to the zImage (payload must end with the NAS542 DTB)')
    elif b'zyxel,nas542' not in pl[i:]:
        fail('appended device tree is not the zyxel,nas542 one')
    else:
        ok(f'appended zyxel,nas542 device tree ({tot} bytes)')
    ird = find_initramfs(vm)
    if not ird: fail('no embedded initramfs found'); return
    fs = cpio(ird)
    mods = {os.path.basename(n)[:-3]: e for n, e in fs.items() if n.endswith('.ko')}
    print(f'   initramfs {len(ird)} bytes, {len(fs)} entries, {len(mods)} modules')

    # files, device nodes, binaries
    for f in FILES:
        if f not in fs: fail(f'initramfs lacks {f}')
    con = fs.get('dev/console')
    (ok if con and (con['mode'] & 0o170000) == 0o020000 and con['rdev'] == (5, 1) else fail)('dev/console char 5:1 (rc.ssh exec >/dev/console)')
    bad = [n for n, e in fs.items() if (e['mode'] & 0o170000) == 0o100000 and e['data'][:4] == b'\x7fELF'
           and not n.startswith('lib/firmware/')
           and (e['data'][4] != 1 or struct.unpack_from('<H', e['data'], 18)[0] != 40)]
    (fail if bad else ok)(f'all ELF files are 32-bit ARM{": " + ", ".join(bad) if bad else ""}')
    links = {n: e['data'].decode(errors='replace') for n, e in fs.items() if (e['mode'] & 0o170000) == 0o120000}
    missing = [x for x in APPLETS if f'bin/{x}' not in fs and f'sbin/{x}' not in fs and f'usr/bin/{x}' not in fs]
    (fail if missing else ok)(f'busybox applets for rc.ssh/zt-loader{": missing " + " ".join(missing) if missing else ""}')

    # modules: vermagic, dependencies, needed set
    cfg = kconfig(a.build) if a.build else None
    builtin = set()
    if a.build and os.path.exists(os.path.join(a.build, 'modules.builtin')):
        builtin = {os.path.basename(l.strip())[:-3] for l in open(os.path.join(a.build, 'modules.builtin'))}
        builtin |= {m.replace('_', '-') for m in builtin} | {m.replace('-', '_') for m in builtin}
    if a.build:
        for c in BUILTIN:
            (ok if cfg.get(c) == 'y' else fail)(f'CONFIG_{c}=y (have {cfg.get(c, "unset")})')
        if cfg.get('AUTO_ZRELADDR') == 'y': fail('CONFIG_AUTO_ZRELADDR=y')
        cmd = os.path.join(a.build, 'arch/arm/boot/compressed/.vmlinux.cmd')
        (ok if os.path.exists(cmd) and '--defsym zreladdr=0x04008000' in open(cmd).read() else fail)('zreladdr=0x04008000 in .vmlinux.cmd')
        src = cfg.get('INITRAMFS_SOURCE', '')
        if src and os.path.exists(src):
            (ok if open(src, 'rb').read().rstrip(b'\0') == ird.rstrip(b'\0') else warn)(f'INITRAMFS_SOURCE {os.path.basename(src)} equals the embedded initramfs')
    vm_magic = None
    infos = {}
    for n, e in mods.items():
        mi = modinfo(e['data']); infos[n] = mi
        vm_magic = vm_magic or mi.get('vermagic')
    if mods:
        wrong = [n for n, mi in infos.items() if not mi.get('vermagic', '').startswith(kver + ' ')]
        (fail if wrong else ok)(f'vermagic of all modules starts with "{kver} "{": " + " ".join(sorted(wrong)) if wrong else ""}')
        have = set(mods) | {n.replace('-', '_') for n in mods} | builtin
        unmet = sorted({f'{n}->{d}' for n, mi in infos.items() for d in filter(None, mi.get('depends', '').split(','))
                        if d not in have and d.replace('_', '-') not in have})
        (fail if unmet else ok)(f'module dependencies inside the initramfs{": " + " ".join(unmet) if unmet else ""}')
    for m, c in NEEDED.items():
        if m in mods or m in builtin: continue
        if cfg and c and cfg.get(c) == 'y': continue
        fail(f'needed module {m}.ko missing' + (f' and CONFIG_{c} is not =y' if cfg and c else ''))
    # FAT defaults: codepage and iocharset must be loadable
    if cfg and cfg.get('FAT_FS') in ('y', 'm'):
        for nls in (f'nls_cp{cfg.get("FAT_DEFAULT_CODEPAGE", "437")}', 'nls_' + cfg.get('FAT_DEFAULT_IOCHARSET', 'iso8859-1')):
            sym = 'NLS_' + nls[4:].upper().replace('-', '_').replace('CP', 'CODEPAGE_')
            (ok if nls in mods or cfg.get(sym) == 'y' else fail)(f'FAT default charset {nls} available (CONFIG_{sym}={cfg.get(sym, "unset")})')

    # rc.ssh loads modules with "[ -f ] || continue": every listed module must exist
    rc = fs.get('etc/rc.ssh', {}).get('data', b'').decode(errors='replace')
    listed = set()
    for body in re.findall(r'for m in (.*?); do', rc, re.S):
        listed |= set(body.replace('\\\n', ' ').split())
    listed |= set(re.findall(r'\$M/([\w-]+)\.ko', rc))
    listed.discard('$m')
    dev_only = {'pfe'}	# loaded only with an operator key ($DEV = 1)
    skipped = sorted(m for m in listed if m not in mods and m not in dev_only and m not in builtin)
    # without --build a missing name may be built in (modules.builtin is not in
    # the image); the NEEDED set above stays a hard check either way
    hard = [m for m in skipped if a.build or m in NEEDED]
    msg = f'every module rc.ssh loads is present ({len(listed)} named){": missing " + " ".join(skipped) if skipped else ""}'
    (fail if hard else warn if skipped else ok)(msg + ('' if hard or not skipped else ' (built in? pass --build)'))

    # disk drivers must not sit inside an operator-key-only block
    rl = rc.splitlines()
    for i, line in enumerate(rl):
        m = re.search(r'\$M/(pcie-ls1024a|ahci|ahci_platform|libahci)\.ko', line)
        if not m or line.lstrip().startswith('#'): continue
        depth, gate = 0, None
        for j in range(i - 1, -1, -1):
            t = rl[j].split('#')[0].strip()
            closes = bool(re.search(r'(^|;|\s)fi\s*$', t))	# "fi", "...; fi", "else ...; fi"
            opens = bool(re.match(r'if\b', t))
            if opens and closes: continue			# one-line if
            if closes: depth += 1
            elif opens:
                if depth == 0:		# an enclosing block: check it, keep going out
                    if '$DEV = 1' in t: gate = j + 1; break
                else: depth -= 1
        if gate: fail(f'etc/rc.ssh:{i + 1}: {m.group(1)}.ko only loaded with an operator key (if at line {gate}): release loader misses disks')
    # zt-mount option lint in every shell script of the initramfs
    for n, e in sorted(fs.items()):
        d = e['data']
        if (e['mode'] & 0o170000) != 0o100000 or not d.startswith(b'#!'): continue
        for ln, line in enumerate(d.decode(errors='replace').splitlines(), 1):
            m = re.search(r'\bzt-mount\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+([^\s;|&<>]+))?', line)
            if not m or line.lstrip().startswith('#') or m.group(1) == '-u': continue
            opt = m.group(4)
            if not opt or opt.startswith('2>'): continue
            parts = opt.split(',')
            if parts[0] == 'ro': parts = parts[1:]
            flags = [p for p in parts if p in VFS_FLAGS]
            if flags: fail(f'{n}:{ln}: zt-mount {m.group(1)} passes VFS flag(s) {",".join(flags)} as fs data: {line.strip()}')
    ok('zt-mount option lint done')

    # release hygiene: no operator key, host key or device MACs
    for n in ('root/.ssh/authorized_keys', 'etc/zt-mac.env', 'etc/dropbear/dropbear_ed25519_host_key'):
        if n in fs and fs[n]['data'].strip(): fail(f'release loader carries {n}')
    # the loader script is the repository's
    repo_ldr = os.path.join(a.repo, 'loader/slot/zt-loader')
    if os.path.exists(repo_ldr) and 'bin/zt-loader' in fs:
        (ok if fs['bin/zt-loader']['data'] == open(repo_ldr, 'rb').read() else warn)('bin/zt-loader equals loader/slot/zt-loader')

    # regression against a known-good loader
    if a.ref:
        r = uimage(a.ref); rv = kernel_image(r['payload']); rf = cpio(find_initramfs(rv) or b'')
        rmods = {os.path.basename(n)[:-3] for n in rf if n.endswith('.ko')}
        lost = sorted(rmods - set(mods))
        (fail if lost else ok)(f'module set vs {os.path.basename(a.ref)} ({len(rmods)} -> {len(mods)}){": lost " + " ".join(lost) if lost else ""}')
        gone = sorted(n for n in rf if n not in fs and not n.endswith('.ko'))
        (fail if gone else ok)(f'no file of the reference initramfs lost{": " + " ".join(gone[:10]) if gone else ""}')
        changed = sorted(n for n in rf if n in fs and rf[n]['data'] != fs[n]['data'])
        print(f'   changed vs reference: {", ".join(changed) or "nothing"}')

    print(f'== {"PASS" if not FAIL else "FAIL (%d)" % len(FAIL)}')
    return 1 if FAIL else 0

if __name__ == '__main__':
    sys.exit(main() or (1 if FAIL else 0))
