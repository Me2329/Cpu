# PERRY-16 system architecture

PERRY-16 is a complete, small computer: a custom 16-bit CPU (as an
emulator and as synthesizable RTL), a PC-like set of devices, firmware,
a DOS-like operating system and applications, all built from source in
this repository.

```
+--------------------------------------------------------------------------+
|  Applications (.PEX)   WORD  EXCEL  PAINT  RAYCAST  HELLO      apps/ games/
+--------------------------------------------------------------------------+
|  PERRY-DOS shell       COMMAND.PEX: prompt, DIR/RUN/MEM/..., EXPLORER    os/
+--------------------------------------------------------------------------+
|  Firmware services     INT 10h video  16h keyboard  21h DOS  33h mouse   emu/bios.cpp
|  (HLE behind "BIOS n") process manager + .PEX loader, PFS file system    emu/machine.cpp emu/pfs.cpp
+--------------------------------------------------------------------------+
|  Devices               VGA (text + 13h, DAC, banks)  keyboard  mouse     emu/machine.cpp
|                        AdLib OPL2  70 Hz timer  debug/power ports        emu/opl2.cpp
+--------------------------------------------------------------------------+
|  CPU                   PERRY-16 ISA: emulator core  |  RTL core          emu/cpu.cpp rtl/
+--------------------------------------------------------------------------+
|  Host frontends        SDL2 window + audio | ANSI terminal | headless    emu/main.cpp
+--------------------------------------------------------------------------+
   Toolchain: pasm.py (assembler) -> .PEX -> mkdisk.py -> disk.img       tools/
```

Reference documents: [ISA.md](ISA.md) ·
[BIOS_DOS_API.md](BIOS_DOS_API.md) · [PEX_FORMAT.md](PEX_FORMAT.md) ·
[ASSEMBLER.md](ASSEMBLER.md) · [DOOM_WOLF3D.md](DOOM_WOLF3D.md)

## 1. CPU

* 8 general 16-bit registers `AX BX CX DX SP BP SI DI`, `PC`, `FLAGS`
  (CF ZF SF IF OF at the x86 bit positions).
* 2- or 4-byte instructions: opcode, mode byte (`B|rd|rs`), optional
  16-bit immediate. One uniform two-operand ALU group with 8 addressing
  modes (`reg,reg` `reg,imm` `reg,[reg]` `reg,[reg+d]` `reg,[abs]`
  `[reg],reg` `[reg+d],reg` `[abs],reg`) covers MOV, arithmetic, logic,
  MUL/DIV, shifts, LEA, XCHG and MOVSX, in word or byte width.
* Control flow (Jcc with 14 conditions, CALL/RET, LOOP, JCXZ), stack
  (PUSH/POP/PUSHA/POPA/PUSHF/POPF), port I/O (IN/OUT), string ops
  (MOVS/STOS/LODS with REP), INT/IRET, HLT and the `BIOS n` trap.

The design goal was "8086 feel, RISC-simple decode": every instruction is
decoded from the first two bytes, there is no ModR/M complexity and no
segments, which keeps both the emulator switch and the RTL state machine
small. Full details in [ISA.md](ISA.md).

## 2. Memory map

| Range | Size | Use |
|---|---|---|
| `0000-03FF` | 1 KB | **IVT**: 256 vectors × 4 bytes (word 0 = handler) |
| `0400-04FF` | 256 B | BIOS data area: `0400` u32 tick counter (70 Hz), `0404` cursor column, `0405` row, `0406` video mode, `0407` text attribute, `0408` cursor visible |
| `0500-05FF` | 256 B | kernel scratch |
| `0600-067F` | 128 B | command line of the running program (ASCIIZ) |
| `0680-06FF` | 128 B | default DTA (directory search results) |
| `0700-0FFF` | 2.3 KB | free low RAM (bare-metal stack in `--raw` mode) |
| `1000-9FFF` | 36 KB | **system RAM**: `1000-2FFF` resident shell, `3000-9FFF` TPA for programs |
| `A000-B7FF` | 6 KB | **graphics VRAM window** into the 64 000-byte 320×200×256 framebuffer |
| `B800-C79F` | 4000 B | **text VRAM** 80×25 × (character, attribute) |
| `C7A0-C7FF` | 96 B | unused |
| `C800-EFFF` | 10 KB | upper RAM, free for programs (the shell caches the directory at `E800`) |
| `F000-F3FF` | 1 KB | ROM: 256 interrupt stubs `BIOS n ; IRET` |
| `F400-F7FF` | 1 KB | ROM: BIOS identification string |
| `F800-FFFF` | 2 KB | ROM: 8×8 system font, 256 glyphs |

### Why two ranges differ from the original sketch

The requested map placed graphics VRAM at `A000-B7FF` and text VRAM at
`B800-BC00`. Two of those ranges are too small for what they must hold:

* **320×200 at 256 colours is 64 000 bytes**, but `A000-B7FF` is only
  6 144 bytes. Rather than giving up 64 KB of a 64 KB address space, the
  framebuffer lives in the video device and `A000h` is a **bank window**
  (4 KB granularity, bank register at port `3CDh`, the same scheme as the
  Tseng ET4000 and VESA windowed modes). Writes up to `B7FF` continue
  into the next 2 KB of the framebuffer, so short runs that cross a 4 KB
  boundary still land correctly. For whole frames, `INT 10h AH=40h/41h`
  blit a RAM buffer into the framebuffer in one call.
* **80×25 text with attributes is 4 000 bytes**, but `B800-BC00` is
  1 024 bytes. The text buffer therefore spans `B800-C79F`, keeping the
  familiar `B800h` start address and the `(char, attribute)` cell format.

Everything else follows the sketch: IVT at 0, system RAM `1000-9FFF`.

## 3. Devices

| Device | Interface | Model |
|---|---|---|
| VGA | text VRAM in memory; framebuffer via the A000h window; DAC ports 3C7h–3C9h; bank 3CDh; status 3DAh | modes 03h and 13h, 16-colour CGA palette in text mode, 256 × 18-bit DAC, vertical-retrace bit, hardware mouse cursor overlay |
| Keyboard | INT 16h / INT 21h, port 60h/64h, IRQ 9 | 32-entry buffer of `(scancode << 8) \| ascii` codes |
| Mouse | INT 33h | position, 3 buttons, ranges, show/hide |
| AdLib | ports 388h/389h | 9-channel 2-operator FM (FM/additive, feedback, multipliers, total level, ADSR, 4 waveforms, timer status for detection) mixed at 44.1 kHz |
| Timer | IRQ 8 at 70 Hz | also increments the BDA tick counter; wakes `HLT` |
| Disk | INT 21h file services | `disk.img` with the PFS file system |
| Debug / power | ports E9h / F4h | Bochs-style debug console; QEMU-style power-off with exit code |

## 4. Firmware model: ROM stubs + high-level emulation

At power-on every IVT entry *n* points at a 4-byte ROM stub:

```
F000 + n*4:   DF n      BIOS n      ; trap into the native service n
              C7 00     IRET
```

So `INT 21h` is a completely ordinary interrupt – push FLAGS and PC, jump
through the IVT – and the stub's `BIOS 21h` instruction hands control to
`Machine::bios_trap(0x21)` in `emu/bios.cpp`, which implements the service
in C++ (that is what "high-level emulation" means: the firmware is native
code instead of guest code). Consequences:

* **Hooking works like on a PC.** A program can install its own handler
  with `INT 21h AH=25h`, and chain to the original by calling the stub
  address it got from `AH=35h`.
* **Results survive `IRET`.** Services set CF/ZF in the live FLAGS *and* in
  the FLAGS image on the stack (`[SP+2]`), which `IRET` restores.
* **Blocking without threads.** A service that must wait for input (`INT
  16h AH=00h`, `INT 21h AH=01h/0Ah`) rewinds PC onto the `BIOS`
  instruction and marks the machine idle. The run loop stops burning
  cycles until the frontend delivers a key, then the trap re-executes.
* **The RTL core is firmware-agnostic.** In hardware, `BIOS n` raises
  `bios_req`/`bios_vector` and waits for `bios_done`; a soft-core system
  would answer with a microcontroller or replace the stubs with guest-code
  BIOS routines.

## 5. Boot and process model

1. `Machine::power_on()` clears RAM, writes the IVT + ROM stubs + font,
   resets the palette and sets text mode.
2. `Machine::boot("COMMAND.PEX")` loads the shell from `disk.img` with the
   .PEX loader (header check, checksum, copy code+data, clear BSS+stack,
   `SP` = end of image, `PC` = entry).
3. The shell's `EXEC` (`INT 21h AH=4Bh`) loads an application into the
   TPA; the shell's register context is saved inside its interrupt frame.
4. `INT 21h AH=4Ch` closes the program's files, restores the shell
   context with `AX` = exit code and returns from the shell's `INT 21h`.
5. When the shell itself exits (`EXIT`), the machine powers off.

Overlapping images are refused ("not enough memory"), so a program can
start another one only if their load ranges don't collide. Details and
the loader source are in [PEX_FORMAT.md](PEX_FORMAT.md).

## 6. PERRY-DOS and the applications

| Program | Size | Highlights |
|---|---|---|
| `COMMAND.PEX` | ~6 KB | line input via `INT 21h AH=0Ah`; command table dispatch; EXEC with arguments; file-type associations (`.TXT`→WORD, `.XLS`→EXCEL, `.WAD`→RAYCAST, `.IMG`→PAINT); full-screen **Explorer** drawn directly in text VRAM with scrolling list, detail pane, open/delete |
| `WORD.PEX` | ~4 KB | flat 16 KB document buffer with `\n` line separators; insert/delete by memmove (`REP MOVSB`); line-start/line-end navigation; vertical and horizontal scrolling; live line/column/character/word counts; save/open/new with prompts; dirty tracking |
| `EXCEL.PEX` | ~5 KB | 8×20 grid, 15-char cells; recursive-descent formula engine (`+ - * /` with precedence, parentheses, cell references, `SUM/AVG/MIN/MAX(range)`); recursion with a BP stack frame and a depth limit for circular references; text file format `B4=800` |
| `PAINT.PEX` | ~2.4 KB | mode 13h; INT 33h mouse polling at 70 Hz with `HLT`; Bresenham strokes with square brushes written straight into the banked A000h window; DAC-programmed toolbar colour; save/load of the canvas bank by bank through INT 21h |
| `RAYCAST.PEX` | ~5.4 KB | Wolf3D-style grid DDA renderer, WAD lump loader, PLAYPAL → DAC, OPL2 music, automap – see [DOOM_WOLF3D.md](DOOM_WOLF3D.md) |

All of them are written in PERRY-16 assembly and share `include/lib/*.inc`.

## 7. The emulator

* **Main loop.** Frontends call `Machine::run_frame()` 70 times per
  second; each frame executes `clock_hz / 70` cycles (8 MHz default,
  `--mhz`), then increments the tick counter and raises IRQ 8. An idle
  machine (blocked on input or halted) skips the rest of the frame.
* **Speed.** ≈ 55 million instructions per second on a modern x86 host,
  so the nominal 8 MHz machine uses a few percent of one core.
* **Frontends** (`emu/main.cpp`):
  * SDL2: 640×400 window (scalable), keyboard/text input, mouse, OPL2
    audio through `SDL_QueueAudio`.
  * ANSI terminal (`--term`): truecolour text mode, CP437 → Unicode box
    drawing, half-block graphics for mode 13h, SGR mouse, Ctrl+Q quits.
  * Headless (`--script`): scripted keys/mouse/waits, `expect` checks on
    the text screen, `expectpixel`, PNG screenshots, WAV capture.
  * Bare metal (`--raw file.bin`): no firmware services needed, port E9h →
    stdout, port F4h → exit code; `--trace` prints every instruction.

## 8. The RTL core

`rtl/perry16_cpu.sv` is a multi-cycle implementation of the same ISA:

```
 S_FETCH --(opcode+mode word)--> S_IMM? --> S_EXEC
    ^                                         |
    |   ALU:   S_RD_SRC / S_RD_DST --> S_ALU --> S_WR
    |   stack: S_PUSH  S_POP  S_PUSHA  S_POPA
    |   INT:   S_INT1 (push FLAGS) -> S_INT2 (push PC) -> S_INT3 (read IVT)
    |   REP:   S_STR_RD <-> S_STR_WR (CX counts down)
    +-- S_BIOS (bios_req until bios_done)   S_HALT (until IRQ)
```

* Memory: byte-interleaved dual-bank RAM so any byte or unaligned word is
  one cycle; asynchronous read. I/O and IRQ/BIOS handshakes are simple
  ports on the module.
* The ALU is a single SystemVerilog function shared by all paths, written
  to match `CPU::alu` bit for bit.
* Verification: `tests/run_tests.py` runs `tests/cpu/selftest.asm` on both
  models and compares the **full per-instruction trace** (PC, eight
  registers, FLAGS); `tests/fuzz_cpu.py` generates random programs
  (ALU in all modes and widths, shifts by 0–31, MUL/IMUL/DIV/IDIV, XCHG,
  MOVSX, LEA, stack, POPF, conditional jumps) for the same lockstep
  comparison.
* Synthesis notes: MUL/DIV use `*` and `/` for clarity (iterative units
  would save area); the debug outputs can be left unconnected.

## 9. Build and test

```sh
make            # emulator (+SDL2 if found), all programs, build/disk.img
make run        # SDL2 window (falls back to the terminal)
make term       # terminal frontend
make test       # assembler, CPU, RTL, lockstep fuzzing, OS/app scenarios
```

Requirements: a C++17 compiler, Python 3, optionally SDL2 (window +
sound) and Icarus Verilog (RTL tests).
