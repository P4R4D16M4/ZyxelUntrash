#!/usr/bin/env python3
"""Extract the stock uImage from a NAND kernel partition dump (rollback stage 1:
served by TFTP as uImage-zyxeluntrash, env V7 boots it with stock rootfs1).
  extract-stock-kernel.py DUMP OUT   (DUMP: *.nand-oob.bin with 2048+64 pages,
                                      or a data-only dump)"""
import struct, sys, zlib
raw = open(sys.argv[1], 'rb').read()
data = b''.join(raw[i:i + 2048] for i in range(0, len(raw), 2112)) if sys.argv[1].endswith('.nand-oob.bin') else raw
magic, hcrc, _, size = struct.unpack_from('>IIII', data, 0)
assert magic == 0x27051956, 'no uImage header'
hdr = bytearray(data[:64]); hdr[4:8] = b'\0' * 4
assert zlib.crc32(bytes(hdr)) == hcrc, 'header crc'
dcrc = struct.unpack_from('>I', data, 24)[0]
assert zlib.crc32(data[64:64 + size]) == dcrc, 'data crc'
open(sys.argv[2], 'wb').write(data[:64 + size])
print('uImage %s: %d bytes, name %s' % (sys.argv[2], 64 + size, data[32:64].split(b'\0')[0].decode()))
