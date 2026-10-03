// PERRY-16 machine: memory/IO dispatch, video, input devices, run loop
// and the .PEX process manager.
#include "machine.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>

#include "font8x8.h"
#include "pex.h"

namespace p16 {

// 16-colour CGA/EGA palette used by text mode and the first 16 VGA entries.
static const uint32_t kCga[16] = {
  0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
  0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF};

uint16_t key::from_ascii(char c) {
  static const char* rows[] = {"1234567890-=", "qwertyuiop[]", "asdfghjkl;'`", "zxcvbnm,./"};
  static const char* shifted[] = {"!@#$%^&*()_+", "QWERTYUIOP{}", "ASDFGHJKL:\"~", "ZXCVBNM<>?"};
  static const uint8_t base[] = {0x02, 0x10, 0x1E, 0x2C};
  uint8_t ch = uint8_t(c);
  if (c == ' ') return 0x3920;
  if (c == '\r' || c == '\n') return ENTER;
  if (c == '\t') return TAB;
  if (c == 8 || c == 127) return BACKSPACE;
  if (c == 27) return ESC;
  if (c == '\\' || c == '|') return uint16_t(0x2B00 | ch);
  for (int r = 0; r < 4; r++) {
    const char* p = strchr(rows[r], c);
    if (p && c) return uint16_t(((base[r] + (p - rows[r])) << 8) | ch);
    p = strchr(shifted[r], c);
    if (p && c) return uint16_t(((base[r] + (p - shifted[r])) << 8) | ch);
  }
  return ch;
}

Machine::Machine() { power_on(); }

Machine::~Machine() { fs.flush(); }

void Machine::power_on() {
  memset(mem_, 0, sizeof mem_);
  memset(gfx_, 0, sizeof gfx_);
  install_rom();
  reset_palette();
  opl.reset();
  keys_.clear();
  procs_.clear();
  for (auto& h : handles_) h = Handle();
  powered_off_ = false;
  waiting_input_ = false;
  line_input_active_ = false;
  dta_ = mm::DTA_DEFAULT;
  mem_[mm::BDA_ATTR] = 0x07;
  set_video_mode(0x03);
  cpu.reset(0);
}

void Machine::install_rom() {
  // IVT: every vector points at its ROM stub "BIOS n ; IRET".
  for (int n = 0; n < 256; n++) {
    uint16_t stub = uint16_t(mm::ROM + n * 4);
    mem_[n * 4] = stub & 0xFF;
    mem_[n * 4 + 1] = stub >> 8;
    mem_[n * 4 + 2] = mem_[n * 4 + 3] = 0;
    mem_[stub] = 0xDF;      // BIOS n
    mem_[stub + 1] = uint8_t(n);
    mem_[stub + 2] = 0xC7;  // IRET
    mem_[stub + 3] = 0x00;
  }
  const char* id = "PERRY-16 BIOS 1.0 / PERRY-DOS 1.0";
  memcpy(&mem_[mm::ROM_ID], id, strlen(id) + 1);
  memcpy(&mem_[mm::FONT], kFont8x8, sizeof kFont8x8);
}

void Machine::reset_palette() {
  // 0-15 CGA colours, 16-31 grey ramp, 32-247 6x6x6 colour cube, rest white
  for (int i = 0; i < 256; i++) {
    uint32_t rgb;
    if (i < 16) {
      rgb = kCga[i];
    } else if (i < 32) {
      int g = (i - 16) * 255 / 15;
      rgb = (g << 16) | (g << 8) | g;
    } else if (i < 248) {
      int c = i - 32, r = c / 36, g = (c / 6) % 6, b = c % 6;
      rgb = ((r * 51) << 16) | ((g * 51) << 8) | (b * 51);
    } else {
      rgb = 0xFFFFFF;
    }
    pal_[i * 3] = ((rgb >> 16) & 0xFF) >> 2;
    pal_[i * 3 + 1] = ((rgb >> 8) & 0xFF) >> 2;
    pal_[i * 3 + 2] = (rgb & 0xFF) >> 2;
  }
}

void Machine::set_video_mode(uint8_t mode) {
  mem_[mm::BDA_VMODE] = mode;
  mem_[mm::BDA_CUR_COL] = mem_[mm::BDA_CUR_ROW] = 0;
  mem_[mm::BDA_CUR_SHOW] = 1;
  vga_bank_ = 0;
  if (mode == 0x13) {
    memset(gfx_, 0, sizeof gfx_);
    reset_palette();
    mouse_xmax_ = 319;
  } else {
    mem_[mm::BDA_VMODE] = 0x03;
    for (int i = 0; i < 80 * 25; i++) {
      mem_[mm::TEXT_VRAM + i * 2] = ' ';
      mem_[mm::TEXT_VRAM + i * 2 + 1] = 0x07;
    }
    mouse_xmax_ = 639;
  }
  mouse_xmin_ = mouse_ymin_ = 0;
  mouse_ymax_ = 199;
}

// ------------------------------------------------------------------ bus
uint8_t Machine::read8(uint16_t a) {
  if (a >= mm::VGA_WIN && a < mm::VGA_WIN_END) {
    uint32_t off = uint32_t(vga_bank_) * 4096 + (a - mm::VGA_WIN);
    return off < sizeof gfx_ ? gfx_[off] : 0;
  }
  return mem_[a];
}

void Machine::write8(uint16_t a, uint8_t v) {
  if (a >= mm::VGA_WIN && a < mm::VGA_WIN_END) {
    uint32_t off = uint32_t(vga_bank_) * 4096 + (a - mm::VGA_WIN);
    if (off < sizeof gfx_) gfx_[off] = v;
    return;
  }
  if (a >= mm::ROM) return;  // ROM is read-only
  mem_[a] = v;
}

uint16_t Machine::io_in(uint16_t p) {
  switch (p) {
    case port::PIT: return uint16_t(cpu.cycles);
    case port::KBD_DATA: return last_scancode_;
    case port::KBD_STATUS: return keys_.empty() ? 0 : 1;
    case port::ADLIB_INDEX: return opl.status();
    case port::ADLIB_DATA: return 0xFF;
    case port::DAC_DATA: {
      uint8_t v = pal_[dac_read_];
      dac_read_ = (dac_read_ + 1) % 768;
      return v;
    }
    case port::VGA_BANK: return vga_bank_;
    case port::VGA_STATUS: {
      uint64_t per_frame = clock_hz / kFps;
      uint64_t in_frame = cpu.cycles - frame_start_cycles_;
      bool retrace = in_frame >= per_frame * 9 / 10;
      return retrace ? 0x09 : 0x00;
    }
    default: return 0xFFFF;
  }
}

void Machine::io_out(uint16_t p, uint16_t v) {
  switch (p) {
    case port::DEBUG_OUT:
      if (debug_sink) debug_sink(char(v));
      else fputc(v & 0xFF, stderr);
      break;
    case port::POWER: power_off(v & 0xFF, ""); break;
    case port::ADLIB_INDEX: opl.write_index(uint8_t(v)); break;
    case port::ADLIB_DATA: opl.write_data(uint8_t(v)); break;
    case port::DAC_READ_INDEX: dac_read_ = (v & 0xFF) * 3; break;
    case port::DAC_WRITE_INDEX: dac_write_ = (v & 0xFF) * 3; break;
    case port::DAC_DATA:
      pal_[dac_write_] = v & 0x3F;
      dac_write_ = (dac_write_ + 1) % 768;
      break;
    case port::VGA_BANK: vga_bank_ = uint8_t(v & 0x0F); break;
    default: break;
  }
}

void Machine::power_off(int code, const std::string& why) {
  powered_off_ = true;
  exit_code_ = code;
  if (!why.empty()) last_error_ = why;
  fs.flush();
}

// ------------------------------------------------------------------ run loop
void Machine::run_cycles(uint64_t budget) {
  uint64_t target = cpu.cycles + budget;
  while (cpu.cycles < target && !powered_off_) {
    if (waiting_input_) break;  // idle until the frontend delivers input
    if (cpu.halted && !(cpu.flags & F_IF)) {
      power_off(0, "CPU halted with interrupts disabled");
      break;
    }
    if (trace && !cpu.halted) {
      std::string dis;
      cpu.disassemble(cpu.pc, dis);
      fprintf(stderr, "%04X  %-26s AX=%04X BX=%04X CX=%04X DX=%04X SP=%04X BP=%04X SI=%04X DI=%04X F=%04X\n",
              cpu.pc, dis.c_str(), cpu.r[AX], cpu.r[BX], cpu.r[CX], cpu.r[DX], cpu.r[SP], cpu.r[BP],
              cpu.r[SI], cpu.r[DI], cpu.flags);
    }
    if (cpu.halted) {
      // sleep until the next timer interrupt
      uint64_t next = frame_start_cycles_ + clock_hz / kFps;
      cpu.cycles = next > cpu.cycles ? std::min(next, target) : cpu.cycles + 1;
      if (cpu.cycles >= target) break;
      continue;
    }
    cpu.step();
  }
}

void Machine::run_frame() {
  frame_start_cycles_ = cpu.cycles;
  run_cycles(clock_hz / kFps);
  frames_++;
  uint32_t t = mem_[0x400] | (mem_[0x401] << 8) | (mem_[0x402] << 16) | (uint32_t(mem_[0x403]) << 24);
  t++;
  mem_[0x400] = t & 0xFF; mem_[0x401] = (t >> 8) & 0xFF;
  mem_[0x402] = (t >> 16) & 0xFF; mem_[0x403] = t >> 24;
  cpu.raise_irq(VEC_TIMER);
  if (cpu.halted && (cpu.flags & F_IF)) cpu.halted = false;
}

// ------------------------------------------------------------------ input
void Machine::key_press(uint16_t code) {
  if (keys_.size() < 32) keys_.push_back(code);
  last_scancode_ = uint8_t(code >> 8);
  waiting_input_ = false;
  cpu.raise_irq(VEC_KEYBOARD);
}

void Machine::key_release(uint8_t scancode) { last_scancode_ = scancode | 0x80; }

void Machine::mouse_move(int x, int y) {
  mouse_x_ = std::max(mouse_xmin_, std::min(mouse_xmax_, x));
  mouse_y_ = std::max(mouse_ymin_, std::min(mouse_ymax_, y));
}

void Machine::mouse_buttons(int b) { mouse_btn_ = b; }

// ------------------------------------------------------------------ video
void Machine::render(uint32_t* out) {
  if (video_mode() == 0x13) {
    uint32_t pal[256];
    for (int i = 0; i < 256; i++) {
      uint32_t r = pal_[i * 3] * 255 / 63, g = pal_[i * 3 + 1] * 255 / 63, b = pal_[i * 3 + 2] * 255 / 63;
      pal[i] = 0xFF000000u | (r << 16) | (g << 8) | b;
    }
    for (int y = 0; y < 200; y++) {
      for (int x = 0; x < 320; x++) {
        uint32_t c = pal[gfx_[y * 320 + x]];
        uint32_t* o = out + (y * 2) * kScreenW + x * 2;
        o[0] = o[1] = o[kScreenW] = o[kScreenW + 1] = c;
      }
    }
    if (mouse_shown_ > 0) {  // arrow-shaped hardware cursor overlay
      static const char* arrow[] = {"X.........", "XX........", "XWX.......", "XWWX......", "XWWWX.....",
                                    "XWWWWX....", "XWWWWWX...", "XWWWWWWX..", "XWWWWXXXX.", "XWXWWX....",
                                    "XX.XWWX...", "X...XWX...", "....XWWX..", ".....XX..."};
      for (int dy = 0; dy < 14; dy++)
        for (int dx = 0; dx < 10; dx++) {
          char ch = arrow[dy][dx];
          if (ch == '.') continue;
          int px = mouse_x_ + dx, py = mouse_y_ + dy;
          if (px >= 320 || py >= 200) continue;
          uint32_t c = ch == 'X' ? 0xFF000000u : 0xFFFFFFFFu;
          uint32_t* o = out + (py * 2) * kScreenW + px * 2;
          o[0] = o[1] = o[kScreenW] = o[kScreenW + 1] = c;
        }
    }
    return;
  }
  // text mode: 80x25 cells of 8x16 (8x8 font, doubled vertically)
  bool blink_on = (frames_ / 16) % 2 == 0;
  int cur_c = mem_[mm::BDA_CUR_COL], cur_r = mem_[mm::BDA_CUR_ROW];
  int mcol = mouse_x_ / 8, mrow = mouse_y_ / 8;
  for (int row = 0; row < 25; row++) {
    for (int col = 0; col < 80; col++) {
      uint8_t ch = mem_[mm::TEXT_VRAM + (row * 80 + col) * 2];
      uint8_t at = mem_[mm::TEXT_VRAM + (row * 80 + col) * 2 + 1];
      if (mouse_shown_ > 0 && row == mrow && col == mcol) at = uint8_t(0x7F ^ at);
      uint32_t fg = 0xFF000000u | kCga[at & 15], bg = 0xFF000000u | kCga[at >> 4];
      for (int gy = 0; gy < 8; gy++) {
        uint8_t bits = kFont8x8[ch][gy];
        if (gy == 7 && blink_on && mem_[mm::BDA_CUR_SHOW] && row == cur_r && col == cur_c) bits = 0xFF;
        uint32_t* o = out + (row * 16 + gy * 2) * kScreenW + col * 8;
        for (int gx = 0; gx < 8; gx++) {
          uint32_t c = (bits & (0x80 >> gx)) ? fg : bg;
          o[gx] = o[gx + kScreenW] = c;
        }
      }
    }
  }
}

std::string Machine::text_screen() const {
  std::string s;
  for (int row = 0; row < 25; row++) {
    std::string line;
    for (int col = 0; col < 80; col++) {
      uint8_t ch = mem_[mm::TEXT_VRAM + (row * 80 + col) * 2];
      switch (ch) {
        case 0xC4: case 0xCD: line += '-'; break;
        case 0xB3: case 0xBA: line += '|'; break;
        case 0xDA: case 0xBF: case 0xC0: case 0xD9: case 0xC9: case 0xBB: case 0xC8: case 0xBC:
        case 0xC3: case 0xB4: case 0xC2: case 0xC1: case 0xC5: line += '+'; break;
        case 0x10: line += '>'; break;
        default: line += (ch >= 32 && ch < 127) ? char(ch) : (ch == 0 ? ' ' : '#'); break;
      }
    }
    while (!line.empty() && line.back() == ' ') line.pop_back();
    s += line + "\n";
  }
  return s;
}

void Machine::scroll_text(int top, int left, int bottom, int right, int lines, uint8_t attr) {
  int height = bottom - top + 1;
  if (lines <= 0 || lines >= height) lines = height;  // 0 = clear window
  for (int row = top; row <= bottom; row++) {
    int src = row + lines;
    for (int col = left; col <= right; col++) {
      uint16_t d = uint16_t(mm::TEXT_VRAM + (row * 80 + col) * 2);
      if (src <= bottom) {
        uint16_t sa = uint16_t(mm::TEXT_VRAM + (src * 80 + col) * 2);
        mem_[d] = mem_[sa];
        mem_[d + 1] = mem_[sa + 1];
      } else {
        mem_[d] = ' ';
        mem_[d + 1] = attr;
      }
    }
  }
}

void Machine::draw_gfx_char(int x, int y, uint8_t ch, uint8_t fg, int bg) {
  for (int gy = 0; gy < 8; gy++) {
    uint8_t bits = kFont8x8[ch][gy];
    for (int gx = 0; gx < 8; gx++) {
      if (bits & (0x80 >> gx)) put_pixel(x + gx, y + gy, fg);
      else if (bg >= 0) put_pixel(x + gx, y + gy, uint8_t(bg));
    }
  }
}

// Teletype output with cursor advance, CR/LF/BS/TAB handling and scrolling.
void Machine::tty_out(uint8_t ch, uint8_t attr) {
  bool gfx = video_mode() == 0x13;
  int cols = gfx ? 40 : 80;
  int col = mem_[mm::BDA_CUR_COL], row = mem_[mm::BDA_CUR_ROW];
  switch (ch) {
    case '\r': col = 0; break;
    case '\n': row++; break;
    case 8: if (col > 0) col--; break;
    case 7: break;  // bell
    case '\t': col = (col + 8) & ~7; break;
    default:
      if (gfx) {
        draw_gfx_char(col * 8, row * 8, ch, attr, 0);
      } else {
        mem_[mm::TEXT_VRAM + (row * 80 + col) * 2] = ch;
        mem_[mm::TEXT_VRAM + (row * 80 + col) * 2 + 1] = attr;
      }
      col++;
  }
  if (col >= cols) {
    col = 0;
    row++;
  }
  if (row >= 25) {
    if (gfx) {
      memmove(gfx_, gfx_ + 320 * 8, 320 * 192);
      memset(gfx_ + 320 * 192, 0, 320 * 8);
    } else {
      scroll_text(0, 0, 24, 79, 1, mem_[mm::BDA_ATTR] ? mem_[mm::BDA_ATTR] : 0x07);
    }
    row = 24;
  }
  mem_[mm::BDA_CUR_COL] = uint8_t(col);
  mem_[mm::BDA_CUR_ROW] = uint8_t(row);
}

void Machine::print(const std::string& s, uint8_t attr) {
  for (char c : s) {
    if (c == '\n') tty_out('\r', attr);
    tty_out(uint8_t(c), attr);
  }
}

// ------------------------------------------------------------------ processes
std::string Machine::exec(const std::string& raw_name, const std::string& args, bool as_child) {
  std::string name = Pfs::normalize(raw_name);
  if (!fs.mounted()) return "no disk";
  int idx = fs.find(name);
  if (idx < 0 && name.find('.') == std::string::npos) {
    name += ".PEX";
    idx = fs.find(name);
  }
  if (idx < 0) return "file not found";
  const PfsEntry* e = fs.entry(idx);
  std::vector<uint8_t> file(e->size);
  fs.read(idx, 0, file.data(), e->size);
  PexImage img;
  std::string err = pex_parse(file, img);
  if (!err.empty()) return "invalid executable: " + err;
  const PexHeader& h = img.hdr;
  // the new image must not overlap any running (suspended) process
  for (const auto& p : procs_) {
    if (h.load_addr < p.hi && img.image_end() > p.lo)
      return "not enough memory (image overlaps " + p.name + ")";
  }
  Process proc;
  proc.name = name;
  proc.lo = h.load_addr;
  proc.hi = img.image_end();
  proc.has_parent = as_child;
  if (as_child) proc.parent = cpu.save();

  // copy segments: code+data, zero the BSS and stack
  memcpy(&mem_[h.load_addr], img.payload, size_t(h.code_size) + h.data_size);
  memset(&mem_[h.load_addr + h.code_size + h.data_size], 0, size_t(h.bss_size) + h.stack_size);
  // command line -> PSP area
  std::string cmd = args.substr(0, 126);
  memcpy(&mem_[mm::PSP_CMDLINE], cmd.c_str(), cmd.size() + 1);
  dta_ = mm::DTA_DEFAULT;
  procs_.push_back(proc);

  cpu.reset(h.entry);
  cpu.r[SP] = uint16_t(proc.hi);  // stack grows down from the end of the image
  cpu.flags = F_IF;
  waiting_input_ = false;
  line_input_active_ = false;
  return "";
}

void Machine::terminate(uint8_t code) {
  if (procs_.empty()) {
    power_off(code, "");
    return;
  }
  Process p = procs_.back();
  procs_.pop_back();
  // close files left open by the program
  for (auto& h : handles_) h = Handle();
  fs.flush();
  waiting_input_ = false;
  line_input_active_ = false;
  if (!p.has_parent || procs_.empty()) {
    power_off(code, "");
    return;
  }
  last_child_code_ = code;
  cpu.load(p.parent);  // back inside the parent's INT 21h stub, right before IRET
  cpu.r[AX] = code;
  set_result_flag(F_CF, false);
}

bool Machine::boot(const std::string& program, std::string& err) {
  power_on();
  err = exec(program, "", false);
  if (!err.empty()) {
    print("PERRY-16 BIOS: cannot start " + program + ": " + err + "\n", 0x0C);
    return false;
  }
  return true;
}

bool Machine::boot_raw(const std::vector<uint8_t>& bin, uint16_t org, std::string& err) {
  power_on();
  if (size_t(org) + bin.size() > mm::ROM) {
    err = "raw image too large";
    return false;
  }
  memcpy(&mem_[org], bin.data(), bin.size());
  cpu.reset(org);
  cpu.r[SP] = 0x1000;  // stack in free low RAM
  cpu.flags = F_IF;
  return true;
}

}  // namespace p16
