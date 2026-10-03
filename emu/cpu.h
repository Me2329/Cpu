// PERRY-16 CPU core - instruction-level emulator.
//
// 8 x 16-bit general registers (AX BX CX DX SP BP SI DI), PC and FLAGS,
// flat 64 KB address space, separate 64 K I/O port space.
// Encoding reference: docs/ISA.md (shared with tools/pasm.py and
// rtl/perry16_cpu.sv).
#pragma once
#include <cstdint>
#include <string>

namespace p16 {

enum Reg : int { AX = 0, BX, CX, DX, SP, BP, SI, DI };

enum Flag : uint16_t {
  F_CF = 1u << 0,   // carry
  F_ZF = 1u << 6,   // zero
  F_SF = 1u << 7,   // sign
  F_IF = 1u << 9,   // interrupt enable
  F_OF = 1u << 11,  // overflow
};

// Exception / fixed interrupt vectors
enum Vector : uint8_t {
  VEC_DIVIDE = 0x00,
  VEC_INVALID_OPCODE = 0x06,
  VEC_TIMER = 0x08,
  VEC_KEYBOARD = 0x09,
};

// The CPU talks to the rest of the machine only through this interface.
class Bus {
 public:
  virtual ~Bus() = default;
  virtual uint8_t read8(uint16_t addr) = 0;
  virtual void write8(uint16_t addr, uint8_t v) = 0;
  virtual uint16_t io_in(uint16_t port) = 0;
  virtual void io_out(uint16_t port, uint16_t v) = 0;
  // BIOS n: trap into a native (high-level emulated) firmware service.
  virtual void bios_trap(uint8_t vector) = 0;
};

struct CpuState {
  uint16_t r[8];
  uint16_t pc;
  uint16_t flags;
};

class CPU {
 public:
  explicit CPU(Bus& bus) : bus_(bus) { reset(0); }

  uint16_t r[8] = {};
  uint16_t pc = 0;
  uint16_t flags = 0;
  bool halted = false;
  uint64_t cycles = 0;
  uint64_t instructions = 0;

  void reset(uint16_t start_pc);
  // Execute one instruction (or deliver one pending interrupt).
  // Returns the number of cycles consumed.
  int step();
  // Request a maskable hardware interrupt (delivered when IF=1).
  void raise_irq(uint8_t vector) { pending_irq_ |= irq_bit(vector); }
  // Enter an interrupt through the IVT (push FLAGS, push PC, IF=0).
  void interrupt(uint8_t vector);

  CpuState save() const;
  void load(const CpuState& s);

  uint16_t read16(uint16_t a) { return bus_.read8(a) | (bus_.read8(uint16_t(a + 1)) << 8); }
  void write16(uint16_t a, uint16_t v) {
    bus_.write8(a, v & 0xFF);
    bus_.write8(uint16_t(a + 1), v >> 8);
  }
  void push(uint16_t v) {
    r[SP] -= 2;
    write16(r[SP], v);
  }
  uint16_t pop() {
    uint16_t v = read16(r[SP]);
    r[SP] += 2;
    return v;
  }

  bool flag(Flag f) const { return flags & f; }
  void set_flag(Flag f, bool on) { flags = on ? (flags | f) : (flags & ~f); }

  // Disassemble the instruction at addr; returns its length in bytes.
  int disassemble(uint16_t addr, std::string& out);

  static const char* reg_name(int r);

 private:
  Bus& bus_;
  uint32_t pending_irq_ = 0;  // bit n -> vector 8+n

  static uint32_t irq_bit(uint8_t v) { return (v >= 8 && v < 16) ? (1u << (v - 8)) : 0; }

  uint8_t fetch8() { return bus_.read8(pc++); }
  uint16_t fetch16() {
    uint16_t v = read16(pc);
    pc += 2;
    return v;
  }
  bool condition(int cc) const;
  int exec_alu(int op, int mode, uint8_t m);
  int exec_misc(uint8_t op, uint8_t m);
  void set_zs(uint32_t v, bool byte);
  uint16_t alu(int op, uint16_t d, uint16_t s, bool byte, bool& write, int dst_reg);
};

}  // namespace p16
