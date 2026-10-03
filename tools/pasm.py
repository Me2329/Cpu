#!/usr/bin/env python3
"""pasm - the PERRY-16 assembler.

Reads PERRY-16 assembly (.asm), resolves labels / constants / includes and
emits either a flat binary (.bin) or a PERRY executable (.PEX).

    python3 tools/pasm.py prog.asm -o PROG.PEX            # PEX (default)
    python3 tools/pasm.py boot.asm -o boot.bin -f bin     # raw binary
    python3 tools/pasm.py prog.asm -o P.PEX -l P.LST      # with listing

Syntax overview (see docs/ASSEMBLER.md for the full reference):

    ORG 0x3000              ; load address (PEX: must be inside 0x1000-0x9FFF)
    ENTRY start             ; entry point (default: first byte of code)
    STACK 1024              ; stack size placed after BSS
    %include "perry.inc"

    SECTION .code
    start:  MOV AX, 0x0900       ; AH=09h print ASCIIZ string
            MOV DX, msg
            INT 0x21
    .loop:  JMP .loop            ; local label -> start.loop
    SECTION .data
    msg:    DB "Hello", 13, 10, 0
    SECTION .bss
    buf:    RESB 128

Instruction encoding is described in docs/ISA.md and mirrored by
emu/cpu.cpp and rtl/perry16_cpu.sv.
"""
import argparse
import os
import re
import struct
import sys

# ---------------------------------------------------------------- ISA tables
REGS = {'AX': 0, 'BX': 1, 'CX': 2, 'DX': 3, 'SP': 4, 'BP': 5, 'SI': 6, 'DI': 7}

# two-operand "ALU group": opcode = (op << 3) | mode
ALU_OPS = {
    'MOV': 0, 'ADD': 1, 'SUB': 2, 'CMP': 3, 'AND': 4, 'OR': 5, 'XOR': 6,
    'TEST': 7, 'ADC': 8, 'SBB': 9, 'MUL': 10, 'IMUL': 11, 'DIV': 12,
    'IDIV': 13, 'SHL': 14, 'SHR': 15, 'SAR': 16, 'ROL': 17, 'ROR': 18,
    'LEA': 19, 'XCHG': 20, 'MOVSX': 21,
}
ALIASES = {'MOVB': 'MOV.B', 'CMPB': 'CMP.B', 'SAL': 'SHL', 'J': 'JMP'}

# addressing modes of the ALU group
M_RR, M_RI, M_RM, M_RMD, M_RA, M_MR, M_MDR, M_AR = range(8)
MODE_HAS_IMM = {M_RI, M_RMD, M_RA, M_MDR, M_AR}

COND = {
    'JMP': 0, 'JZ': 1, 'JE': 1, 'JNZ': 2, 'JNE': 2, 'JC': 3, 'JB': 3,
    'JNAE': 3, 'JNC': 4, 'JNB': 4, 'JAE': 4, 'JS': 5, 'JNS': 6, 'JO': 7,
    'JNO': 8, 'JA': 9, 'JNBE': 9, 'JBE': 10, 'JNA': 10, 'JL': 11,
    'JNGE': 11, 'JGE': 12, 'JNL': 12, 'JG': 13, 'JNLE': 13, 'JLE': 14,
    'JNG': 14,
}

OP_NOP, OP_HLT, OP_JCC, OP_JMPR, OP_CALL, OP_CALLR, OP_RET, OP_IRET = range(0xC0, 0xC8)
OP_INT, OP_PUSH, OP_POP, OP_PUSHI, OP_PUSHF, OP_POPF, OP_PUSHA, OP_POPA = range(0xC8, 0xD0)
OP_INI, OP_INR, OP_OUTI, OP_OUTR = 0xD0, 0xD1, 0xD2, 0xD3
OP_LOOP, OP_JCXZ, OP_BIOS = 0xDC, 0xDD, 0xDF

SIMPLE = {   # 2-byte instructions without operands
    'NOP': OP_NOP, 'HLT': OP_HLT, 'RET': OP_RET, 'IRET': OP_IRET,
    'PUSHF': OP_PUSHF, 'POPF': OP_POPF, 'PUSHA': OP_PUSHA, 'POPA': OP_POPA,
    'CLI': 0xD8, 'STI': 0xD9, 'CLC': 0xDA, 'STC': 0xDB,
    'MOVSB': 0xE0, 'MOVSW': 0xE1, 'STOSB': 0xE2, 'STOSW': 0xE3,
    'LODSB': 0xE4, 'LODSW': 0xE5,
}
REP_OPS = {'MOVSB': 0xE6, 'MOVSW': 0xE7, 'STOSB': 0xE8, 'STOSW': 0xE9}
UNARY = {'NOT': 0xD4, 'NEG': 0xD5, 'INC': 0xD6, 'DEC': 0xD7}

SECTIONS = ('code', 'data', 'bss')
SECTION_NAMES = {'.code': 'code', '.text': 'code', 'code': 'code', 'text': 'code',
                 '.data': 'data', 'data': 'data', '.rodata': 'data',
                 '.bss': 'bss', 'bss': 'bss'}

PEX_MAGIC = b'PEX\0'
PEX_HEADER = struct.Struct('<4sBBHHHHHHHH10s')   # 32 bytes


class AsmError(Exception):
    pass


# ---------------------------------------------------------------- expressions
TOKEN_RE = re.compile(r"""
    \s*(?:
      (?P<num>0[xX][0-9A-Fa-f_]+|[0-9][0-9A-Fa-f_]*[hH]\b|0[bB][01_]+|[0-9][0-9_]*)
     |(?P<chr>'(?:\\.|[^'\\])')
     |(?P<id>[A-Za-z_.@][A-Za-z0-9_.@]*)
     |(?P<op><<|>>|\$\$|[-+*/%&|^~()$])
    )""", re.X)

ESCAPES = {'n': 10, 'r': 13, 't': 9, '0': 0, '\\': 92, '"': 34, "'": 39, 'e': 27}


def parse_number(text):
    t = text.replace('_', '')
    if t[:2] in ('0x', '0X'):
        return int(t[2:], 16)
    if t[:2] in ('0b', '0B'):
        return int(t[2:], 2)
    if t[-1] in 'hH':
        return int(t[:-1], 16)
    return int(t, 10)


def char_value(lit):
    body = lit[1:-1]
    if body.startswith('\\'):
        if body[1] not in ESCAPES:
            raise AsmError('unknown escape %r' % body)
        return ESCAPES[body[1]]
    return ord(body)


def tokenize(expr):
    pos, out = 0, []
    expr = expr.rstrip()
    while pos < len(expr):
        m = TOKEN_RE.match(expr, pos)
        if not m or m.end() == pos:
            raise AsmError('bad expression near %r' % expr[pos:])
        pos = m.end()
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
    return out


class ExprParser:
    """Recursive-descent expression evaluator (C-like precedence)."""

    def __init__(self, tokens, resolve):
        self.t, self.i, self.resolve = tokens, 0, resolve

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self):
        tok = self.peek()
        self.i += 1
        return tok

    def parse(self):
        v = self.p_or()
        if self.i != len(self.t):
            raise AsmError('unexpected %r in expression' % (self.peek()[1],))
        return v

    def binary(self, sub, ops):
        v = sub()
        while self.peek()[0] == 'op' and self.peek()[1] in ops:
            op = self.take()[1]
            r = sub()
            v = ops[op](v, r)
        return v

    def p_or(self):
        return self.binary(self.p_xor, {'|': lambda a, b: a | b})

    def p_xor(self):
        return self.binary(self.p_and, {'^': lambda a, b: a ^ b})

    def p_and(self):
        return self.binary(self.p_shift, {'&': lambda a, b: a & b})

    def p_shift(self):
        return self.binary(self.p_add, {'<<': lambda a, b: a << b, '>>': lambda a, b: a >> b})

    def p_add(self):
        return self.binary(self.p_mul, {'+': lambda a, b: a + b, '-': lambda a, b: a - b})

    def p_mul(self):
        def div(a, b):
            if b == 0:
                raise AsmError('division by zero in expression')
            return int(a / b)

        def mod(a, b):
            if b == 0:
                raise AsmError('division by zero in expression')
            return a % b
        return self.binary(self.p_unary, {'*': lambda a, b: a * b, '/': div, '%': mod})

    def p_unary(self):
        kind, val = self.peek()
        if kind == 'op' and val in '-~+':
            self.take()
            v = self.p_unary()
            return -v if val == '-' else (~v if val == '~' else v)
        return self.p_atom()

    def p_atom(self):
        kind, val = self.take()
        if kind == 'num':
            return parse_number(val)
        if kind == 'chr':
            return char_value(val)
        if kind == 'id':
            return self.resolve(val)
        if kind == 'op' and val in ('$', '$$'):
            return self.resolve(val)
        if kind == 'op' and val == '(':
            v = self.p_or()
            if self.take()[1] != ')':
                raise AsmError("missing ')'")
            return v
        raise AsmError('unexpected %r in expression' % (val,))


# ---------------------------------------------------------------- lexing
def strip_comment(line):
    quote, i = None, 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == '\\':
                i += 1            # skip the escaped character
            elif ch == quote:
                quote = None
        elif ch in '"\'':
            quote = ch
        elif ch == ';':
            return line[:i]
        i += 1
    return line


def split_operands(text):
    """Split on top-level commas (outside quotes, brackets and parens)."""
    parts, depth, quote, cur = [], 0, None, ''
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            cur += ch
            if ch == '\\' and i + 1 < len(text):
                cur += text[i + 1]
                i += 1
            elif ch == quote:
                quote = None
        elif ch in '"\'':
            quote = ch
            cur += ch
        elif ch in '([':
            depth += 1
            cur += ch
        elif ch in ')]':
            depth -= 1
            cur += ch
        elif ch == ',' and depth == 0:
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
        i += 1
    if cur.strip():
        parts.append(cur.strip())
    return parts


def parse_string(lit):
    """Decode a "..." or '...' literal (with C escapes) to bytes."""
    body, out, i = lit[1:-1], bytearray(), 0
    while i < len(body):
        ch = body[i]
        if ch == '\\':
            i += 1
            if i >= len(body) or body[i] not in ESCAPES:
                raise AsmError('bad escape in %s' % lit)
            out.append(ESCAPES[body[i]])
        else:
            out.append(ord(ch) & 0xFF)
        i += 1
    return bytes(out)


LABEL_RE = re.compile(r'^\s*([A-Za-z_.@][A-Za-z0-9_.@]*)\s*:(?!\S*\])')
EQU_RE = re.compile(r'^\s*([A-Za-z_@][A-Za-z0-9_.@]*)\s+(?:EQU|equ|Equ)\s+(.+)$')
ASSIGN_RE = re.compile(r'^\s*([A-Za-z_@][A-Za-z0-9_.@]*)\s*=\s*(.+)$')
DEFINE_RE = re.compile(r'^\s*%define\s+([A-Za-z_@][A-Za-z0-9_.@]*)\s+(.+)$', re.I)


# ---------------------------------------------------------------- operands
class Operand:
    __slots__ = ('kind', 'reg', 'expr')

    def __init__(self, kind, reg=None, expr=None):
        self.kind, self.reg, self.expr = kind, reg, expr   # kind: reg|imm|mem

    def __repr__(self):
        return 'Operand(%s,%s,%s)' % (self.kind, self.reg, self.expr)


def parse_operand(text):
    t = text.strip()
    if not t:
        raise AsmError('empty operand')
    up = t.upper()
    for prefix in ('WORD ', 'BYTE '):
        if up.startswith(prefix):
            raise AsmError("size prefixes are not used: write MOV.B / ADD.B etc. "
                           "for byte access")
    if up in REGS:
        return Operand('reg', reg=REGS[up])
    if t.startswith('['):
        if not t.endswith(']'):
            raise AsmError('missing ] in %r' % t)
        inner = t[1:-1].strip()
        # find a register term: REG, REG+expr, REG-expr, expr+REG
        if len(re.findall(r'\b(?:%s)\b' % '|'.join(REGS), inner, re.I)) > 1:
            raise AsmError('unsupported addressing mode [%s] (only [reg], [reg+disp], '
                           '[disp])' % inner)
        m = re.match(r'^([A-Za-z]{2})\s*(?:([+-])\s*(.+))?$', inner)
        if m and m.group(1).upper() in REGS:
            reg = REGS[m.group(1).upper()]
            if m.group(2):
                expr = m.group(3) if m.group(2) == '+' else '-(' + m.group(3) + ')'
                return Operand('mem', reg=reg, expr=expr)
            return Operand('mem', reg=reg)
        m = re.match(r'^(.+?)\s*\+\s*([A-Za-z]{2})$', inner)
        if m and m.group(2).upper() in REGS:
            return Operand('mem', reg=REGS[m.group(2).upper()], expr=m.group(1))
        for name in REGS:   # registers anywhere else are not encodable
            if re.search(r'\b%s\b' % name, inner, re.I):
                raise AsmError('unsupported addressing mode [%s] (only [reg], '
                               '[reg+disp], [disp])' % inner)
        return Operand('mem', expr=inner)
    return Operand('imm', expr=t)


# ---------------------------------------------------------------- assembler
class Stmt:
    __slots__ = ('kind', 'section', 'offset', 'size', 'mnem', 'ops', 'byte',
                 'src', 'scope', 'data', 'line_text')

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))


class Assembler:
    def __init__(self, include_dirs=()):
        self.include_dirs = list(include_dirs)
        self.stmts = []
        self.symbols = {}          # name -> ('label', section, offset) | ('const', expr, src, scope)
        self.sizes = {s: 0 for s in SECTIONS}
        self.section = 'code'
        self.scope = ''
        self.org = None
        self.entry_expr = None
        self.stack_size = 1024
        self.pex_flags = 0
        self.base = {}
        self._evaluating = set()
        self.cur_src = None

    # ---------------- errors
    def err(self, msg, src=None):
        src = src or self.cur_src
        if src:
            return AsmError('%s:%d: %s' % (src[0], src[1], msg))
        return AsmError(msg)

    # ---------------- symbols
    def qualify(self, name, scope):
        if name.startswith('.') and not name.startswith('..'):
            if not scope:
                raise AsmError('local label %s outside of any global label' % name)
            return scope + name
        return name

    def define(self, name, value):
        if name in self.symbols:
            raise AsmError('symbol %s redefined' % name)
        self.symbols[name] = value

    def lookup(self, name, scope, here, final):
        if name == '$':
            if here is None:
                raise AsmError('$ not allowed here')
            return here
        if name == '$$':
            return self.org or 0
        q = self.qualify(name, scope)
        sym = self.symbols.get(q)
        if sym is None:
            sym = self.symbols.get(name.upper()) if name.upper() != name else None
            if sym is None:
                raise AsmError('undefined symbol %s' % q)
            q = name.upper()
        if sym[0] == 'label':
            if not final:
                raise AsmError('label %s used where a constant is required' % q)
            return self.base[sym[1]] + sym[2]
        # constant
        if q in self._evaluating:
            raise AsmError('recursive definition of %s' % q)
        self._evaluating.add(q)
        try:
            return self.eval(sym[1], sym[3], None, final)
        finally:
            self._evaluating.discard(q)

    def eval(self, expr, scope, here, final=True):
        toks = tokenize(expr)
        for kind, val in toks:
            if kind == 'id' and val.upper() in REGS:
                raise AsmError('register %s not allowed in expression' % val)
        return ExprParser(toks, lambda n: self.lookup(n, scope, here, final)).parse()

    # ---------------- pass 1
    def find_include(self, name, cur_file):
        cands = [os.path.join(os.path.dirname(cur_file), name)]
        cands += [os.path.join(d, name) for d in self.include_dirs]
        for c in cands:
            if os.path.isfile(c):
                return c
        raise AsmError('include file not found: %s' % name)

    def add(self, kind, size, **kw):
        st = Stmt(kind=kind, section=self.section, offset=self.sizes[self.section],
                  size=size, src=self.cur_src, scope=self.scope, **kw)
        if self.section == 'bss' and kind not in ('reserve', 'align'):
            raise AsmError('only RESB/RESW/DS/ALIGN are allowed in .bss')
        self.stmts.append(st)
        self.sizes[self.section] += size
        return st

    def pass1_file(self, path, depth=0):
        if depth > 16:
            raise AsmError('include nesting too deep')
        with open(path, 'r', encoding='latin-1') as f:
            lines = f.read().split('\n')
        for n, raw in enumerate(lines, 1):
            self.cur_src = (path, n)
            try:
                self.pass1_line(raw, path, depth)
            except AsmError as e:
                if str(e).startswith(path + ':'):
                    raise
                raise self.err(str(e))

    def pass1_line(self, raw, path, depth):
        line = strip_comment(raw).rstrip()
        if not line.strip():
            return
        m = DEFINE_RE.match(line)
        if m:
            self.define(m.group(1), ('const', m.group(2).strip(), self.cur_src, self.scope))
            return
        m = EQU_RE.match(line) or ASSIGN_RE.match(line)
        if m and m.group(1).upper() not in REGS:
            self.define(m.group(1), ('const', m.group(2).strip(), self.cur_src, self.scope))
            return
        while True:
            m = LABEL_RE.match(line)
            if not m:
                break
            name = m.group(1)
            if not name.startswith('.'):
                self.scope = name
            self.define(self.qualify(name, self.scope),
                        ('label', self.section, self.sizes[self.section]))
            line = line[m.end():]
        line = line.strip()
        if not line:
            return
        parts = line.split(None, 1)
        mnem = parts[0].upper()
        rest = parts[1].strip() if len(parts) > 1 else ''
        mnem = ALIASES.get(mnem, mnem)
        self.statement(mnem, rest, line, path, depth)

    def const_eval(self, expr):
        return self.eval(expr, self.scope, None, final=False)

    def statement(self, mnem, rest, line, path, depth):
        if mnem in ('%INCLUDE', 'INCLUDE', '.INCLUDE'):
            name = rest.strip().strip('"').strip("'").strip('<>')
            self.pass1_file(self.find_include(name, path), depth + 1)
            return
        if mnem in ('SECTION', 'SEGMENT', '.SECTION'):
            key = rest.strip().lower()
            if key not in SECTION_NAMES:
                raise AsmError('unknown section %s' % rest)
            self.section = SECTION_NAMES[key]
            return
        if mnem in ('.CODE', '.TEXT', '.DATA', '.BSS', '.RODATA'):
            self.section = SECTION_NAMES[mnem.lower()]
            return
        if mnem == 'ORG':
            if self.org is not None or any(self.sizes.values()):
                raise AsmError('ORG must appear once, before any code')
            self.org = self.const_eval(rest)
            return
        if mnem == 'ENTRY':
            self.entry_expr = (rest, self.scope, self.cur_src)
            return
        if mnem == 'STACK':
            self.stack_size = self.const_eval(rest)
            return
        if mnem == 'PEXFLAGS':
            self.pex_flags = self.const_eval(rest)
            return
        if mnem == 'TIMES':
            cnt_text, sub = self.split_times(rest)
            count = self.const_eval(cnt_text)
            for _ in range(count):
                p = sub.split(None, 1)
                self.statement(ALIASES.get(p[0].upper(), p[0].upper()),
                               p[1] if len(p) > 1 else '', sub, path, depth)
            return
        if mnem in ('DB', 'DW', '.BYTE', '.WORD'):
            width = 1 if mnem in ('DB', '.BYTE') else 2
            items = split_operands(rest)
            size = 0
            for it in items:
                if it[:1] in '"\'' and it[-1:] == it[:1] and (len(it) > 3 or it[:1] == '"'):
                    s = parse_string(it)
                    size += len(s) * width
                else:
                    size += width
            self.add('data', size, mnem=mnem, ops=items, data=width)
            return
        if mnem in ('DS', 'RESB', 'RESW', '.SPACE'):
            n = self.const_eval(rest)
            if mnem == 'RESW':
                n *= 2
            if n < 0:
                raise AsmError('negative size')
            self.add('reserve', n)
            return
        if mnem == 'ALIGN':
            a = self.const_eval(rest)
            cur = self.sizes[self.section]
            pad = (-cur) % a
            self.add('align', pad)
            return
        if mnem == 'INCBIN':
            name = rest.strip().strip('"').strip("'")
            fpath = self.find_include(name, path)
            with open(fpath, 'rb') as f:
                blob = f.read()
            self.add('blob', len(blob), data=blob)
            return
        # instructions
        if self.section == 'bss':
            raise AsmError('instructions are not allowed in .bss')
        st = self.add('insn', 0, mnem=mnem, ops=rest, line_text=line)
        size = self.insn_size(mnem, rest)
        st.size = size
        self.sizes[self.section] += size

    @staticmethod
    def split_times(rest):
        # TIMES <count> <statement>; count may contain spaces inside parens
        depth = 0
        for i, ch in enumerate(rest):
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            elif ch.isspace() and depth == 0:
                head, tail = rest[:i], rest[i:].strip()
                if tail and tail.split(None, 1)[0].upper() in (
                        'DB', 'DW', 'NOP', 'RESB', 'RESW', 'DS') or tail.split(None, 1)[0].upper() in SIMPLE:
                    return head, tail
        raise AsmError('TIMES needs <count> <statement>')

    # ---------------- instruction encoding (sizes are value-independent)
    def insn_size(self, mnem, rest):
        return len(self.encode(mnem, rest, None, sizing=True))

    def encode(self, mnem, rest, st, sizing=False):
        def val(expr, lo=-0x8000, hi=0xFFFF):
            if sizing:
                return 0
            here = self.base[st.section] + st.offset
            v = self.eval(expr, st.scope, here, final=True)
            if not lo <= v <= hi:
                raise AsmError('value %d out of range (%d..%d)' % (v, lo, hi))
            return v & 0xFFFF

        def w16(v):
            return [v & 0xFF, (v >> 8) & 0xFF]

        ops = [parse_operand(o) for o in split_operands(rest)] if rest else []
        byte = False
        base = mnem
        if mnem.endswith('.B'):
            base, byte = mnem[:-2], True
        if base.endswith('.W'):
            base = base[:-2]

        def need(n):
            if len(ops) != n:
                raise AsmError('%s expects %d operand(s), got %d' % (mnem, n, len(ops)))

        if byte and base not in ALU_OPS:
            raise AsmError('.B suffix is only valid on two-operand ALU instructions')

        if base in ALU_OPS:
            need(2)
            op = ALU_OPS[base]
            d, s = ops
            bflag = 0x80 if byte else 0
            if base == 'LEA':
                if d.kind != 'reg' or s.kind != 'mem':
                    raise AsmError('LEA needs reg, [mem]')
            if d.kind == 'reg':
                if s.kind == 'reg':
                    return [op << 3 | M_RR, bflag | d.reg << 4 | s.reg]
                if s.kind == 'imm':
                    if base == 'XCHG':
                        raise AsmError('XCHG with an immediate')
                    return [op << 3 | M_RI, bflag | d.reg << 4] + w16(val(s.expr))
                if s.reg is not None and s.expr is None:
                    return [op << 3 | M_RM, bflag | d.reg << 4 | s.reg]
                if s.reg is not None:
                    return [op << 3 | M_RMD, bflag | d.reg << 4 | s.reg] + w16(val(s.expr))
                return [op << 3 | M_RA, bflag | d.reg << 4] + w16(val(s.expr))
            if d.kind == 'mem':
                if s.kind != 'reg':
                    raise AsmError('memory destination needs a register source '
                                   '(load the value into a register first)')
                if base in ('LEA', 'MOVSX'):
                    raise AsmError('%s needs a register destination' % base)
                if d.reg is not None and d.expr is None:
                    return [op << 3 | M_MR, bflag | d.reg << 4 | s.reg]
                if d.reg is not None:
                    return [op << 3 | M_MDR, bflag | d.reg << 4 | s.reg] + w16(val(d.expr))
                return [op << 3 | M_AR, bflag | s.reg] + w16(val(d.expr))
            raise AsmError('invalid destination operand for %s' % mnem)

        if base in COND:
            need(1)
            t = ops[0]
            if base == 'JMP' and t.kind == 'reg':
                return [OP_JMPR, t.reg << 4]
            if t.kind != 'imm':
                raise AsmError('%s needs a label/address' % base)
            return [OP_JCC, COND[base]] + w16(val(t.expr, 0))
        if base == 'CALL':
            need(1)
            t = ops[0]
            if t.kind == 'reg':
                return [OP_CALLR, t.reg << 4]
            if t.kind != 'imm':
                raise AsmError('CALL needs a label or register')
            return [OP_CALL, 0] + w16(val(t.expr, 0))
        if base in ('LOOP', 'JCXZ'):
            need(1)
            if ops[0].kind != 'imm':
                raise AsmError('%s needs a label' % base)
            return [OP_LOOP if base == 'LOOP' else OP_JCXZ, 0] + w16(val(ops[0].expr, 0))
        if base in ('INT', 'BIOS'):
            need(1)
            if ops[0].kind != 'imm':
                raise AsmError('%s needs a vector number' % base)
            return [OP_INT if base == 'INT' else OP_BIOS, val(ops[0].expr, 0, 255)]
        if base == 'PUSH':
            need(1)
            if ops[0].kind == 'reg':
                return [OP_PUSH, ops[0].reg << 4]
            if ops[0].kind == 'imm':
                return [OP_PUSHI, 0] + w16(val(ops[0].expr))
            raise AsmError('PUSH [mem] is not supported')
        if base == 'POP':
            need(1)
            if ops[0].kind != 'reg':
                raise AsmError('POP needs a register')
            return [OP_POP, ops[0].reg << 4]
        if base in UNARY:
            need(1)
            if ops[0].kind != 'reg':
                raise AsmError('%s needs a register' % base)
            return [UNARY[base], ops[0].reg << 4]
        if base == 'IN':
            need(2)
            d, p = ops
            if d.kind != 'reg':
                raise AsmError('IN needs a destination register')
            if p.kind == 'reg':
                return [OP_INR, d.reg << 4 | p.reg]
            if p.kind == 'imm':
                return [OP_INI, d.reg << 4] + w16(val(p.expr, 0))
            raise AsmError('IN port must be an immediate or register')
        if base == 'OUT':
            need(2)
            p, s = ops
            if s.kind != 'reg':
                raise AsmError('OUT needs a source register')
            if p.kind == 'reg':
                return [OP_OUTR, p.reg << 4 | s.reg]
            if p.kind == 'imm':
                return [OP_OUTI, s.reg] + w16(val(p.expr, 0))
            raise AsmError('OUT port must be an immediate or register')
        if base == 'REP':
            target = rest.strip().upper()
            if target not in REP_OPS:
                raise AsmError('REP only works with MOVSB/MOVSW/STOSB/STOSW')
            return [REP_OPS[target], 0]
        if base in SIMPLE:
            need(0)
            return [SIMPLE[base], 0]
        raise AsmError('unknown instruction %s' % mnem)

    # ---------------- pass 2
    def assemble(self, path):
        self.pass1_file(path)
        self.cur_src = None
        if self.org is None:
            self.org = 0
        self.base['code'] = self.org
        self.base['data'] = self.org + self.sizes['code']
        self.base['bss'] = self.base['data'] + self.sizes['data']
        end = self.base['bss'] + self.sizes['bss']
        if end > 0x10000:
            raise AsmError('program does not fit in 64 KB (ends at 0x%X)' % end)
        out = {'code': bytearray(self.sizes['code']), 'data': bytearray(self.sizes['data'])}
        self.listing = []
        for st in self.stmts:
            self.cur_src = st.src
            try:
                blob = self.emit(st)
            except AsmError as e:
                raise self.err(str(e), st.src)
            if st.section != 'bss':
                if len(blob) != st.size:
                    raise self.err('internal: size mismatch (%d vs %d)' % (len(blob), st.size), st.src)
                out[st.section][st.offset:st.offset + len(blob)] = blob
            self.listing.append((self.base[st.section] + st.offset, blob, st))
        if self.entry_expr:
            text, scope, src = self.entry_expr
            try:
                self.entry = self.eval(text, scope, None) & 0xFFFF
            except AsmError as e:
                raise self.err(str(e), src)
        else:
            self.entry = self.org
        return out

    def emit(self, st):
        if st.kind == 'insn':
            return bytes(self.encode(st.mnem, st.ops, st))
        if st.kind in ('reserve', 'align'):
            return bytes(st.size)
        if st.kind == 'blob':
            return st.data
        if st.kind == 'data':
            width, out = st.data, bytearray()
            here = self.base[st.section] + st.offset
            for it in st.ops:
                if it[:1] in '"\'' and it[-1:] == it[:1] and (len(it) > 3 or it[:1] == '"'):
                    for b in parse_string(it):
                        out += bytes([b]) if width == 1 else struct.pack('<H', b)
                    continue
                v = self.eval(it, st.scope, here)
                if width == 1:
                    if not -128 <= v <= 255:
                        raise AsmError('byte value %d out of range' % v)
                    out.append(v & 0xFF)
                else:
                    if not -0x8000 <= v <= 0xFFFF:
                        raise AsmError('word value %d out of range' % v)
                    out += struct.pack('<H', v & 0xFFFF)
            return bytes(out)
        raise AsmError('internal: unknown statement kind %s' % st.kind)

    # ---------------- output
    def pex_image(self, out):
        code, data = bytes(out['code']), bytes(out['data'])
        checksum = sum(code + data) & 0xFFFF
        hdr = PEX_HEADER.pack(PEX_MAGIC, 1, 0, self.pex_flags, self.org, self.entry,
                              len(code), len(data), self.sizes['bss'], self.stack_size,
                              checksum, b'\0' * 10)
        return hdr + code + data

    def write_listing(self, path):
        with open(path, 'w') as f:
            for addr, blob, st in self.listing:
                text = st.line_text if st.kind == 'insn' else (
                    ('%s %s' % (st.mnem, ', '.join(st.ops))) if st.kind == 'data' else st.kind)
                hexb = ' '.join('%02X' % b for b in blob[:8])
                if len(blob) > 8:
                    hexb += ' ..'
                f.write('%04X  %-26s %s:%d  %s\n' % (addr, hexb, os.path.basename(st.src[0]),
                                                    st.src[1], text))

    def write_symbols(self, path):
        with open(path, 'w') as f:
            for name, sym in sorted(self.symbols.items(), key=lambda kv: kv[0]):
                if sym[0] == 'label':
                    f.write('%04X %s\n' % (self.base[sym[1]] + sym[2], name))


def main(argv=None):
    ap = argparse.ArgumentParser(description='PERRY-16 assembler')
    ap.add_argument('source')
    ap.add_argument('-o', '--output')
    ap.add_argument('-f', '--format', choices=('pex', 'bin'), default=None,
                    help='output format (default: from extension, else pex)')
    ap.add_argument('-I', '--include', action='append', default=[],
                    help='add include directory')
    ap.add_argument('-l', '--listing', help='write a listing file')
    ap.add_argument('-s', '--symbols', help='write a symbol map file')
    args = ap.parse_args(argv)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    inc = args.include + [os.path.join(root, 'include')]
    out_path = args.output or os.path.splitext(args.source)[0] + '.PEX'
    fmt = args.format or ('bin' if out_path.lower().endswith('.bin') else 'pex')

    asm = Assembler(inc)
    try:
        out = asm.assemble(args.source)
        if fmt == 'pex':
            if not 0x1000 <= asm.org < 0xA000:
                raise AsmError('PEX load address 0x%04X is outside system RAM '
                               '(0x1000-0x9FFF)' % asm.org)
            end = asm.base['bss'] + asm.sizes['bss'] + asm.stack_size
            if end > 0xA000:
                raise AsmError('PEX image + stack ends at 0x%04X, beyond system RAM '
                               '(0xA000)' % end)
            image = asm.pex_image(out)
        else:
            image = bytes(out['code']) + bytes(out['data'])
    except AsmError as e:
        print('pasm: error: %s' % e, file=sys.stderr)
        return 1
    with open(out_path, 'wb') as f:
        f.write(image)
    if args.listing:
        asm.write_listing(args.listing)
    if args.symbols:
        asm.write_symbols(args.symbols)
    print('pasm: %s -> %s  code=%d data=%d bss=%d org=0x%04X entry=0x%04X' % (
        os.path.basename(args.source), out_path, asm.sizes['code'], asm.sizes['data'],
        asm.sizes['bss'], asm.org, asm.entry))
    return 0


if __name__ == '__main__':
    sys.exit(main())
