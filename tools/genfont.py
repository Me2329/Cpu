#!/usr/bin/env python3
"""genfont.py - generates the PERRY-16 8x8 system font (emu/font8x8.h).

The font is an original 5x7 design (drawn below as ASCII art) plus
procedurally generated CP437 box-drawing / shade glyphs used by the
text-mode UI.  Bit 7 of each row byte is the leftmost pixel (VGA order).
The emulator copies this table into ROM at 0xF800 so guest programs can
draw text in graphics mode themselves.
"""
import os
import sys

GLYPHS = r"""
! ..#.. ..#.. ..#.. ..#.. ..#.. ..... ..#..
" .#.#. .#.#. .#.#. ..... ..... ..... .....
# .#.#. .#.#. ##### .#.#. ##### .#.#. .#.#.
$ ..#.. .#### #.#.. .###. ..#.# ####. ..#..
% ##... ##..# ...#. ..#.. .#... #..## ...##
& .##.. #..#. #.#.. .#... #.#.# #..#. .##.#
' ..#.. ..#.. .#... ..... ..... ..... .....
( ...#. ..#.. .#... .#... .#... ..#.. ...#.
) .#... ..#.. ...#. ...#. ...#. ..#.. .#...
* ..... ..#.. #.#.# .###. #.#.# ..#.. .....
+ ..... ..#.. ..#.. ##### ..#.. ..#.. .....
, ..... ..... ..... ..... .##.. ..#.. .#...
- ..... ..... ..... ##### ..... ..... .....
. ..... ..... ..... ..... ..... .##.. .##..
/ ..... ....# ...#. ..#.. .#... #.... .....
0 .###. #...# #..## #.#.# ##..# #...# .###.
1 ..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.
2 .###. #...# ....# ...#. ..#.. .#... #####
3 ##### ...#. ..#.. ...#. ....# #...# .###.
4 ...#. ..##. .#.#. #..#. ##### ...#. ...#.
5 ##### #.... ####. ....# ....# #...# .###.
6 ..##. .#... #.... ####. #...# #...# .###.
7 ##### ....# ...#. ..#.. .#... .#... .#...
8 .###. #...# #...# .###. #...# #...# .###.
9 .###. #...# #...# .#### ....# ...#. .##..
: ..... .##.. .##.. ..... .##.. .##.. .....
; ..... .##.. .##.. ..... .##.. ..#.. .#...
< ...#. ..#.. .#... #.... .#... ..#.. ...#.
= ..... ..... ##### ..... ##### ..... .....
> .#... ..#.. ...#. ....# ...#. ..#.. .#...
? .###. #...# ....# ...#. ..#.. ..... ..#..
@ .###. #...# ....# .##.# #.#.# #.#.# .###.
A .###. #...# #...# ##### #...# #...# #...#
B ####. #...# #...# ####. #...# #...# ####.
C .###. #...# #.... #.... #.... #...# .###.
D ###.. #..#. #...# #...# #...# #..#. ###..
E ##### #.... #.... ####. #.... #.... #####
F ##### #.... #.... ####. #.... #.... #....
G .###. #...# #.... #.### #...# #...# .####
H #...# #...# #...# ##### #...# #...# #...#
I .###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.
J ..### ...#. ...#. ...#. ...#. #..#. .##..
K #...# #..#. #.#.. ##... #.#.. #..#. #...#
L #.... #.... #.... #.... #.... #.... #####
M #...# ##.## #.#.# #.#.# #...# #...# #...#
N #...# #...# ##..# #.#.# #..## #...# #...#
O .###. #...# #...# #...# #...# #...# .###.
P ####. #...# #...# ####. #.... #.... #....
Q .###. #...# #...# #...# #.#.# #..#. .##.#
R ####. #...# #...# ####. #.#.. #..#. #...#
S .#### #.... #.... .###. ....# ....# ####.
T ##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..
U #...# #...# #...# #...# #...# #...# .###.
V #...# #...# #...# #...# #...# .#.#. ..#..
W #...# #...# #...# #.#.# #.#.# #.#.# .#.#.
X #...# #...# .#.#. ..#.. .#.#. #...# #...#
Y #...# #...# #...# .#.#. ..#.. ..#.. ..#..
Z ##### ....# ...#. ..#.. .#... #.... #####
[ .###. .#... .#... .#... .#... .#... .###.
\ ..... #.... .#... ..#.. ...#. ....# .....
] .###. ...#. ...#. ...#. ...#. ...#. .###.
^ ..#.. .#.#. #...# ..... ..... ..... .....
_ ..... ..... ..... ..... ..... ..... ..... #####
` .#... ..#.. ...#. ..... ..... ..... .....
a ..... ..... .###. ....# .#### #...# .####
b #.... #.... #.##. ##..# #...# #...# ####.
c ..... ..... .###. #.... #.... #...# .###.
d ....# ....# .##.# #..## #...# #...# .####
e ..... ..... .###. #...# ##### #.... .###.
f ..##. .#..# .#... ###.. .#... .#... .#...
g ..... ..... .#### #...# #...# .#### ....# .###.
h #.... #.... #.##. ##..# #...# #...# #...#
i ..#.. ..... .##.. ..#.. ..#.. ..#.. .###.
j ...#. ..... ..##. ...#. ...#. ...#. #..#. .##..
k #.... #.... #..#. #.#.. ##... #.#.. #..#.
l .##.. ..#.. ..#.. ..#.. ..#.. ..#.. .###.
m ..... ..... ##.#. #.#.# #.#.# #...# #...#
n ..... ..... #.##. ##..# #...# #...# #...#
o ..... ..... .###. #...# #...# #...# .###.
p ..... ..... ####. #...# #...# ####. #.... #....
q ..... ..... .#### #...# #...# .#### ....# ....#
r ..... ..... #.##. ##..# #.... #.... #....
s ..... ..... .#### #.... .###. ....# ####.
t .#... .#... ###.. .#... .#... .#..# ..##.
u ..... ..... #...# #...# #...# #..## .##.#
v ..... ..... #...# #...# #...# .#.#. ..#..
w ..... ..... #...# #...# #.#.# #.#.# .#.#.
x ..... ..... #...# .#.#. ..#.. .#.#. #...#
y ..... ..... #...# #...# #...# .#### ....# .###.
z ..... ..... ##### ...#. ..#.. .#... #####
{ ...#. ..#.. ..#.. .#... ..#.. ..#.. ...#.
| ..#.. ..#.. ..#.. ..#.. ..#.. ..#.. ..#..
} .#... ..#.. ..#.. ...#. ..#.. ..#.. .#...
~ ..... ..... .#... #.#.# ...#. ..... .....
"""


def glyph_from_rows(rows):
    out = [0] * 8
    for y, row in enumerate(rows):
        bits = 0
        for x, ch in enumerate(row):
            if ch == '#':
                bits |= 0x80 >> (x + 1)       # 5 columns at x = 1..5
        out[y] = bits
    return out


def box(up=0, down=0, left=0, right=0):
    """Box-drawing glyph. Each arm is 0 (none), 1 (single) or 2 (double)."""
    g = [[0] * 8 for _ in range(8)]
    cx, cy = 3, 3

    def vline(x, y0, y1):
        for y in range(y0, y1 + 1):
            g[y][x] = 1

    def hline(y, x0, x1):
        for x in range(x0, x1 + 1):
            g[y][x] = 1

    for arm, (a, b) in (('up', (0, cy)), ('down', (cy, 7))):
        kind = up if arm == 'up' else down
        if kind == 1:
            vline(cx, a, b)
        elif kind == 2:
            vline(cx - 1, a, b)
            vline(cx + 1, a, b)
    for arm, (a, b) in (('left', (0, cx)), ('right', (cx, 7))):
        kind = left if arm == 'left' else right
        if kind == 1:
            hline(cy, a, b)
        elif kind == 2:
            hline(cy - 1, a, b)
            hline(cy + 1, a, b)
    return [sum(0x80 >> x for x in range(8) if g[y][x]) for y in range(8)]


def build():
    font = [[0] * 8 for _ in range(256)]
    for line in GLYPHS.strip('\n').split('\n'):
        ch, *rows = line.split(' ')
        font[ord(ch)] = glyph_from_rows(rows)

    # CP437 extras used by the PERRY-DOS UI
    font[0xDB] = [0xFF] * 8                                    # full block
    font[0xDC] = [0] * 4 + [0xFF] * 4                          # lower half
    font[0xDF] = [0xFF] * 4 + [0] * 4                          # upper half
    font[0xDD] = [0xF0] * 8                                    # left half
    font[0xDE] = [0x0F] * 8                                    # right half
    font[0xB0] = [0x88, 0x22] * 4                              # light shade
    font[0xB1] = [0xAA, 0x55] * 4                              # medium shade
    font[0xB2] = [0x77, 0xDD] * 4                              # dark shade
    font[0xFE] = [0, 0, 0x3C, 0x3C, 0x3C, 0x3C, 0, 0]          # small square
    font[0xFA] = [0, 0, 0, 0x18, 0x18, 0, 0, 0]                # middle dot
    font[0x10] = [0x40, 0x60, 0x70, 0x78, 0x70, 0x60, 0x40, 0]  # right triangle
    font[0x11] = [0x04, 0x0C, 0x1C, 0x3C, 0x1C, 0x0C, 0x04, 0]  # left triangle
    font[0x1E] = [0, 0x10, 0x38, 0x7C, 0xFE, 0, 0, 0]           # up triangle
    font[0x1F] = [0, 0xFE, 0x7C, 0x38, 0x10, 0, 0, 0]           # down triangle
    font[0x07] = [0, 0, 0x18, 0x3C, 0x3C, 0x18, 0, 0]           # bullet
    font[0x18] = [0x10, 0x38, 0x54, 0x10, 0x10, 0x10, 0x10, 0]  # arrow up
    font[0x19] = [0x10, 0x10, 0x10, 0x10, 0x54, 0x38, 0x10, 0]  # arrow down
    font[0x1A] = [0, 0x08, 0x04, 0x7E, 0x04, 0x08, 0, 0]        # arrow right
    font[0x1B] = [0, 0x10, 0x20, 0x7E, 0x20, 0x10, 0, 0]        # arrow left
    font[0x0F] = [0x10, 0x54, 0x38, 0xEE, 0x38, 0x54, 0x10, 0]  # sun / gear
    font[0x01] = [0x7C, 0x82, 0xAA, 0x82, 0xBA, 0x92, 0x7C, 0]  # smiley
    # single-line boxes
    font[0xB3] = box(up=1, down=1)
    font[0xC4] = box(left=1, right=1)
    font[0xDA] = box(down=1, right=1)
    font[0xBF] = box(down=1, left=1)
    font[0xC0] = box(up=1, right=1)
    font[0xD9] = box(up=1, left=1)
    font[0xC3] = box(up=1, down=1, right=1)
    font[0xB4] = box(up=1, down=1, left=1)
    font[0xC2] = box(down=1, left=1, right=1)
    font[0xC1] = box(up=1, left=1, right=1)
    font[0xC5] = box(up=1, down=1, left=1, right=1)
    # double-line boxes
    font[0xBA] = box(up=2, down=2)
    font[0xCD] = box(left=2, right=2)
    font[0xC9] = box(down=2, right=2)
    font[0xBB] = box(down=2, left=2)
    font[0xC8] = box(up=2, right=2)
    font[0xBC] = box(up=2, left=2)
    # fix the corners of the double boxes so the inner/outer lines meet
    font[0xC9] = [0, 0, 0x1F, 0x10, 0x17, 0x14, 0x14, 0x14]
    font[0xBB] = [0, 0, 0xFC, 0x04, 0xF4, 0x14, 0x14, 0x14]
    font[0xC8] = [0x14, 0x14, 0x17, 0x10, 0x1F, 0, 0, 0]
    font[0xBC] = [0x14, 0x14, 0xF4, 0x04, 0xFC, 0, 0, 0]
    font[0xBA] = [0x14] * 8
    font[0xCD] = [0, 0, 0xFF, 0, 0xFF, 0, 0, 0]
    return font


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'emu', 'font8x8.h')
    font = build()
    with open(out, 'w') as f:
        f.write('// Generated by tools/genfont.py - do not edit.\n')
        f.write('// PERRY-16 8x8 system font, 256 glyphs, bit 7 = leftmost pixel.\n')
        f.write('#pragma once\n#include <cstdint>\n\n')
        f.write('static const uint8_t kFont8x8[256][8] = {\n')
        for i, g in enumerate(font):
            f.write('  {' + ','.join('0x%02X' % b for b in g) + '},')
            f.write('  // %02X %s\n' % (i, repr(chr(i)) if 32 <= i < 127 else ''))
        f.write('};\n')
    print('wrote', out)


if __name__ == '__main__':
    main()
