// Simplified AdLib / Yamaha YM3812 (OPL2) FM synthesizer.
//
// Port 0x388 (write) selects a register, port 0x389 (write) writes it,
// port 0x388 (read) returns the status byte. This model implements what
// games actually use: 9 two-operator channels, FM and additive
// connection, operator feedback, frequency multipliers, total level,
// a linear ADSR envelope, the four OPL2 waveforms and the timer status
// bits needed by the classic AdLib detection routine. It is not
// cycle-exact (no rhythm mode, no vibrato/tremolo LFO).
#pragma once
#include <cstdint>
#include <vector>

namespace p16 {

class Opl2 {
 public:
  explicit Opl2(int sample_rate = 44100);
  void write_index(uint8_t idx) { index_ = idx; }
  void write_data(uint8_t v);
  uint8_t status() const { return status_; }
  void reset();
  // Mix `n` mono 16-bit samples.
  void generate(int16_t* out, int n);
  bool active() const;  // any channel producing sound
  uint8_t reg(uint8_t r) const { return regs_[r]; }

 private:
  struct Op {
    double phase = 0, env = 0;
    int stage = 0;  // 0 off, 1 attack, 2 decay, 3 sustain, 4 release
    double last[2] = {0, 0};
  };
  int rate_;
  uint8_t index_ = 0, status_ = 0;
  uint8_t regs_[256] = {};
  Op ops_[18];
  bool key_[9] = {};

  static int slot_offset(int ch, int op);  // register offset for channel op
  double op_out(int slot, double phase_mod, double freq);
  void key_on(int ch);
  void key_off(int ch);
  void advance_env(Op& o, int slot_off);
  double wave(int slot_off, double phase) const;
};

}  // namespace p16
