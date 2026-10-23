#!/usr/bin/env python3
"""Barebox envfs (as used by the NAS542 Barebox-C2K) - list, extract, pack.

Layout (verified against a stock env dump): 28-byte superblock
  magic 0x798fba79, priority, crc (crc32 of data), size (data bytes),
  flags, reserved, sb_crc (crc32 of the first 24 bytes);
then inodes: magic 0x67a8c78d, size, headerlen, name (NUL, padded to 4),
data (padded to 4).  The partition is padded with 0xff.

  envfs.py list ENV.bin
  envfs.py extract ENV.bin DIR
  envfs.py pack DIR OUT.bin [PART_SIZE]   (files sorted like the original)
  envfs.py check ENV.bin                  (CRCs)
  envfs.py untrash ENV.bin OUT.bin        (UntrashOS env, see untrash())
  envfs.py stock ENV.bin OUT.bin          (project hooks removed, see stock())

The PartnerKey does the same on the NAS with install/ztpk.c (stock
BusyBox, no Python); install/test-ztpk.sh checks both give identical bytes.
"""
import os, struct, sys, zlib

MAGIC, INODE = 0x798fba79, 0x67a8c78d

def pad4(n): return (n + 3) & ~3

def parse(blob):
    magic, prio, crc, size, flags, res, sbcrc = struct.unpack_from('<7I', blob, 0)
    assert magic == MAGIC, 'no envfs superblock'
    assert zlib.crc32(blob[:24]) == sbcrc, 'superblock crc mismatch'
    data = blob[28:28 + size]
    assert zlib.crc32(data) == crc, 'data crc mismatch'
    files, off = [], 0
    while off < len(data):
        m, fsize, hlen = struct.unpack_from('<3I', data, off)
        assert m == INODE, 'bad inode magic at %#x' % off
        name = data[off + 12:off + 12 + hlen].split(b'\0')[0].decode()
        doff = off + 12 + pad4(hlen)
        files.append((name, data[doff:doff + fsize]))
        off = doff + pad4(fsize)
    return prio, flags, files

def pack(files, part_size, prio=0, flags=0):
    data = b''
    for name, content in files:
        n = name.encode() + b'\0'
        data += struct.pack('<3I', INODE, len(content), len(n))
        data += n.ljust(pad4(len(n)), b'\0') + content.ljust(pad4(len(content)), b'\0')
    sb = struct.pack('<6I', MAGIC, prio, zlib.crc32(data), len(data), flags, 0)
    blob = sb + struct.pack('<I', zlib.crc32(sb)) + data
    assert len(blob) <= part_size
    return blob + b'\xff' * (part_size - len(blob))

LOADER = """#!/bin/sh
# UntrashOS: start the loader in NAND kernel%(x)s.  The stock boot follows
# when this returns: after the loader asked for the way back to stock (16-byte
# mark in RAM at 0x2e000000, os/loader/zt-loader) or when bootm fails.
echo
mw 0x2e000010 0x5a54726f
mw 0x2e000014 0x6c6c6261
mw 0x2e000018 0x636b2d31
mw 0x2e00001c 0x8f1e2d3c
if memcmp 0x2e000000 0x2e000010 16; then
	echo "UntrashOS: way back to stock requested, stock boot"
else
	echo "UntrashOS: loader from NAND kernel%(x)s"
	mw 0x904700D0 0x010000A0
	mw 0x90470058 0x05000000
	mw 0x90458000 0x80000001
	mw 0x90458028 0x80001388
	mw 0x9045802C 0x00000fa0
	# the loader kernel uses its built-in command line (CMDLINE_FORCE)
	bootargs="console=ttyS0,115200n8"
	bootm /dev/nand0.kernel%(x)s.bb
	echo "UntrashOS: loader bootm returned, stock boot"
fi
"""

def config_var(cfg, name):
    """Last plain assignment NAME=VALUE / NAME="VALUE" in the env config."""
    val = None
    for line in cfg.split('\n'):
        if line.startswith(name + '='):
            v = line[len(name) + 1:].strip()
            if len(v) >= 2 and v[0] == v[-1] == '"':
                v = v[1:-1]
            val = v
    return val

def untrash(files):
    """Stock (or project dev V6) env -> UntrashOS env.  Returns (files, slot).

    The loader goes into the INACTIVE stock kernel slot X: the active one is
    curr_bootfrom (= next_bootfrom; Barebox boots kernel<curr>, stock rcS
    mounts rootfs<curr>).  New file /bin/untrash_loader boots kernelX; it is
    called before the stock dispatch, so a failed bootm continues with the
    untouched stock boot (kernel<curr> + rootfs<curr>).
      pristine stock: last non-empty line of /bin/init is "boot"
                      -> "/env/bin/untrash_loader" + "boot"
      dev V6 (TFTP):  in /bin/boot_zyxeluntrash the two lines
                      "    /env/bin/boot_zyxeluntrash_recovery" right after an
                      echo line naming TFTP (server unreachable / download
                      failed) -> untrash_loader (as env V7 did)
    Everything else is refused (ValueError)."""
    d = dict(files)
    for need in ('/config', '/bin/init', '/bin/boot'):
        if need not in d:
            raise ValueError('not a NAS542 stock env: %s missing' % need)
    if '/bin/untrash_loader' in d or '/bin/boot_zyxeluntrash_loader' in d:
        raise ValueError('env already starts an UntrashOS loader')
    cfg = d['/config'].decode('latin-1')
    cur, nxt = config_var(cfg, 'curr_bootfrom'), config_var(cfg, 'next_bootfrom')
    if cur not in ('1', '2') or nxt != cur:
        raise ValueError('curr_bootfrom=%s next_bootfrom=%s: no settled stock slot' % (cur, nxt))
    x = '2' if cur == '1' else '1'
    out = []
    init = d['/bin/init'].decode('latin-1')
    lines = init.split('\n')
    last = max((i for i, l in enumerate(lines) if l.strip()), default=-1)
    if last >= 0 and lines[last] == 'boot':
        lines[last:last + 1] = ['/env/bin/untrash_loader', 'boot']
        new = {'/bin/init': '\n'.join(lines).encode('latin-1')}
    elif '/bin/boot_zyxeluntrash' in d and '\t/env/bin/boot_zyxeluntrash\n' in init:
        bz = d['/bin/boot_zyxeluntrash'].decode('latin-1').split('\n')
        hits = [i for i, l in enumerate(bz) if l == '    /env/bin/boot_zyxeluntrash_recovery'
                and i > 0 and 'echo' in bz[i - 1] and 'TFTP' in bz[i - 1]]
        if len(hits) != 2:
            raise ValueError('dev env: %d TFTP fallbacks in boot_zyxeluntrash, expected 2' % len(hits))
        for i in hits:
            bz[i] = '    /env/bin/untrash_loader'
        new = {'/bin/boot_zyxeluntrash': '\n'.join(bz).encode('latin-1')}
    else:
        raise ValueError('unknown env: /bin/init does not end with the stock "boot"')
    for name, content in files:
        out.append((name, new.get(name, content)))
    out.append(('/bin/untrash_loader', (LOADER % {'x': x}).encode()))
    return out, x

# (the en dash is UTF-8 in the env; files are handled as latin-1 here)
HOOK_V4 = """# ZyxelUntrash \xe2\x80\x93 deaktivierte Basisinstallation V4
if [ x$zyxeluntrash_enabled = x1 ]; then
	/env/bin/boot_zyxeluntrash
else
	boot
fi"""
PROJECT_FILES = ('/bin/boot_zyxeluntrash', '/bin/boot_zyxeluntrash_recovery',
                 '/bin/boot_zyxeluntrash_loader', '/bin/untrash_loader')

def stock(files):
    """Dev env (V4-V7) or UntrashOS env -> stock env.  Returns files.

    Removes exactly what this project added since July 2026: the scripts in
    PROJECT_FILES, the V4 dispatch in /bin/init (back to the stock "boot"),
    an /env/bin/untrash_loader line, and the block of zyxeluntrash_* settings
    appended to /config (from its first "ZyxelUntrash" banner to the end).
    Everything Zyxel wrote (fwversion_*, MACs, serial, boot slot) stays.
    Anything else that looks like the project is refused (ValueError)."""
    d = dict(files)
    init = d['/bin/init'].decode('latin-1')
    if HOOK_V4 in init:
        init = init.replace(HOOK_V4, 'boot')
    init = '\n'.join(l for l in init.split('\n') if l != '/env/bin/untrash_loader')
    lines = init.split('\n')
    last = max((i for i, l in enumerate(lines) if l.strip()), default=-1)
    if last < 0 or lines[last] != 'boot':
        raise ValueError('/bin/init does not end with the stock "boot" after removing the hooks')
    cfg = d['/config'].decode('latin-1').split('\n')
    hit = [i for i, l in enumerate(cfg) if 'ZyxelUntrash' in l]
    if hit:
        cut = hit[0]
        while cut > 0 and (cfg[cut - 1].startswith('#') or not cfg[cut - 1].strip()):
            cut -= 1
        for l in cfg[cut:]:
            t = l.strip()
            if t and not t.startswith('#') and not t.startswith('zyxeluntrash_'):
                raise ValueError('config block after the ZyxelUntrash banner holds %r' % l)
        cfg = cfg[:cut]
    while cfg and not cfg[-1].strip():
        cfg.pop()
    new = {'/bin/init': init.encode('latin-1'), '/config': ('\n'.join(cfg) + '\n').encode('latin-1')}
    out = [(n, new.get(n, c)) for n, c in files if n not in PROJECT_FILES]
    for n, c in out:
        if b'untrash' in c.lower():
            raise ValueError('%s still mentions the project' % n)
    return out

def main(a):
    if a[0] in ('list', 'check'):
        prio, flags, files = parse(open(a[1], 'rb').read())
        if a[0] == 'check':
            print('OK files=%d' % len(files)); return
        for n, c in files: print('%6d %s' % (len(c), n))
    elif a[0] == 'extract':
        _, _, files = parse(open(a[1], 'rb').read())
        order = []
        for n, c in files:
            p = os.path.join(a[2], n.lstrip('/'))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, 'wb').write(c); order.append(n)
        open(os.path.join(a[2], '.envfs-order'), 'w').write('\n'.join(order) + '\n')
    elif a[0] == 'pack':
        d = a[1]; size = int(a[3], 0) if len(a) > 3 else 0x40000
        order = open(os.path.join(d, '.envfs-order')).read().split()
        extra = sorted('/' + os.path.relpath(os.path.join(r, f), d)
                       for r, _, fs in os.walk(d) for f in fs if f != '.envfs-order')
        names = [n for n in order if n in extra] + [n for n in extra if n not in order]
        files = [(n, open(os.path.join(d, n.lstrip('/')), 'rb').read()) for n in names]
        open(a[2], 'wb').write(pack(files, size))
    elif a[0] == 'untrash':
        blob = open(a[1], 'rb').read()
        prio, flags, files = parse(blob)
        try:
            files, x = untrash(files)
        except ValueError as e:
            sys.exit('REFUSED %s' % e)
        open(a[2], 'wb').write(pack(files, len(blob), prio, flags))
        print('OK slot=%s' % x)
    elif a[0] == 'stock':
        blob = open(a[1], 'rb').read()
        prio, flags, files = parse(blob)
        try:
            files = stock(files)
        except ValueError as e:
            sys.exit('REFUSED %s' % e)
        open(a[2], 'wb').write(pack(files, len(blob), prio, flags))
        print('OK files=%d' % len(files))
    else:
        sys.exit(__doc__)

if __name__ == '__main__':
    main(sys.argv[1:] or ['help'])
