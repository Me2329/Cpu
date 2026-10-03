#!/usr/bin/env python3
"""pngopt.py - recompress the emulator's uncompressed PNG screenshots with
zlib level 9 (standard library only).   python3 tools/pngopt.py *.png"""
import struct
import sys
import zlib


def optimize(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, chunks, idat = 8, [], b''
    while pos < len(data):
        n, = struct.unpack('>I', data[pos:pos + 4])
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b'IDAT':
            idat += body
        else:
            chunks.append((kind, body))
    raw = zlib.decompress(idat)
    out = data[:8]
    for kind, body in chunks:
        if kind == b'IEND':
            z = zlib.compress(raw, 9)
            out += struct.pack('>I', len(z)) + b'IDAT' + z + struct.pack('>I', zlib.crc32(b'IDAT' + z))
        out += struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    open(path, 'wb').write(out)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        optimize(p)
