# PERRY-16 Instruction Set Architecture

The same ISA is implemented three times and the implementations are tested
against each other instruction by instruction:

| Implementation | File | Role |
|---|---|---|
| Assembler (encoder) | `tools/pasm.py` | turns assembly into machine code |
| Instruction-level emulator | `emu/cpu.cpp` | runs PERRY-DOS and the apps |
| RTL core | `rtl/perry16_cpu.sv` | synthesizable hardware description |

`tests/run_tests.py` runs a self-test program and thousands of random
instructions on the emulator **and** the RTL and requires identical PC,
registers and FLAGS after every instruction.

## 1. Programmer's model

| Register | # | Conventional use |
|---|---|---|
| `AX` | 0 | accumulator, function number for `INT` (AH = high byte) |
| `BX` | 1 | base / handle |
| `CX` | 2 | count (`LOOP`, `JCXZ`, `REP`) |
| `DX` | 3 | data, high word of `MUL`, remainder of `DIV` |
| `SP` | 4 | stack pointer (stack grows down, word pushes) |
| `BP` | 5 | frame pointer (`[BP-2]` locals) |
| `SI` | 6 | source index (string ops) |
| `DI` | 7 | destination index (string ops) |
| `PC` | – | program counter |
| `FLAGS` | – | status / control |

All registers are 16 bits, any register can be used as a base address.
There are no segment registers: the address space is a flat 64 KB
(`0x0000-0xFFFF`), little endian, plus a separate 64 K I/O port space.
"AH"/"AL" in the documentation mean the high/low byte of `AX` – they are
not separate registers.

**FLAGS** (x86-compatible bit positions):

| Bit | Flag | Meaning |
|---|---|---|
| 0 | CF | carry / borrow (unsigned overflow), last bit shifted out |
| 6 | ZF | result is zero |
| 7 | SF | result is negative (top bit) |
| 9 | IF | maskable interrupts enabled |
| 11 | OF | signed overflow |

## 2. Instruction encoding

Every instruction is **2 or 4 bytes**: an opcode byte, a mode byte and an
optional 16-bit little-endian immediate.

```
 byte 0          byte 1                 bytes 2-3 (optional)
+---------------+-----------------------+----------------------+
|   opcode      | B | rd(3) | 0 | rs(3) |  imm16 (low, high)   |
+---------------+-----------------------+----------------------+
                  7   6..4   3   2..0
```

* `B` – byte operation (`.B` suffix in assembly)
* `rd` – destination register / base register of a memory destination
* `rs` – source register / base register of a memory source

### 2.1 ALU group (`opcode = op << 3 | mode`, opcodes `0x00-0xAF`)

| mode | Form | Size | Example |
|---|---|---|---|
| 0 | `op reg, reg` | 2 | `ADD AX, BX` |
| 1 | `op reg, imm16` | 4 | `ADD AX, 10` |
| 2 | `op reg, [reg]` | 2 | `MOV AX, [SI]` |
| 3 | `op reg, [reg+disp16]` | 4 | `MOV AX, [BP-2]` |
| 4 | `op reg, [addr16]` | 4 | `CMP CX, [count]` |
| 5 | `op [reg], reg` | 2 | `MOV [DI], AX` |
| 6 | `op [reg+disp16], reg` | 4 | `ADD [SI+4], DX` |
| 7 | `op [addr16], reg` | 4 | `MOV.B [0xB800], AX` |

| op | Mnemonic | Operation | Flags |
|---|---|---|---|
| 0 | `MOV` | d = s | – |
| 1 | `ADD` | d = d + s | C Z S O |
| 2 | `SUB` | d = d − s | C Z S O |
| 3 | `CMP` | d − s (result discarded) | C Z S O |
| 4 | `AND` | d = d & s | Z S, C=O=0 |
| 5 | `OR` | d = d \| s | Z S, C=O=0 |
| 6 | `XOR` | d = d ^ s | Z S, C=O=0 |
| 7 | `TEST` | d & s (discarded) | Z S, C=O=0 |
| 8 | `ADC` | d = d + s + CF | C Z S O |
| 9 | `SBB` | d = d − s − CF | C Z S O |
| 10 | `MUL` | 32-bit unsigned product: d = low word, **DX = high word**¹ | C=O=(high≠0), Z S |
| 11 | `IMUL` | signed version of `MUL` | C=O=(result doesn't fit), Z S |
| 12 | `DIV` | d = d / s, **DX = d % s**¹ (unsigned); s = 0 → `INT 0` | Z S |
| 13 | `IDIV` | signed division, truncating toward zero | Z S |
| 14 | `SHL` | shift left by s & 31 | C (last bit out), O, Z S |
| 15 | `SHR` | logical shift right | C O Z S |
| 16 | `SAR` | arithmetic shift right | C O Z S |
| 17 | `ROL` | rotate left | C O |
| 18 | `ROR` | rotate right | C O |
| 19 | `LEA` | d = effective address (modes 2-4 only) | – |
| 20 | `XCHG` | swap operands | – |
| 21 | `MOVSX` | d = sign-extended low byte of s | – |
| 22-23 | – | reserved → invalid opcode trap | |

¹ Only in word mode, only when the destination is a register other than
`DX`. A shift/rotate by 0 changes nothing, flags included.

**Byte mode** (`MOV.B`, `ADD.B`, …; `MOVB`/`CMPB` are aliases): memory
operands are 8 bits wide, ALU flags are computed on 8 bits and a register
destination receives the result **zero-extended**. `MOV.B [DI], AX`
stores AL; `MOV.B AX, [SI]` loads a byte into AX (AH = 0).

There is no `mem, imm` form: load the value into a register first.

### 2.2 Control, stack, I/O and system (`0xC0-0xEF`)

| Opcode | Assembly | Size | Operation |
|---|---|---|---|
| `C0` | `NOP` | 2 | – |
| `C1` | `HLT` | 2 | stop until the next interrupt (with IF=0: power off) |
| `C2` | `Jcc addr` | 4 | if condition (byte 1 = cc): PC = addr |
| `C3` | `JMP reg` | 2 | PC = reg |
| `C4` | `CALL addr` | 4 | push PC; PC = addr |
| `C5` | `CALL reg` | 2 | push PC; PC = reg |
| `C6` | `RET` | 2 | PC = pop |
| `C7` | `IRET` | 2 | PC = pop; FLAGS = pop |
| `C8` | `INT n` | 2 | push FLAGS; push PC; IF = 0; PC = word [n*4] |
| `C9` | `PUSH reg` | 2 | SP −= 2; [SP] = reg |
| `CA` | `POP reg` | 2 | reg = [SP]; SP += 2 |
| `CB` | `PUSH imm` | 4 | |
| `CC` / `CD` | `PUSHF` / `POPF` | 2 | |
| `CE` / `CF` | `PUSHA` / `POPA` | 2 | AX CX DX BX SP BP SI DI (x86 order) |
| `D0` | `IN reg, port` | 4 | reg = port[imm] |
| `D1` | `IN reg, reg2` | 2 | reg = port[reg2] |
| `D2` | `OUT port, reg` | 4 | port[imm] = reg |
| `D3` | `OUT reg, reg2` | 2 | port[reg] = reg2 |
| `D4`-`D7` | `NOT` `NEG` `INC` `DEC` reg | 2 | `INC`/`DEC` keep CF |
| `D8`-`DB` | `CLI` `STI` `CLC` `STC` | 2 | |
| `DC` | `LOOP addr` | 4 | CX −= 1; if CX ≠ 0: PC = addr |
| `DD` | `JCXZ addr` | 4 | if CX = 0: PC = addr |
| `DF` | `BIOS n` | 2 | trap to firmware service *n* (see ARCHITECTURE.md) |
| `E0`/`E1` | `MOVSB` / `MOVSW` | 2 | [DI] = [SI]; SI, DI += 1/2 |
| `E2`/`E3` | `STOSB` / `STOSW` | 2 | [DI] = AL/AX; DI += 1/2 |
| `E4`/`E5` | `LODSB` / `LODSW` | 2 | AX = [SI]; SI += 1/2 |
| `E6`/`E7` | `REP MOVSB` / `REP MOVSW` | 2 | repeat CX times (CX ends at 0) |
| `E8`/`E9` | `REP STOSB` / `REP STOSW` | 2 | |
| others | | | invalid opcode → `INT 6` with PC on the faulting instruction |

**Condition codes** (byte 1 of `C2`):

| cc | Mnemonics | Condition |
|---|---|---|
| 0 | `JMP` | always |
| 1 / 2 | `JZ JE` / `JNZ JNE` | ZF / !ZF |
| 3 / 4 | `JC JB JNAE` / `JNC JAE JNB` | CF / !CF |
| 5 / 6 | `JS` / `JNS` | SF / !SF |
| 7 / 8 | `JO` / `JNO` | OF / !OF |
| 9 / 10 | `JA` / `JBE` | unsigned > / ≤ |
| 11 / 12 | `JL` / `JGE` | signed < / ≥ (SF≠OF / SF=OF) |
| 13 / 14 | `JG` / `JLE` | signed > / ≤ |

## 3. Interrupts and exceptions

* **Entry:** push FLAGS, push return PC, clear IF, PC = 16-bit handler
  address stored in IVT entry *n* at `n*4` (the second word of each
  4-byte entry is reserved).
* **Exit:** `IRET`.
* **Vectors:** 0 = divide error (pushed PC = next instruction), 6 =
  invalid opcode (pushed PC = faulting instruction), 8 = timer (70 Hz),
  9 = keyboard, 0x10/0x16/0x20/0x21/0x33 = firmware services.
* Hardware IRQs are accepted between instructions when IF = 1 and wake a
  halted CPU.

## 4. Timing

The emulator uses a simple cost model for pacing (default 8 MHz):
1 cycle per instruction word, +1 per immediate, +1 per memory access,
+8 for `MUL`, +16 for `DIV`, +n for `REP` string operations, +8 for a
firmware trap.

The RTL core is a multi-cycle state machine with a one-cycle unaligned
word memory interface: fetch 1 cycle, immediate 1 cycle, then 1-3
execute/memory cycles (`PUSHA` 9). The self-test averages ≈ 3.7
clocks per instruction.

## 5. Assembly quick reference

```asm
        MOV  AX, 0x1234         ; reg, imm
        MOV  BX, AX             ; reg, reg
        MOV  CX, [table+4]      ; reg, [abs]
        MOV  DX, [SI+2]         ; reg, [reg+disp]
        MOV  [DI], AX           ; [reg], reg
        MOV.B [DI+1], BX        ; store BL
        ADD  [counter], AX      ; read-modify-write memory
        MUL  AX, CX             ; DX:AX = AX * CX
        LEA  DI, [BP-8]
        SHL  AX, 4
        CMP  AX, 'A'
        JB   .below
        LOOP .again
        REP  STOSW              ; fill CX words at DI with AX
        INT  0x21
```

See [ASSEMBLER.md](ASSEMBLER.md) for directives and expressions.
