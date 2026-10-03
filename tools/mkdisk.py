#!/usr/bin/env python3
"""mkdisk.py - build a PERRY File System (PFS) disk image.

    python3 tools/mkdisk.py build/disk.img build/*.PEX disk/*  [--size 4M]

Layout (see emu/pfs.h): sector 0 superblock, sectors 1-4 directory
(64 x 32-byte entries), data from sector 5, files stored contiguously.
Also supports listing / extracting an existing image:

    python3 tools/mkdisk.py --list build/disk.img
    python3 tools/mkdisk.py build/disk.img --extract README.TXT
"""
import argparse
import os
import struct
import sys
import time

SECTOR = 512
DIR_START, DIR_SECTORS, MAX_ENTRIES = 1, 4, 64
DATA_START = DIR_START + DIR_SECTORS
ATTR_USED, ATTR_RO, ATTR_SYS = 1, 2, 4
SYSTEM_FILES = {'COMMAND.PEX'}


def dos_name(path):
    name = os.path.basename(path).upper()
    base, _, ext = name.partition('.')
    if not base or len(base) > 8 or len(ext) > 3 or '.' in ext:
        raise SystemExit('mkdisk: %s is not a valid 8.3 file name' % name)
    return name


def parse_size(text):
    text = text.upper()
    mult = 1
    if text.endswith('K'):
        mult, text = 1024, text[:-1]
    elif text.endswith('M'):
        mult, text = 1024 * 1024, text[:-1]
    return int(text) * mult


def build(out, files, size, label):
    total = size // SECTOR
    img = bytearray(total * SECTOR)
    img[0:4] = b'PFS1'
    struct.pack_into('<IIII', img, 4, total, DIR_START, DIR_SECTORS, DATA_START)
    img[20:36] = label.encode()[:16].ljust(16, b'\0')
    # system files first, then alphabetical
    named = {}
    for f in files:
        named[dos_name(f)] = f
    order = sorted(named, key=lambda n: (n not in SYSTEM_FILES, n))
    if len(order) > MAX_ENTRIES:
        raise SystemExit('mkdisk: too many files (max %d)' % MAX_ENTRIES)
    sector = DATA_START
    now = int(time.time())
    for i, name in enumerate(order):
        with open(named[name], 'rb') as fh:
            data = fh.read()
        alloc = max(1, (len(data) + SECTOR - 1) // SECTOR)
        if sector + alloc > total:
            raise SystemExit('mkdisk: disk full while adding %s' % name)
        img[sector * SECTOR:sector * SECTOR + len(data)] = data
        attr = ATTR_USED | (ATTR_SYS if name in SYSTEM_FILES else 0)
        ent = struct.pack('<13sBHIIII', name.encode(), attr, 0, sector, len(data), alloc, now)
        off = DIR_START * SECTOR + i * 32
        img[off:off + 32] = ent
        sector += alloc
    with open(out, 'wb') as fh:
        fh.write(img)
    print('mkdisk: %s  %d files, %d KB used of %d KB' % (
        out, len(order), sector * SECTOR // 1024, size // 1024))


def entries(img):
    for i in range(MAX_ENTRIES):
        off = DIR_START * SECTOR + i * 32
        name, attr, _, start, size, alloc, mtime = struct.unpack_from('<13sBHIIII', img, off)
        if attr & ATTR_USED:
            yield name.split(b'\0')[0].decode(), attr, start, size, alloc


def main():
    ap = argparse.ArgumentParser(description='build a PFS disk image')
    ap.add_argument('image')
    ap.add_argument('files', nargs='*')
    ap.add_argument('--size', default='4M')
    ap.add_argument('--label', default='PERRY-DOS')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--extract', metavar='NAME')
    args = ap.parse_args()
    if args.list or args.extract:
        with open(args.image, 'rb') as fh:
            img = fh.read()
        if img[:4] != b'PFS1':
            raise SystemExit('mkdisk: not a PFS image')
        for name, attr, start, size, alloc in entries(img):
            if args.extract and name == args.extract.upper():
                sys.stdout.buffer.write(img[start * SECTOR:start * SECTOR + size])
                return
            if args.list:
                print('%-12s %8d bytes  sector %5d  attr %d' % (name, size, start, attr))
        if args.extract:
            raise SystemExit('mkdisk: %s not found' % args.extract)
        return
    build(args.image, args.files, parse_size(args.size), args.label)


if __name__ == '__main__':
    main()
