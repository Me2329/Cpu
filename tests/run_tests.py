#!/usr/bin/env python3
"""run_tests.py - PERRY-16 test-suite.

    python3 tests/run_tests.py            # everything (run `make` first)
    python3 tests/run_tests.py --only rtl # one group: asm, cpu, rtl, fuzz, system

Groups
  asm     assembler unit tests (encodings, expressions, errors)
  cpu     tests/cpu/selftest.asm on the C++ emulator
  rtl     the same binary on the SystemVerilog core (Icarus Verilog),
          plus an instruction-by-instruction lockstep trace comparison
  fuzz    random instruction streams, emulator vs RTL lockstep
  system  headless scenario scripts (tests/scripts/*.txt) that boot
          PERRY-DOS from a fresh copy of build/disk.img
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
EMU = os.path.join(BUILD, 'perry16')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
sys.path.insert(0, os.path.join(ROOT, 'tests'))

import pasm        # noqa: E402
import fuzz_cpu    # noqa: E402

results = []


def report(name, ok, detail=''):
    results.append((name, ok))
    print('  %-46s %s%s' % (name, 'ok' if ok else 'FAIL', ('  ' + detail) if detail else ''))


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def assemble_text(src, fmt='bin'):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, 't.asm')
        with open(path, 'w') as f:
            f.write(src)
        a = pasm.Assembler([os.path.join(ROOT, 'include')])
        out = a.assemble(path)
        return bytes(out['code']) + bytes(out['data']), a


# ------------------------------------------------------------------ asm
def test_asm():
    print('assembler')
    cases = [
        ('MOV AX, BX', [0x00, 0x01]),
        ('MOV AX, 0x1234', [0x01, 0x00, 0x34, 0x12]),
        ('ADD CX, [SI]', [0x0A, 0x26]),
        ('SUB DX, [BX+4]', [0x13, 0x31, 0x04, 0x00]),
        ('CMP AX, [0x2000]', [0x1C, 0x00, 0x00, 0x20]),
        ('MOV [DI], AX', [0x05, 0x70]),
        ('MOV [BP-2], CX', [0x06, 0x52, 0xFE, 0xFF]),
        ('MOV.B [0xB800], AX', [0x07, 0x80, 0x00, 0xB8]),
        ('MOVB AX, [SI]', [0x02, 0x86]),
        ('LEA DI, [SI+0x23]', [0x9B, 0x76, 0x23, 0x00]),
        ('JMP 0x1000', [0xC2, 0x00, 0x00, 0x10]),
        ('JLE 0x1000', [0xC2, 0x0E, 0x00, 0x10]),
        ('CALL AX', [0xC5, 0x00]),
        ('INT 0x21', [0xC8, 0x21]),
        ('PUSH 0x4242', [0xCB, 0x00, 0x42, 0x42]),
        ('OUT 0x388, AX', [0xD2, 0x00, 0x88, 0x03]),
        ('IN AX, DX', [0xD1, 0x03]),
        ('REP MOVSB', [0xE6, 0x00]),
        ('BIOS 0x10', [0xDF, 0x10]),
        ("MOV AX, 'A' + (2 << 4) - 1", [0x01, 0x00, 0x60, 0x00]),
        ('MOV AX, 0FFh', [0x01, 0x00, 0xFF, 0x00]),
    ]
    for src, want in cases:
        try:
            got, _ = assemble_text('        ' + src + '\n')
            report('encode  ' + src, list(got) == want,
                   '' if list(got) == want else 'got %s' % ' '.join('%02X' % b for b in got))
        except pasm.AsmError as e:
            report('encode  ' + src, False, str(e))
    # labels, locals, sections, data
    src = '''        ORG 0x3000
SECTION .code
main:   JMP .x
.x:     MOV AX, msg
        RET
SECTION .data
msg:    DB "Hi", 0
        DW main, $
SECTION .bss
buf:    RESB 10
'''
    got, a = assemble_text(src)
    ok = got[:4] == bytes([0xC2, 0, 0x04, 0x30]) and got[4:8] == bytes([0x01, 0, 0x0A, 0x30]) \
        and got[10:13] == b'Hi\0' and got[13:15] == bytes([0, 0x30]) and got[15:17] == bytes([0x0D, 0x30]) \
        and a.sizes['bss'] == 10
    report('labels, local labels, sections, $', ok)
    for bad, why in [('MOV [AX], 5', 'memory destination'), ('FOO AX', 'unknown instruction'),
                     ('MOV AX, undefined_sym', 'undefined'), ('MOV [AX+BX], CX', 'addressing'),
                     ('INT 300', 'out of range')]:
        try:
            assemble_text('        ' + bad + '\n')
            report('reject  ' + bad, False, 'no error')
        except pasm.AsmError as e:
            report('reject  ' + bad, why in str(e), str(e) if why not in str(e) else '')


# ------------------------------------------------------------------ cpu
def build_selftest():
    binp = os.path.join(BUILD, 'selftest.bin')
    r = run([sys.executable, os.path.join(ROOT, 'tools', 'pasm.py'),
             os.path.join(ROOT, 'tests', 'cpu', 'selftest.asm'), '-o', binp])
    if r.returncode:
        print(r.stderr)
    return binp


def test_cpu():
    print('cpu (C++ emulator)')
    binp = build_selftest()
    r = run([EMU, '--raw', binp])
    report('selftest.asm on perry16', r.returncode == 0 and 'PASS' in r.stdout, r.stdout.strip())


# ------------------------------------------------------------------ rtl
def have_iverilog():
    return shutil.which('iverilog') and shutil.which('vvp')


def compile_rtl():
    tb = os.path.join(BUILD, 'tb_perry16')
    r = run(['iverilog', '-g2012', '-o', tb, os.path.join(ROOT, 'rtl', 'perry16_cpu.sv'),
             os.path.join(ROOT, 'rtl', 'tb_perry16.sv')])
    errors = [l for l in r.stderr.splitlines() if 'error' in l.lower()]
    return tb if r.returncode == 0 and not errors else None


def to_hex(binp, hexp):
    with open(binp, 'rb') as f:
        data = f.read()
    with open(hexp, 'w') as f:
        f.write('@1000\n' + '\n'.join('%02X' % b for b in data) + '\n')


def norm_trace(lines):
    out = []
    for l in lines:
        m = re.match(r'^([0-9A-Fa-f]{4})\s', l)
        if not m or int(m.group(1), 16) >= 0xF000:   # skip ROM stubs (timer IRQ in the emulator)
            continue
        regs = re.findall(r'(AX|BX|CX|DX|SP|BP|SI|DI|F)=([0-9A-Fa-f]{4})', l)
        out.append((m.group(1) + ' ' + ' '.join('%s=%s' % r for r in regs)).upper())
    return out


def lockstep(tb, binp, name):
    hexp = binp + '.hex'
    to_hex(binp, hexp)
    rtl_trace = binp + '.rtl.trace'
    r = run(['vvp', '-n', tb, '+image=' + hexp, '+trace=' + rtl_trace])
    m = re.search(r'EXIT (\d+)', r.stdout)
    rtl_exit = int(m.group(1)) if m else -1
    e = run([EMU, '--raw', binp, '--trace'])
    emu = norm_trace(e.stderr.splitlines())
    with open(rtl_trace) as f:
        rtl = norm_trace(f.readlines())
    for i, (a, b) in enumerate(zip(emu, rtl)):
        if a != b:
            return False, 'step %d differs:\n      emu %s\n      rtl %s' % (i, a, b), r.stdout
    if len(emu) != len(rtl):
        return False, 'trace lengths differ (%d vs %d)' % (len(emu), len(rtl)), r.stdout
    if rtl_exit != e.returncode:
        return False, 'exit codes differ (rtl %d, emu %d)' % (rtl_exit, e.returncode), r.stdout
    return True, '%d instructions identical' % len(emu), r.stdout


def test_rtl():
    print('rtl (SystemVerilog core, Icarus Verilog)')
    if not have_iverilog():
        report('iverilog available', False, 'install iverilog to run RTL tests')
        return
    tb = compile_rtl()
    report('compile perry16_cpu.sv + tb', tb is not None)
    if not tb:
        return
    binp = build_selftest()
    ok, detail, out = lockstep(tb, binp, 'selftest')
    report('selftest.asm on RTL', 'PASS' in out and 'EXIT 0' in out, out.strip().splitlines()[-1] if out else '')
    report('lockstep RTL vs emulator (selftest)', ok, detail)


def test_fuzz(seeds=8, count=600):
    print('fuzz (random programs, emulator vs RTL lockstep)')
    if not have_iverilog():
        report('iverilog available', False)
        return
    tb = compile_rtl()
    if not tb:
        report('compile RTL', False)
        return
    for seed in range(1, seeds + 1):
        asm = os.path.join(BUILD, 'fuzz%d.asm' % seed)
        binp = os.path.join(BUILD, 'fuzz%d.bin' % seed)
        with open(asm, 'w') as f:
            f.write(fuzz_cpu.gen(seed, count))
        r = run([sys.executable, os.path.join(ROOT, 'tools', 'pasm.py'), asm, '-o', binp])
        if r.returncode:
            report('fuzz seed %d assemble' % seed, False, r.stderr.strip())
            continue
        ok, detail, _ = lockstep(tb, binp, 'fuzz%d' % seed)
        report('fuzz seed %d (%d random insns)' % (seed, count), ok, detail)


# ------------------------------------------------------------------ system
def test_system():
    print('system (PERRY-DOS scenarios, headless)')
    disk = os.path.join(BUILD, 'disk.img')
    if not os.path.exists(disk):
        report('build/disk.img exists', False, 'run make first')
        return
    sizes = {}
    for name in ('COMMAND.PEX',):
        with open(os.path.join(BUILD, name), 'rb') as f:
            hdr = f.read(32)
        load, entry, code, data, bss, stack = [int.from_bytes(hdr[o:o + 2], 'little')
                                               for o in (8, 10, 12, 14, 16, 18)]
        sizes[name] = load + code + data + bss + stack
    report('COMMAND.PEX resident image ends below TPA', sizes['COMMAND.PEX'] <= 0x3000,
           'ends at 0x%04X' % sizes['COMMAND.PEX'])
    scripts = sorted(f for f in os.listdir(os.path.join(ROOT, 'tests', 'scripts')) if f.endswith('.txt'))
    for s in scripts:
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, 'disk.img')
            shutil.copy(disk, img)
            r = run([EMU, '--script', os.path.join(ROOT, 'tests', 'scripts', s), img], cwd=d, timeout=120)
            report('scenario ' + s, r.returncode == 0, (r.stderr.strip()[:2000]) if r.returncode else '')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', choices=['asm', 'cpu', 'rtl', 'fuzz', 'system'])
    args = ap.parse_args()
    groups = {'asm': test_asm, 'cpu': test_cpu, 'rtl': test_rtl, 'fuzz': test_fuzz, 'system': test_system}
    for name, fn in groups.items():
        if args.only in (None, name):
            fn()
    failed = [n for n, ok in results if not ok]
    print('\n%d tests, %d failed' % (len(results), len(failed)))
    for n in failed:
        print('  FAILED: ' + n)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
