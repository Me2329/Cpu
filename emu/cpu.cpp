// PERRY-16 CPU core implementation.
#include "cpu.h"

#include <cstdio>

namespace p16 {

namespace {
enum AluOp {
  OP_MOV = 0, OP_ADD, OP_SUB, OP_CMP, OP_AND, OP_OR, OP_XOR, OP_TEST,
  OP_ADC, OP_SBB, OP_MUL, OP_IMUL, OP_DIV, OP_IDIV, OP_SHL, OP_SHR,
  OP_SAR, OP_ROL, OP_ROR, OP_LEA, OP_XCHG, OP_MOVSX, ALU_COUNT
};
// Addressing modes of the ALU group (low 3 bits of the opcode).
enum Mode { M_RR = 0, M_RI, M_RM, M_RMD, M_RA, M_MR, M_MDR, M_AR };

const char* kAluNames[ALU_COUNT] = {
  "MOV", "ADD", "SUB", "CMP", "AND", "OR", "XOR", "TEST", "ADC", "SBB", "MUL",
  "IMUL", "DIV", "IDIV", "SHL", "SHR", "SAR", "ROL", "ROR", "LEA", "XCHG", "MOVSX"};
const char* kCondNames[16] = {"JMP", "JZ", "JNZ", "JC", "JNC", "JS", "JNS", "JO",
                              "JNO", "JA", "JBE", "JL", "JGE", "JG", "JLE", "J??"};
const char* kRegNames[8] = {"AX", "BX", "CX", "DX", "SP", "BP", "SI", "DI"};

bool mode_has_imm(int m) { return m == M_RI || m == M_RMD || m == M_RA || m == M_MDR || m == M_AR; }
}  // namespace

const char* CPU::reg_name(int r) { return kRegNames[r & 7]; }

void CPU::reset(uint16_t start_pc) {
  for (auto& x : r) x = 0;
  pc = start_pc;
  flags = 0;
  halted = false;
  pending_irq_ = 0;
}

CpuState CPU::save() const {
  CpuState s;
  for (int i = 0; i < 8; i++) s.r[i] = r[i];
  s.pc = pc;
  s.flags = flags;
  return s;
}

void CPU::load(const CpuState& s) {
  for (int i = 0; i < 8; i++) r[i] = s.r[i];
  pc = s.pc;
  flags = s.flags;
  halted = false;
}

void CPU::interrupt(uint8_t vector) {
  push(flags);
  push(pc);
  flags &= ~F_IF;
  pc = read16(uint16_t(vector * 4));
  halted = false;
}

bool CPU::condition(int cc) const {
  bool cf = flags & F_CF, zf = flags & F_ZF, sf = flags & F_SF, of = flags & F_OF;
  switch (cc) {
    case 0: return true;
    case 1: return zf;
    case 2: return !zf;
    case 3: return cf;
    case 4: return !cf;
    case 5: return sf;
    case 6: return !sf;
    case 7: return of;
    case 8: return !of;
    case 9: return !cf && !zf;      // A   (unsigned >)
    case 10: return cf || zf;       // BE  (unsigned <=)
    case 11: return sf != of;       // L   (signed <)
    case 12: return sf == of;       // GE
    case 13: return !zf && sf == of;  // G
    case 14: return zf || sf != of;   // LE
    default: return false;
  }
}

void CPU::set_zs(uint32_t v, bool byte) {
  uint32_t mask = byte ? 0xFF : 0xFFFF, sign = byte ? 0x80 : 0x8000;
  set_flag(F_ZF, (v & mask) == 0);
  set_flag(F_SF, (v & sign) != 0);
}

// Core ALU. d = destination value, s = source value. Sets `write` to false
// when the result must not be stored (CMP/TEST).
uint16_t CPU::alu(int op, uint16_t d, uint16_t s, bool byte, bool& write, int dst_reg) {
  const uint32_t mask = byte ? 0xFF : 0xFFFF, sign = byte ? 0x80 : 0x8000;
  const int width = byte ? 8 : 16;
  uint32_t res = 0;
  write = true;
  d &= mask;
  s &= mask;
  switch (op) {
    case OP_MOV: return s;
    case OP_ADD:
    case OP_ADC: {
      uint32_t c = (op == OP_ADC && (flags & F_CF)) ? 1 : 0;
      res = uint32_t(d) + s + c;
      set_flag(F_CF, res > mask);
      set_flag(F_OF, (~(d ^ s) & (d ^ res) & sign) != 0);
      set_zs(res, byte);
      return res & mask;
    }
    case OP_SUB:
    case OP_SBB:
    case OP_CMP: {
      uint32_t c = (op == OP_SBB && (flags & F_CF)) ? 1 : 0;
      res = (uint32_t(d) - s - c) & 0x1FFFF;
      set_flag(F_CF, uint32_t(d) < uint32_t(s) + c);
      set_flag(F_OF, ((d ^ s) & (d ^ res) & sign) != 0);
      set_zs(res, byte);
      if (op == OP_CMP) write = false;
      return res & mask;
    }
    case OP_AND:
    case OP_TEST: res = d & s; break;
    case OP_OR: res = d | s; break;
    case OP_XOR: res = d ^ s; break;
    case OP_MUL: {
      uint32_t p = uint32_t(d) * s;
      if (!byte && dst_reg >= 0 && dst_reg != DX) r[DX] = uint16_t(p >> 16);
      bool hi = (p >> width) != 0;
      set_flag(F_CF, hi);
      set_flag(F_OF, hi);
      set_zs(p, byte);
      return p & mask;
    }
    case OP_IMUL: {
      int32_t a = byte ? int8_t(d) : int16_t(d), b = byte ? int8_t(s) : int16_t(s);
      int32_t p = a * b;
      if (!byte && dst_reg >= 0 && dst_reg != DX) r[DX] = uint16_t(uint32_t(p) >> 16);
      int32_t lo = byte ? int8_t(p) : int16_t(p);
      set_flag(F_CF, lo != p);
      set_flag(F_OF, lo != p);
      set_zs(uint32_t(p), byte);
      return uint32_t(p) & mask;
    }
    case OP_DIV:
    case OP_IDIV: {
      if (s == 0) {
        write = false;
        interrupt(VEC_DIVIDE);
        return d;
      }
      uint32_t q, rem;
      if (op == OP_DIV) {
        q = d / s;
        rem = d % s;
      } else {
        int32_t a = byte ? int8_t(d) : int16_t(d), b = byte ? int8_t(s) : int16_t(s);
        q = uint32_t(a / b);
        rem = uint32_t(a % b);
      }
      if (!byte && dst_reg >= 0 && dst_reg != DX) r[DX] = uint16_t(rem);
      set_zs(q, byte);
      return q & mask;
    }
    case OP_SHL:
    case OP_SHR:
    case OP_SAR:
    case OP_ROL:
    case OP_ROR: {
      int n = s & 0x1F;
      res = d;
      if (n == 0) return d;
      for (int i = 0; i < n; i++) {
        bool out;
        switch (op) {
          case OP_SHL: out = res & sign; res = (res << 1) & mask; break;
          case OP_SHR: out = res & 1; res >>= 1; break;
          case OP_SAR: out = res & 1; res = (res >> 1) | (res & sign); break;
          case OP_ROL: out = res & sign; res = ((res << 1) | (out ? 1 : 0)) & mask; break;
          default: out = res & 1; res = (res >> 1) | (out ? sign : 0); break;
        }
        set_flag(F_CF, out);
      }
      if (op != OP_ROL && op != OP_ROR) set_zs(res, byte);
      set_flag(F_OF, ((res ^ d) & sign) != 0);
      return res & mask;
    }
    default: return d;
  }
  // logic ops land here
  set_flag(F_CF, false);
  set_flag(F_OF, false);
  set_zs(res, byte);
  if (op == OP_TEST) write = false;
  return res & mask;
}

int CPU::exec_alu(int op, int mode, uint8_t m) {
  const bool byte = m & 0x80;
  const int rd = (m >> 4) & 7, rs = m & 7;
  uint16_t imm = mode_has_imm(mode) ? fetch16() : 0;
  int cyc = mode_has_imm(mode) ? 2 : 1;

  if (op >= ALU_COUNT) {
    pc -= mode_has_imm(mode) ? 4 : 2;
    interrupt(VEC_INVALID_OPCODE);
    return 2;
  }

  uint16_t addr = 0, src = 0;
  bool src_mem = false, dst_mem = false;
  switch (mode) {
    case M_RR: src = r[rs]; break;
    case M_RI: src = imm; break;
    case M_RM: addr = r[rs]; src_mem = true; break;
    case M_RMD: addr = uint16_t(r[rs] + imm); src_mem = true; break;
    case M_RA: addr = imm; src_mem = true; break;
    case M_MR: addr = r[rd]; dst_mem = true; src = r[rs]; break;
    case M_MDR: addr = uint16_t(r[rd] + imm); dst_mem = true; src = r[rs]; break;
    case M_AR: addr = imm; dst_mem = true; src = r[rs]; break;
  }

  if (op == OP_LEA) {
    if (!src_mem) {
      pc -= mode_has_imm(mode) ? 4 : 2;
      interrupt(VEC_INVALID_OPCODE);
      return 2;
    }
    r[rd] = addr;
    return cyc;
  }
  if (op == OP_MOVSX) {
    if (dst_mem) {
      pc -= mode_has_imm(mode) ? 4 : 2;
      interrupt(VEC_INVALID_OPCODE);
      return 2;
    }
    uint8_t b = src_mem ? bus_.read8(addr) : uint8_t(src);
    r[rd] = uint16_t(int16_t(int8_t(b)));
    return cyc + (src_mem ? 1 : 0);
  }

  if (src_mem) {
    src = byte ? bus_.read8(addr) : read16(addr);
    cyc++;
  }
  if (byte) src &= 0xFF;

  if (op == OP_XCHG) {
    if (dst_mem || src_mem) {
      int reg = dst_mem ? rs : rd;
      uint16_t memv = byte ? bus_.read8(addr) : read16(addr);
      uint16_t regv = byte ? (r[reg] & 0xFF) : r[reg];
      if (byte) bus_.write8(addr, uint8_t(regv)); else write16(addr, regv);
      r[reg] = memv;
      return cyc + 2;
    }
    uint16_t t = r[rd];
    r[rd] = r[rs];
    r[rs] = t;
    return cyc;
  }

  uint16_t d = 0;
  if (op != OP_MOV) {
    if (dst_mem) {
      d = byte ? bus_.read8(addr) : read16(addr);
      cyc++;
    } else {
      d = r[rd];
    }
  }
  bool write = true;
  uint16_t pc_before = pc;
  uint16_t res = alu(op, d, src, byte, write, dst_mem ? -1 : rd);
  if (op == OP_MUL || op == OP_IMUL) cyc += 8;
  if (op == OP_DIV || op == OP_IDIV) cyc += 16;
  if (!write || pc != pc_before) return cyc;  // CMP/TEST, or divide fault
  if (dst_mem) {
    if (byte) bus_.write8(addr, uint8_t(res)); else write16(addr, res);
    cyc++;
  } else {
    r[rd] = res;  // byte ops zero-extend into the register
  }
  return cyc;
}

int CPU::exec_misc(uint8_t op, uint8_t m) {
  const int rd = (m >> 4) & 7, rs = m & 7;
  switch (op) {
    case 0xC0: return 1;                                   // NOP
    case 0xC1: halted = true; return 1;                    // HLT
    case 0xC2: {                                           // Jcc imm16
      uint16_t t = fetch16();
      if (condition(m & 15)) pc = t;
      return 2;
    }
    case 0xC3: pc = r[rd]; return 1;                       // JMP reg
    case 0xC4: {                                           // CALL imm16
      uint16_t t = fetch16();
      push(pc);
      pc = t;
      return 3;
    }
    case 0xC5: {                                           // CALL reg
      uint16_t t = r[rd];
      push(pc);
      pc = t;
      return 2;
    }
    case 0xC6: pc = pop(); return 2;                       // RET
    case 0xC7: pc = pop(); flags = pop(); return 3;        // IRET
    case 0xC8: interrupt(m); return 4;                     // INT n
    case 0xC9: push(r[rd]); return 2;                      // PUSH reg
    case 0xCA: r[rd] = pop(); return 2;                    // POP reg
    case 0xCB: push(fetch16()); return 3;                  // PUSH imm
    case 0xCC: push(flags); return 2;                      // PUSHF
    case 0xCD: flags = pop(); return 2;                    // POPF
    case 0xCE: {                                           // PUSHA
      uint16_t sp = r[SP];
      push(r[AX]); push(r[CX]); push(r[DX]); push(r[BX]);
      push(sp); push(r[BP]); push(r[SI]); push(r[DI]);
      return 9;
    }
    case 0xCF: {                                           // POPA
      r[DI] = pop(); r[SI] = pop(); r[BP] = pop(); pop();
      r[BX] = pop(); r[DX] = pop(); r[CX] = pop(); r[AX] = pop();
      return 9;
    }
    case 0xD0: r[rd] = bus_.io_in(fetch16()); return 3;    // IN reg, imm
    case 0xD1: r[rd] = bus_.io_in(r[rs]); return 2;        // IN reg, reg
    case 0xD2: bus_.io_out(fetch16(), r[rs]); return 3;    // OUT imm, reg
    case 0xD3: bus_.io_out(r[rd], r[rs]); return 2;        // OUT reg, reg
    case 0xD4: r[rd] = ~r[rd]; return 1;                   // NOT
    case 0xD5: {                                           // NEG
      bool w;
      r[rd] = alu(OP_SUB, 0, r[rd], false, w, -1);
      return 1;
    }
    case 0xD6:                                             // INC
    case 0xD7: {                                           // DEC (CF preserved)
      bool cf = flags & F_CF, w;
      r[rd] = alu(op == 0xD6 ? OP_ADD : OP_SUB, r[rd], 1, false, w, -1);
      set_flag(F_CF, cf);
      return 1;
    }
    case 0xD8: flags &= ~F_IF; return 1;                   // CLI
    case 0xD9: flags |= F_IF; return 1;                    // STI
    case 0xDA: flags &= ~F_CF; return 1;                   // CLC
    case 0xDB: flags |= F_CF; return 1;                    // STC
    case 0xDC: {                                           // LOOP
      uint16_t t = fetch16();
      if (--r[CX] != 0) pc = t;
      return 2;
    }
    case 0xDD: {                                           // JCXZ
      uint16_t t = fetch16();
      if (r[CX] == 0) pc = t;
      return 2;
    }
    case 0xDF: bus_.bios_trap(m); return 8;                // BIOS n (HLE trap)
    case 0xE0: bus_.write8(r[DI]++, bus_.read8(r[SI]++)); return 2;   // MOVSB
    case 0xE1: write16(r[DI], read16(r[SI])); r[DI] += 2; r[SI] += 2; return 2;
    case 0xE2: bus_.write8(r[DI]++, uint8_t(r[AX])); return 1;        // STOSB
    case 0xE3: write16(r[DI], r[AX]); r[DI] += 2; return 1;           // STOSW
    case 0xE4: r[AX] = bus_.read8(r[SI]++); return 1;                 // LODSB
    case 0xE5: r[AX] = read16(r[SI]); r[SI] += 2; return 1;           // LODSW
    case 0xE6:                                                        // REP MOVSB
    case 0xE7:                                                        // REP MOVSW
    case 0xE8:                                                        // REP STOSB
    case 0xE9: {                                                      // REP STOSW
      int n = r[CX];
      for (; r[CX]; r[CX]--) {
        switch (op) {
          case 0xE6: bus_.write8(r[DI]++, bus_.read8(r[SI]++)); break;
          case 0xE7: write16(r[DI], read16(r[SI])); r[DI] += 2; r[SI] += 2; break;
          case 0xE8: bus_.write8(r[DI]++, uint8_t(r[AX])); break;
          default: write16(r[DI], r[AX]); r[DI] += 2; break;
        }
      }
      return 2 + n;
    }
    default:
      pc -= 2;
      interrupt(VEC_INVALID_OPCODE);
      return 2;
  }
}

int CPU::step() {
  if (pending_irq_ && (flags & F_IF)) {
    for (int i = 0; i < 8; i++) {
      if (pending_irq_ & (1u << i)) {
        pending_irq_ &= ~(1u << i);
        interrupt(uint8_t(8 + i));
        cycles += 4;
        return 4;
      }
    }
  }
  if (halted) {
    cycles += 1;
    return 1;
  }
  uint8_t op = fetch8();
  uint8_t m = fetch8();
  int cyc = (op < 0xC0) ? exec_alu(op >> 3, op & 7, m) : exec_misc(op, m);
  cycles += cyc;
  instructions++;
  return cyc;
}

int CPU::disassemble(uint16_t addr, std::string& out) {
  char buf[96];
  uint8_t op = bus_.read8(addr), m = bus_.read8(uint16_t(addr + 1));
  uint16_t imm = bus_.read8(uint16_t(addr + 2)) | (bus_.read8(uint16_t(addr + 3)) << 8);
  const char* rd = kRegNames[(m >> 4) & 7];
  const char* rs = kRegNames[m & 7];
  if (op < 0xC0) {
    int o = op >> 3, mode = op & 7;
    if (o >= ALU_COUNT) { out = "???"; return 2; }
    char name[12];
    snprintf(name, sizeof name, "%s%s", kAluNames[o], (m & 0x80) ? ".B" : "");
    switch (mode) {
      case M_RR: snprintf(buf, sizeof buf, "%s %s, %s", name, rd, rs); break;
      case M_RI: snprintf(buf, sizeof buf, "%s %s, 0x%04X", name, rd, imm); break;
      case M_RM: snprintf(buf, sizeof buf, "%s %s, [%s]", name, rd, rs); break;
      case M_RMD: snprintf(buf, sizeof buf, "%s %s, [%s+0x%04X]", name, rd, rs, imm); break;
      case M_RA: snprintf(buf, sizeof buf, "%s %s, [0x%04X]", name, rd, imm); break;
      case M_MR: snprintf(buf, sizeof buf, "%s [%s], %s", name, rd, rs); break;
      case M_MDR: snprintf(buf, sizeof buf, "%s [%s+0x%04X], %s", name, rd, imm, rs); break;
      default: snprintf(buf, sizeof buf, "%s [0x%04X], %s", name, imm, rs); break;
    }
    out = buf;
    return mode_has_imm(mode) ? 4 : 2;
  }
  int len = 2;
  switch (op) {
    case 0xC0: out = "NOP"; break;
    case 0xC1: out = "HLT"; break;
    case 0xC2: snprintf(buf, sizeof buf, "%s 0x%04X", kCondNames[m & 15], imm); out = buf; len = 4; break;
    case 0xC3: out = std::string("JMP ") + rd; break;
    case 0xC4: snprintf(buf, sizeof buf, "CALL 0x%04X", imm); out = buf; len = 4; break;
    case 0xC5: out = std::string("CALL ") + rd; break;
    case 0xC6: out = "RET"; break;
    case 0xC7: out = "IRET"; break;
    case 0xC8: snprintf(buf, sizeof buf, "INT 0x%02X", m); out = buf; break;
    case 0xC9: out = std::string("PUSH ") + rd; break;
    case 0xCA: out = std::string("POP ") + rd; break;
    case 0xCB: snprintf(buf, sizeof buf, "PUSH 0x%04X", imm); out = buf; len = 4; break;
    case 0xCC: out = "PUSHF"; break;
    case 0xCD: out = "POPF"; break;
    case 0xCE: out = "PUSHA"; break;
    case 0xCF: out = "POPA"; break;
    case 0xD0: snprintf(buf, sizeof buf, "IN %s, 0x%04X", rd, imm); out = buf; len = 4; break;
    case 0xD1: snprintf(buf, sizeof buf, "IN %s, %s", rd, rs); out = buf; break;
    case 0xD2: snprintf(buf, sizeof buf, "OUT 0x%04X, %s", imm, rs); out = buf; len = 4; break;
    case 0xD3: snprintf(buf, sizeof buf, "OUT %s, %s", rd, rs); out = buf; break;
    case 0xD4: out = std::string("NOT ") + rd; break;
    case 0xD5: out = std::string("NEG ") + rd; break;
    case 0xD6: out = std::string("INC ") + rd; break;
    case 0xD7: out = std::string("DEC ") + rd; break;
    case 0xD8: out = "CLI"; break;
    case 0xD9: out = "STI"; break;
    case 0xDA: out = "CLC"; break;
    case 0xDB: out = "STC"; break;
    case 0xDC: snprintf(buf, sizeof buf, "LOOP 0x%04X", imm); out = buf; len = 4; break;
    case 0xDD: snprintf(buf, sizeof buf, "JCXZ 0x%04X", imm); out = buf; len = 4; break;
    case 0xDF: snprintf(buf, sizeof buf, "BIOS 0x%02X", m); out = buf; break;
    case 0xE0: out = "MOVSB"; break;
    case 0xE1: out = "MOVSW"; break;
    case 0xE2: out = "STOSB"; break;
    case 0xE3: out = "STOSW"; break;
    case 0xE4: out = "LODSB"; break;
    case 0xE5: out = "LODSW"; break;
    case 0xE6: out = "REP MOVSB"; break;
    case 0xE7: out = "REP MOVSW"; break;
    case 0xE8: out = "REP STOSB"; break;
    case 0xE9: out = "REP STOSW"; break;
    default: out = "???"; break;
  }
  return len;
}

}  // namespace p16
