#include "opl2.h"

#include <cmath>
#include <cstring>

namespace p16 {

namespace {
const double kPi = 3.14159265358979323846;
const double kMult[16] = {0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15};
const int kChanSlot[9] = {0, 1, 2, 8, 9, 10, 16, 17, 18};  // operator 1 register offset

// Approximate OPL envelope times in seconds for rate 0..15.
double attack_time(int rate) { return rate == 0 ? 1e9 : 2.8 * std::pow(2.0, -(rate - 1) * 0.75); }
double decay_time(int rate) { return rate == 0 ? 1e9 : 39.0 * std::pow(2.0, -(rate - 1) * 0.75); }
}  // namespace

Opl2::Opl2(int sample_rate) : rate_(sample_rate) { reset(); }

void Opl2::reset() {
  memset(regs_, 0, sizeof regs_);
  for (auto& o : ops_) o = Op();
  for (auto& k : key_) k = false;
  status_ = 0;
}

int Opl2::slot_offset(int ch, int op) { return kChanSlot[ch] + (op ? 3 : 0); }

void Opl2::write_data(uint8_t v) {
  uint8_t r = index_;
  regs_[r] = v;
  if (r == 0x04) {  // timer control
    if (v & 0x80) {
      status_ = 0;  // IRQ reset
    } else {
      // Timers "expire" immediately in this model; that is what the
      // detection routine (start T1, wait, read status) needs.
      uint8_t s = 0;
      if ((v & 0x01) && !(v & 0x40)) s |= 0x40;
      if ((v & 0x02) && !(v & 0x20)) s |= 0x20;
      if (s) s |= 0x80;
      status_ = s;
    }
  } else if (r >= 0xB0 && r <= 0xB8) {
    int ch = r - 0xB0;
    bool on = v & 0x20;
    if (on && !key_[ch]) key_on(ch);
    if (!on && key_[ch]) key_off(ch);
    key_[ch] = on;
  }
}

void Opl2::key_on(int ch) {
  for (int op = 0; op < 2; op++) {
    Op& o = ops_[ch * 2 + op];
    o.phase = 0;
    o.stage = 1;
    o.last[0] = o.last[1] = 0;
  }
}

void Opl2::key_off(int ch) {
  for (int op = 0; op < 2; op++) {
    Op& o = ops_[ch * 2 + op];
    if (o.stage) o.stage = 4;
  }
}

bool Opl2::active() const {
  for (const auto& o : ops_)
    if (o.stage) return true;
  return false;
}

void Opl2::advance_env(Op& o, int so) {
  const double dt = 1.0 / rate_;
  int ar = regs_[0x60 + so] >> 4, dr = regs_[0x60 + so] & 15;
  int sl = regs_[0x80 + so] >> 4, rr = regs_[0x80 + so] & 15;
  bool sustain = regs_[0x20 + so] & 0x20;  // EG type: hold at sustain level
  double sus_level = sl == 15 ? 0.0 : std::pow(10.0, -(sl * 3.0) / 20.0);
  switch (o.stage) {
    case 1:
      o.env += dt / attack_time(ar);
      if (o.env >= 1) { o.env = 1; o.stage = 2; }
      break;
    case 2:
      o.env -= dt / decay_time(dr);
      if (o.env <= sus_level) { o.env = sus_level; o.stage = sustain ? 3 : 4; }
      break;
    case 3: break;
    case 4:
      o.env -= dt / decay_time(rr);
      if (o.env <= 0) { o.env = 0; o.stage = 0; }
      break;
    default: o.env = 0; break;
  }
}

double Opl2::wave(int so, double ph) const {
  int ws = (regs_[0x01] & 0x20) ? (regs_[0xE0 + so] & 3) : 0;
  double s = std::sin(2 * kPi * ph);
  double frac = ph - std::floor(ph);
  switch (ws) {
    case 1: return frac < 0.5 ? s : 0;              // half sine
    case 2: return std::fabs(s);                     // abs sine
    case 3: return (std::fmod(frac, 0.5) < 0.25) ? std::fabs(s) : 0;  // quarter (pulse) sine
    default: return s;
  }
}

void Opl2::generate(int16_t* out, int n) {
  for (int i = 0; i < n; i++) {
    double mix = 0;
    for (int ch = 0; ch < 9; ch++) {
      Op& o1 = ops_[ch * 2];
      Op& o2 = ops_[ch * 2 + 1];
      if (!o1.stage && !o2.stage) continue;
      int fnum = regs_[0xA0 + ch] | ((regs_[0xB0 + ch] & 3) << 8);
      int block = (regs_[0xB0 + ch] >> 2) & 7;
      double freq = fnum * 49716.0 / double(1 << (20 - block));
      int s1 = slot_offset(ch, 0), s2 = slot_offset(ch, 1);
      int fb = (regs_[0xC0 + ch] >> 1) & 7;
      bool additive = regs_[0xC0 + ch] & 1;

      auto level = [&](int so, const Op& o) {
        int tl = regs_[0x40 + so] & 63;
        return o.env * std::pow(10.0, -(tl * 0.75) / 20.0);
      };
      double fbmod = fb ? (o1.last[0] + o1.last[1]) * 0.5 * (kPi / std::pow(2.0, 9 - fb)) / (2 * kPi) : 0;
      double v1 = wave(s1, o1.phase + fbmod) * level(s1, o1);
      o1.last[1] = o1.last[0];
      o1.last[0] = v1;
      double v2;
      if (additive) {
        v2 = wave(s2, o2.phase) * level(s2, o2) + v1;
      } else {
        v2 = wave(s2, o2.phase + v1 * 0.5) * level(s2, o2);
      }
      mix += v2;
      o1.phase += freq * kMult[regs_[0x20 + s1] & 15] / rate_;
      o2.phase += freq * kMult[regs_[0x20 + s2] & 15] / rate_;
      if (o1.phase > 1e6) o1.phase -= std::floor(o1.phase);
      if (o2.phase > 1e6) o2.phase -= std::floor(o2.phase);
      advance_env(o1, s1);
      advance_env(o2, s2);
    }
    double v = mix * 0.25 * 32767.0;
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    out[i] = int16_t(v);
  }
}

}  // namespace p16
