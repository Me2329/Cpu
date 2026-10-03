# pasm – the PERRY-16 assembler

`tools/pasm.py` is a standalone two-pass assembler (Python 3, standard
library only).

```sh
python3 tools/pasm.py apps/word.asm -o build/WORD.PEX          # .PEX (default)
python3 tools/pasm.py boot.asm -o boot.bin -f bin              # flat binary
python3 tools/pasm.py prog.asm -o P.PEX -l P.LST -s P.SYM -I mydir
```

| Option | Meaning |
|---|---|
| `-o FILE` | output (default: source name with `.PEX`) |
| `-f pex\|bin` | output format (default from the extension, else `pex`) |
| `-l FILE` | listing: address, bytes, source line |
| `-s FILE` | symbol map (`ADDR name`) |
| `-I DIR` | extra include directory (`include/` is always searched) |

## How it works

1. **Pass 1** reads the source (following `%include`), records labels as
   *(section, offset)*, collects `EQU` constants and computes the size of
   every statement. Instruction sizes depend only on the operand *forms*
   (an immediate is always 16 bits), so no relaxation pass is needed.
2. Section base addresses are fixed: `.code` at `ORG`, `.data` right
   after it, `.bss` after the data.
3. **Pass 2** evaluates every expression with final label addresses and
   emits the bytes, then wraps them in a `.PEX` header (or writes a flat
   binary).

## Syntax

```asm
; comment
label:  MNEMONIC operand, operand     ; one instruction per line
.local: ...                           ; local label, scoped to the last global label
NAME    EQU expression                ; constant (also NAME = expr, %define NAME expr)
```

* Mnemonics, registers and directives are case-insensitive; symbols are
  case-sensitive.
* Operands: register (`AX`…`DI`), immediate expression, or memory
  `[reg]`, `[reg+expr]`, `[reg-expr]`, `[expr+reg]`, `[expr]`.
* Byte operations use a `.B` suffix: `MOV.B AX, [SI]`, `CMP.B AX, [DI]`,
  `ADD.B [BX], CX` (`MOVB`/`CMPB` are accepted aliases).
* `REP MOVSB|MOVSW|STOSB|STOSW`.

### Expressions

C-like precedence: `|`, `^`, `&`, `<< >>`, `+ -`, `* / %`, unary `- ~ +`,
parentheses. Numbers: `123`, `0x1F`, `1Fh`, `0b1010`, `'A'` (with C
escapes `'\n'`). `$` is the address of the current statement.

```asm
        MOV AX, (DOS_EXIT << 8) | 1
        MOV DX, (GRID_TOP << 8) | 76
        MOV CX, NCELLS * CELL_SIZE / 2
```

### Directives

| Directive | Meaning |
|---|---|
| `ORG addr` | load address (once, before any code) |
| `ENTRY label` | PEX entry point (default: start of code) |
| `STACK n` | PEX stack size (default 1024) |
| `PEXFLAGS n` | PEX header flags |
| `SECTION .code` / `.data` / `.bss` | select a section (`.text`, `.rodata` accepted) |
| `DB` / `DW` | bytes / words; strings allowed: `DB "Hi", 13, 10, 0` |
| `RESB n` / `RESW n` / `DS n` | reserve zeroed space (the only thing allowed in `.bss`) |
| `TIMES n stmt` | repeat a data statement: `TIMES 80 DB 0` |
| `ALIGN n` | pad to a multiple of *n* |
| `%include "file"` | textual include (relative to the file, then `-I`, then `include/`) |
| `INCBIN "file"` | include a binary file |

### Errors

Errors stop the build with `file:line: message`, for example:

```
pasm: error: apps/x.asm:12: memory destination needs a register source (load the value into a register first)
pasm: error: apps/x.asm:30: unsupported addressing mode [AX+BX] (only [reg], [reg+disp], [disp])
pasm: error: apps/x.asm:41: PEX image + stack ends at 0xA210, beyond system RAM (0xA000)
```

## Runtime library (`include/`)

| File | Contents |
|---|---|
| `perry.inc` | memory map, ports, INT/DOS function numbers, key codes, colours |
| `lib/stdio.inc` | `print_str` `print_char` `print_nl` `print_dec` `print_sdec` `print_hex` `print_dec_w` `print_dec32_w` `utoa` `itoa` `u32toa` `udiv32` `atoi` `to_upper` `str_len` `str_copy` `str_upper` `str_cmpi` `str_ends_with` `skip_spaces` |
| `lib/tui.inc` | text-mode UI in VRAM: `tui_addr` `tui_putc` `tui_puts` `tui_putsn` `tui_fill` `tui_clear` `tui_box` `tui_cursor` `tui_cursor_on/off` `tui_getkey` |

**Calling convention:** arguments and results in registers (documented
per routine); every other register is preserved, FLAGS are not. Results
that signal success use CF (0 = ok). Include the libraries at the end of
your code section – they switch to `.data`/`.bss` for their own buffers
and back to `.code`.

Remember that word `MUL`/`IMUL`/`DIV`/`IDIV` write DX (high word /
remainder) unless DX is the destination.
