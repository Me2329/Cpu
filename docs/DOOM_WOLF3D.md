# Running Doom / Wolfenstein 3D on PERRY-16 – integration strategy

This document explains how a 16-bit port of id Software's engines maps
onto the PERRY-16 machine: what already works today (the `RAYCAST.PEX`
reference game), what the real engines need, and the concrete
engineering path to get there.

## 1. Honest feasibility check

| | Wolfenstein 3D (1992) | Doom (1993) | PERRY-16 today |
|---|---|---|---|
| CPU | 286, 16-bit real mode | 386, 32-bit protected mode | 16-bit, flat 64 KB |
| RAM | ~500+ KB conventional (+EMS/XMS cache) | 4 MB | 36 KB system RAM, 28 KB per program |
| Language | Borland C + asm | Watcom C (32-bit) | assembly (pasm) |
| Video | VGA mode 13h / Mode Y | 320×200×8 linear buffer | 320×200×256, banked window + blit service |
| Music | AdLib (IMF register streams) | OPL2 via MUS + GENMIDI patches | OPL2 at 388h/389h |
| Data | VSWAP / MAPHEAD / GAMEMAPS | one WAD file | PFS disk, INT 21h files, 32-bit seek |

**Conclusion:** the original source code cannot be recompiled for the
current machine as-is. Both engines assume hundreds of kilobytes (Wolf3D)
or megabytes (Doom) of addressable memory and a C compiler; Doom also
assumes 32-bit integers everywhere (`fixed_t` is 16.16). Everything else –
file I/O, WAD access, palette, framebuffer presentation, OPL2 music,
keyboard and timer – is already provided by PERRY-DOS in the same shape
the games expect. Community projects such as Doom8088 (a 16-bit real-mode
Doom derived from GBADoom) show that a heavily restructured Doom fits a
16-bit CPU with about 640 KB of RAM; the missing pieces here are therefore **memory
capacity** and **a C toolchain**, not the I/O model.

## 2. What already works: RAYCAST.PEX

`games/raycast.asm` is a Wolfenstein-style engine built on the exact
pipeline a port would use, so each subsystem below is proven end-to-end
(see `tests/scripts/05_raycast.txt`).

```
 MAZE.WAD on disk.img (PWAD: header, lumps, directory)
        |  INT 21h 3Dh open / 42h seek / 3Fh read        (W_ReadLump)
        v
 +------------+   PLAYPAL ---> OUT 3C8h/3C9h  -> VGA DAC (I_SetPalette)
 | lump cache |   MAP01   ---> 16x16 grid
 | (TPA RAM)  |   THINGS  ---> player start
 +------------+   MUSIC   ---> OPL2 sequencer -> OUT 388h/389h (I_PlaySong)
        |
        v  per column: grid DDA, 8.8 fixed point, camera plane,
           brick texture, distance shading (COLORMAP-style)
 +------------------+
 | 160x100 back     |  INT 10h AH=41h: 2x blit into the 64000-byte
 | buffer (16 KB)   |  framebuffer behind the A000h window (I_FinishUpdate,
 +------------------+  Doom "low detail")
        |
        v  INT 10h AH=42h/43h: HUD text + automap overlay
   INT 16h polling (I_StartTic)   HLT until the 70 Hz tick (frame pacing)
```

### WAD loading through OS interrupts

The WAD container is the genuine id format (`tools/mkwad.py` builds it):

```
offset 0   "PWAD" | int32 numlumps | int32 infotableofs
           ... lump data ...
infotableofs: numlumps x { int32 filepos, int32 size, char name[8] }
```

`wad_find` seeks to `infotableofs` (INT 21h AH=42h with the 32-bit offset
in CX:DX) and reads 16-byte directory entries until the name matches;
`wad_read_lump` seeks to `filepos` and reads `min(size, buffer)` bytes.
A real `DOOM1.WAD` (≈4 MB, over a thousand lumps) works with the same calls – the
file system supports 32-bit sizes and offsets – only the destination
memory is missing (see §3).

### Pushing audio to the AdLib ports

`adlib_detect` runs the classic detection sequence (reset timers, start
timer 1, expect status `C0h`); `opl_write` writes index → 388h, data →
389h with the canonical status-read delays; instruments are programmed
from a register/value table and the `MUSIC` lump drives key-on/off with
70 Hz tick timing. Doom's `GENMIDI` lump contains OPL2 instrument
definitions in exactly this register form, and Wolf3D's music is an IMF
stream of *(register, value, delay)* triples – both play directly on this
OPL2 model (IMF wants a 560/700 Hz timer, see §4).

### Blitting framebuffers to VRAM

The VGA framebuffer is 64 000 bytes but the CPU sees it through the 6 KB
window at A000h, selected in 4 KB banks with `OUT 3CDh` (like ET4000/VESA
banking). Two strategies, both implemented:

* **Direct banked writes** – `PAINT.PEX` computes `offset = y*320+x`,
  `bank = offset >> 12`, writes `A000h + (offset & 0FFFh)`, switching banks
  only when needed. Good for sparse updates.
* **Blit service** – games render into RAM and present a whole frame with
  `INT 10h AH=40h` (linear copy) or `AH=41h` (2× scaled). This is the
  equivalent of Doom's `I_FinishUpdate` copying `screens[0]` to A000h.

## 3. Step 1 – memory: the PERRY-16X mapper

Both engines need a large heap (Doom's zone memory, Wolf3D's `ID_MM` with
EMS/XMS caching). The least invasive extension is a paging unit between
the CPU and the bus; the ISA does not change.

* 16 page registers, each mapping a 4 KB virtual page to a 4 KB physical
  frame in up to 16 MB (12-bit frame number): `OUT 0x00E0+page, frame`.
* Physical memory below 64 KB keeps today's map, so PERRY-DOS and the
  existing programs run unmodified (identity mapping at reset).
* The OS gives every process its own 64 KB, and games map WAD lumps and
  zone blocks into a few "window" pages on demand – exactly how DOS games
  used the EMS page frame.

Implementation cost: in `Machine::read8/write8` one table lookup
(`phys = frame[addr >> 12] << 12 | (addr & 0xFFF)`); in RTL, a 16×12-bit
register file in front of `mem_addr`. INT 21h gains `AH=48h/49h`
(allocate / free frames) and a "map" call.

## 4. Step 2 – toolchain: C for PERRY-16

1. **Compiler.** Retarget an existing small compiler rather than writing
   one: `lcc` (table-driven `lburg` back end) or an LLVM back end modelled
   on the MSP430 target (also 16-bit registers and pointers). Code
   generation maps cleanly: `int` = 16 bit, `long` = 32 bit via `ADC`/
   `SBB` pairs, `MUL` gives a full 32-bit product in `DX:AX`.
2. **Assembler / linker.** Extend `pasm` with relocatable objects
   (sections + relocation records) and add a linker that emits `.PEX`
   with an overlay or banked-segment table.
3. **C runtime.** `crt0` (set up BSS/stack, call `main`, `INT 21h AH=4Ch`)
   and a libc subset on top of the documented services: `open/read/
   lseek/close` → AH=3Dh/3Fh/42h/3Eh, `malloc` → mapper frames,
   `printf` → AH=09h/40h.
4. **Timer.** Add a programmable rate to the 70 Hz timer (PIT-style port)
   for Doom's 35 Hz tics and IMF's 560/700 Hz music clock.

## 5. Step 3 – porting the engines

| Engine subsystem | PERRY-16 implementation |
|---|---|
| `W_ReadLump`, `W_CacheLumpNum` | INT 21h seek/read into mapped pages (as `wad_read_lump`) |
| zone memory / `ID_MM` | mapper frames instead of conventional/EMS memory |
| `I_SetPalette` (PLAYPAL) | OUT 3C8h + 768 × OUT 3C9h (values >> 2) |
| `I_FinishUpdate` | `INT 10h AH=40h` blit of the 320×200 buffer (or AH=41h for low detail) |
| `COLORMAP` light levels | 34 × 256 byte remap tables – RAYCAST uses the same idea with shade ramps |
| `I_StartTic` keyboard | hook IRQ 9 with `INT 21h AH=25h`, read make/break codes from port 60h |
| `I_GetTime` | BIOS tick counter at 0400h (70 Hz → 35 Hz tics) |
| music (MUS / IMF) | OPL2 at 388h/389h with GENMIDI / IMF data |
| `FixedMul` / `FixedDiv` (16.16) | 32-bit helpers on `MUL`/`DIV` + `ADC`/`SBB`; hottest paths in assembly |

Performance budget: the C++ emulator executes ≈ 55 million PERRY-16
instructions per second on a modern host (`--mhz` raises the emulated
clock far above the nominal 8 MHz; the host speed is the ceiling), and the RTL core averages ≈ 3.7
clocks per instruction – ≈ 13 MIPS on a 50 MHz FPGA. A Doom frame at
160×100 "low detail" with 16-bit arithmetic needs on the order of a few
million instructions, so expect playable rates in the emulator and
single-digit to low-double-digit frame rates on an FPGA without further
micro-architectural work.

## 6. Legal notes

Doom's and Wolfenstein 3D's source code are available under the GPL;
their game data is not. The shareware data files (`DOOM1.WAD`, the
Wolf3D shareware episode) are freely redistributable as unmodified
shareware but are not included here. `MAZE.WAD` is original content
generated by `tools/mkwad.py`, and the RAYCAST music is an original tune.
