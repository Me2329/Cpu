#!/usr/bin/env python3
"""mkwad.py - builds MAZE.WAD, the data file of the RAYCAST.PEX demo.

The container is the genuine id Software WAD layout used by DOOM:

    header   "PWAD", int32 numlumps, int32 infotableofs
    lumps    raw data
    dir      numlumps x { int32 filepos, int32 size, char name[8] }

Lumps:
    PLAYPAL  256 x RGB (8 bit) palette, programmed into the VGA DAC
    MAP01    16 x 16 bytes, 0 = empty, 1..4 = wall texture/colour family
    THINGS   player start: int16 x, int16 y (8.8 fixed, cells), int16 angle (0-255)
    MUSIC    AdLib score: {u8 fnum_lo, u8 block<<2 | fnum_hi, u8 ticks, u8 0} ...,
             terminated by ticks = 0. fnum_lo = fnum_hi = 0 is a rest.
    TITLE    ASCIIZ level name for the HUD
"""
import struct
import sys

MAP = [
    "1111111111111111",
    "1..............1",
    "1..2222....3...1",
    "1..2..2....3...1",
    "1..2..2....333.1",
    "1..............1",
    "1....4444......1",
    "1....4..4..2...1",
    "1.......4..2...1",
    "1..33...4..2...1",
    "1..3...........1",
    "1..3....11111..1",
    "1.......1...1..1",
    "1...........1..1",
    "1..............1",
    "1111111111111111",
]

# wall families: base RGB, 16 shades from near (bright) to far (dark)
FAMILIES = {1: (200, 60, 50), 2: (70, 110, 210), 3: (60, 170, 80), 4: (190, 140, 70)}


def palette():
    pal = [(0, 0, 0)] * 256
    for i in range(16):                                   # 0-15: grey ramp
        g = i * 17
        pal[i] = (g, g, g)
    for fam, (r, g, b) in FAMILIES.items():               # 16*fam + shade
        for s in range(16):
            k = 1.0 - s / 18.0
            pal[16 * fam + s] = (int(r * k), int(g * k), int(b * k))
    for s in range(16):                                   # 80-95 ceiling, 96-111 floor
        k = 1.0 - s / 20.0
        pal[80 + s] = (int(60 * k), int(70 * k), int(95 * k))
        pal[96 + s] = (int(95 * k), int(80 * k), int(60 * k))
    pal[252] = (20, 20, 30)          # HUD dark
    pal[253] = (255, 60, 40)         # HUD red (player)
    pal[254] = (255, 220, 60)        # HUD yellow
    pal[255] = (255, 255, 255)       # HUD white
    return b''.join(bytes(c) for c in pal)


def music():
    # an original little tune in A minor; (note, ticks at 70 Hz)
    names = {'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6,
             'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11}
    score = ("A3 14 C4 14 E4 14 A4 28 G4 14 E4 14 C4 14 D4 28 - 14 "
             "F3 14 A3 14 C4 14 F4 28 E4 14 C4 14 A3 14 B3 28 - 14 "
             "E4 14 G#4 14 B4 14 E5 28 D5 14 B4 14 G#4 14 A4 42 - 28").split()
    out = b''
    for i in range(0, len(score), 2):
        note, ticks = score[i], int(score[i + 1])
        if note == '-':
            out += bytes([0, 0, ticks, 0])
            continue
        name, octave = note[:-1], int(note[-1])
        midi = 12 * (octave + 1) + names[name]
        freq = 440.0 * 2 ** ((midi - 69) / 12)
        block = 4
        fnum = round(freq * (1 << (20 - block)) / 49716)
        while fnum > 1023:
            block += 1
            fnum = round(freq * (1 << (20 - block)) / 49716)
        out += bytes([fnum & 0xFF, (block << 2) | (fnum >> 8), ticks, 0])
    return out + bytes([0, 0, 0, 0])


def build(path):
    grid = bytes(0 if ch == '.' else int(ch) for row in MAP for ch in row)
    assert len(grid) == 256
    things = struct.pack('<hhh', int(1.5 * 256), int(1.5 * 256), 16)   # facing south-east
    lumps = [('PLAYPAL', palette()), ('MAP01', grid), ('THINGS', things),
             ('MUSIC', music()), ('TITLE', b'MAZE.WAD - E1M1: PERRY BASE\0')]
    data = b''
    entries = []
    pos = 12
    for name, blob in lumps:
        entries.append((pos, len(blob), name))
        data += blob
        pos += len(blob)
    directory = b''.join(struct.pack('<ii8s', p, n, name.encode()) for p, n, name in entries)
    with open(path, 'wb') as f:
        f.write(b'PWAD' + struct.pack('<ii', len(lumps), 12 + len(data)) + data + directory)
    print('mkwad: %s (%d lumps, %d bytes)' % (path, len(lumps), 12 + len(data) + len(directory)))


if __name__ == '__main__':
    build(sys.argv[1] if len(sys.argv) > 1 else 'MAZE.WAD')
