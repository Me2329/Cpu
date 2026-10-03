# PERRY-16 Firmware & PERRY-DOS API reference

Services are called with `INT n`. Inputs/outputs are registers; "AH" and
"AL" are the high/low byte of `AX` (load them together, e.g.
`MOV AX, 0x4C00 | code`). Errors are reported DOS-style with **CF = 1 and
an error code in AX**. Services are implemented natively by the emulator
(see "firmware model" in [ARCHITECTURE.md](ARCHITECTURE.md)); any vector
can be re-hooked by a program.

Error codes: 1 invalid function, 2 file not found, 4 too many open files,
5 access denied, 6 invalid handle, 8 not enough memory, 11 invalid
executable format, 18 no more files.

## INT 10h – video

| AH | Function | Input | Output |
|---|---|---|---|
| 00 | set video mode | AL = `03h` text 80×25 / `13h` 320×200×256 | screen cleared, palette reset |
| 01 | cursor shape | CX = `2000h` hide, `0607h` show | |
| 02 | set cursor | DH = row, DL = column | |
| 03 | get cursor | | DH = row, DL = column, CX = shape |
| 06 | scroll window up | AL = lines (0 = clear), BH = fill attribute, CH,CL = top-left, DH,DL = bottom-right | |
| 08 | read char/attr at cursor | | AL = char, AH = attribute |
| 09 | write char/attr ×CX at cursor | AL = char, BL = attribute, CX = count | cursor not moved |
| 0A | write char ×CX at cursor | AL = char, CX = count | |
| 0C | put pixel (mode 13h) | AL = colour, CX = x, DX = y | |
| 0D | get pixel | CX = x, DX = y | AL = colour |
| 0E | teletype output | AL = char, BL = colour (mode 13h) | CR, LF, BS, TAB, scrolling |
| 0F | get video mode | | AL = mode, AH = columns |
| 13 | write string | SI = ASCIIZ, BL = attribute, DH,DL = position | (PERRY: SI instead of ES:BP) |
| **40** | linear blit | SI = source, DI = framebuffer offset, CX = bytes | copies RAM → VRAM without banking |
| **41** | 2× blit | SI = source, BX = width, CX = height, DI = framebuffer offset of top-left | every pixel doubled (Doom "low detail") |
| **42** | graphics text | SI = ASCIIZ, CX = x, DX = y, BL = colour, BH = background (`FFh` = transparent) | 8×8 ROM font |
| **43** | fill rectangle | CX = x, DX = y, SI = width, DI = height, BL = colour | |

Bold entries are PERRY extensions.

## INT 16h – keyboard

Key codes are `AX = (scancode << 8) | ascii` (PC/AT scancodes; extended
keys have ASCII 0): Esc `011Bh`, Enter `1C0Dh`, Backspace `0E08h`,
Tab `0F09h`, Up `4800h`, Down `5000h`, Left `4B00h`, Right `4D00h`,
Home `4700h`, End `4F00h`, PgUp `4900h`, PgDn `5100h`, Del `5300h`,
F1–F10 `3B00h`–`4400h`. Constants are in `include/perry.inc`.

| AH | Function | Output |
|---|---|---|
| 00 / 10 | wait for key | AX = key (blocks; the CPU idles) |
| 01 / 11 | check for key | ZF = 1 none; ZF = 0 and AX = key (not removed) |
| 02 | shift flags | AL = 0 |

## INT 33h – mouse (function in AX)

| AX | Function | Input / Output |
|---|---|---|
| 0000 | reset | → AX = `FFFFh` (installed), BX = 3 buttons; cursor hidden and centred |
| 0001 | show cursor | |
| 0002 | hide cursor | |
| 0003 | get state | → BX = buttons (bit0 left, bit1 right, bit2 middle), CX = x, DX = y |
| 0004 | set position | CX = x, DX = y |
| 0007 / 0008 | set x / y range | CX = min, DX = max |

Coordinates: mode 13h → pixels (0–319, 0–199); text mode → 0–639 × 0–199
(cell = x/8, y/8), as in DOS. The cursor is a hardware overlay drawn by
the display, never written into VRAM.

## INT 20h – terminate program (exit code 0)

## INT 21h – PERRY-DOS

| AH | Function | Input | Output |
|---|---|---|---|
| 01 | read key with echo | | AL = ascii, AH = scancode |
| 02 | print char | DL = char | |
| 07 / 08 | read key (no echo) | | AL = ascii, AH = scancode |
| 09 | print string | DX = **ASCIIZ** string | (PERRY: NUL terminated, not `$`) |
| 0A | buffered line input | DX = buffer: `[max][count][chars…]` | count set, chars end with CR; Backspace/Esc editing |
| 0B | key available? | | AL = `FFh` yes / `00h` no |
| 19 | current drive | | AL = 0 (A:) |
| 1A | set DTA | DX = address | |
| 25 | set interrupt vector | AL = vector, DX = handler | |
| 2A | get date | | CX = year, DH = month, DL = day, AL = weekday |
| 2C | get time | | CH = hour, CL = minute, DH = second |
| 30 | version | | AL = 1, AH = 0, BX = `5016h` |
| 35 | get interrupt vector | AL = vector | BX = handler |
| 36 | disk space | | AX = free KB, BX = total KB, CX = 512 |
| 3C | create / truncate file | DX = name | AX = handle |
| 3D | open file | DX = name, AL = 0 read / 1 write / 2 both | AX = handle |
| 3E | close | BX = handle | |
| 3F | read | BX = handle, CX = bytes, DX = buffer | AX = bytes read (0 = EOF) |
| 40 | write | BX = handle (1/2 = console), CX = bytes, DX = buffer | AX = bytes written |
| 41 | delete | DX = name | (system/read-only files refused) |
| 42 | seek | BX = handle, AL = 0 start / 1 current / 2 end, CX:DX = signed offset | DX:AX = new position |
| 4B | **EXEC** – run program | DX = name (`.PEX` added if no extension), BX = argument string or 0 | returns when the child exits: AL = exit code |
| 4C | exit | AL = exit code | |
| 4D | last exit code | | AL |
| 4E | find first | DX = pattern (`*.*`, `*.PEX`, `WO?D.*`) | DTA filled |
| 4F | find next | | DTA filled, CF = 1 when done |
| **58** | memory info | | AX = free conventional bytes, BX = total conventional, CX = upper RAM, DX = bytes used by loaded programs |
| 62 | command line | | BX = address of the ASCIIZ argument string (`0600h`) |

**DTA layout** (32 bytes): `+0` attribute, `+2` size low word, `+4` size
high word, `+6` internal search index, `+8` 13-byte ASCIIZ name.

Files live on `disk.img` (PFS, see [PEX_FORMAT.md](PEX_FORMAT.md)); names
are 8.3, case-insensitive, optionally prefixed with `A:\`. Up to 11 files
can be open at once (handles 5–15); handles left open are closed when a
program exits.

## I/O ports

| Port | Dir | Device |
|---|---|---|
| `0040h` | in | free-running cycle counter (low 16 bits) – random seeds, timing |
| `0060h` | in | last keyboard scancode (bit 7 = key released) |
| `0064h` | in | bit 0 = key waiting |
| `00E9h` | out | debug console (character to the host's stderr / stdout in `--raw` mode) |
| `00F4h` | out | power off, value = exit code |
| `0388h` | out / in | AdLib OPL2 register index / status (timer flags for detection) |
| `0389h` | out | AdLib OPL2 register data |
| `03C7h` / `03C8h` | out | VGA DAC read / write index |
| `03C9h` | in/out | VGA DAC data: R, G, B (6 bit), auto-increment |
| `03CDh` | in/out | VGA bank: framebuffer offset `bank × 4096` appears at `A000h` |
| `03DAh` | in | VGA status, bit 3 = vertical retrace |

## Writing a program

```asm
        ORG 0x3000              ; applications load in the TPA
        ENTRY main
        STACK 1024
        %include "perry.inc"

SECTION .code
main:   MOV DX, hello
        MOV AX, DOS_PUTS << 8
        INT INT_DOS
        MOV AX, (DOS_EXIT << 8) | 0
        INT INT_DOS

SECTION .data
hello:  DB "Hello, PERRY-DOS!", 13, 10, 0
```
