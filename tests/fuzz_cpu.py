#!/usr/bin/env python3
"""fuzz_cpu.py - random instruction streams for differential testing.

Generates a bare-metal PERRY-16 program made of random (but well-defined)
instructions: ALU ops in every addressing mode, byte variants, shifts and
rotates with random counts, MUL/IMUL/DIV/IDIV, ADC/SBB chains, XCHG,
MOVSX, LEA, stack operations, PUSHF/POPF and forward conditional jumps.
tests/run_tests.py runs the program on the C++ emulator and on the RTL
core and requires identical per-instruction traces.

    python3 tests/fuzz_cpu.py SEED COUNT > prog.asm
"""
import random
import sys

DATA = ['AX', 'BX', 'CX', 'DX', 'DI']           # SI, BP, SP stay fixed (bases / stack)
ALU = ['MOV', 'ADD', 'SUB', 'CMP', 'AND', 'OR', 'XOR', 'TEST', 'ADC', 'SBB']
SHIFTS = ['SHL', 'SHR', 'SAR', 'ROL', 'ROR']
JCC = ['JZ', 'JNZ', 'JC', 'JNC', 'JS', 'JNS', 'JO', 'JNO', 'JA', 'JBE', 'JL', 'JGE', 'JG', 'JLE']


def gen(seed, count):
    rnd = random.Random(seed)
    out = ['        ORG 0x1000',
           'start:  MOV SP, 0x0F00',
           '        MOV SI, 0x8000',
           '        MOV BP, 0x8100']
    for r in DATA:
        out.append('        MOV %s, %d' % (r, rnd.randrange(65536)))
    for i in range(0, 256, 2):                   # random scratch memory
        out.append('        MOV AX, %d' % rnd.randrange(65536))
        out.append('        MOV [0x8000+%d], AX' % i)
    label = 0

    def imm():
        return rnd.choice([0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x80, 0xFF, rnd.randrange(65536)])

    def mem():
        k = rnd.randrange(3)
        if k == 0:
            return '[SI+%d]' % rnd.randrange(255)
        if k == 1:
            return '[BP-%d]' % rnd.randrange(1, 200)
        return '[0x%04X]' % (0x8000 + rnd.randrange(255))

    for _ in range(count):
        k = rnd.randrange(16)
        b = '.B' if rnd.random() < 0.3 else ''
        d, s = rnd.choice(DATA), rnd.choice(DATA)
        if k <= 4:
            op = rnd.choice(ALU) + b
            form = rnd.randrange(5)
            if form == 0:
                out.append('        %s %s, %s' % (op, d, s))
            elif form == 1:
                out.append('        %s %s, %d' % (op, d, imm()))
            elif form == 2:
                out.append('        %s %s, %s' % (op, d, mem()))
            elif form == 3:
                out.append('        %s %s, [SI]' % (op, d))
            else:
                out.append('        %s %s, %s' % (op, mem(), s))
        elif k == 5:
            op = rnd.choice(SHIFTS) + b
            if rnd.random() < 0.5:
                out.append('        %s %s, %d' % (op, d, rnd.randrange(32)))
            else:
                out.append('        %s %s, %s' % (op, d, s))
        elif k == 6:
            op = rnd.choice(['MUL', 'IMUL']) + b
            out.append('        %s %s, %s' % (op, d, rnd.choice([s, str(imm()), mem()])))
        elif k == 7:
            op = rnd.choice(['DIV', 'IDIV']) + b
            dv = rnd.choice([x for x in DATA if x != d])
            val = rnd.choice([1, 2, 3, 7, 10, 0xFFFF, 0x8000, rnd.randrange(1, 65536)])
            if b and val & 0xFF == 0:
                val |= 1
            out.append('        MOV %s, %d' % (dv, val))
            out.append('        %s %s, %s' % (op, d, dv))
        elif k == 8:
            out.append('        %s %s' % (rnd.choice(['NOT', 'NEG', 'INC', 'DEC']), d))
        elif k == 9:
            if rnd.random() < 0.5:
                out.append('        XCHG%s %s, %s' % (b, d, rnd.choice([s, mem()])))
            else:
                out.append('        XCHG%s %s, %s' % (b, mem(), s))
        elif k == 10:
            out.append('        MOVSX %s, %s' % (d, rnd.choice([s, mem(), str(imm() & 0xFF)])))
        elif k == 11:
            out.append('        LEA %s, %s' % (d, rnd.choice(['[SI+%d]' % rnd.randrange(300),
                                                              '[BP-7]', '[0x1234]'])))
        elif k == 12:
            out.append('        PUSH %s' % rnd.choice([s, str(imm())]))
            out.append('        POP %s' % d)
        elif k == 13:
            out.append('        PUSH %d' % (imm() & ~0x0200))  # keep IF clear-safe
            out.append('        POPF')
            out.append('        PUSHF')
            out.append('        POP %s' % d)
        elif k == 14:
            out.append('        %s .f%d' % (rnd.choice(JCC), label))
            out.append('        XOR %s, 0x5A5A' % d)
            out.append('.f%d:' % label)
            label += 1
        else:
            out.append('        PUSHA')
            out.append('        MOV %s, %d' % (d, imm()))
            out.append('        POPA')
    out += ['        MOV AX, 0', '        OUT 0xF4, AX', '        HLT']
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 500
    sys.stdout.write(gen(seed, count))
