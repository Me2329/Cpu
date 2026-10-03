// PERRY-16 firmware: high-level emulated BIOS and PERRY-DOS services.
//
// Every IVT entry initially points at a 4-byte ROM stub "BIOS n ; IRET".
// The BIOS instruction traps into Machine::bios_trap(n), which implements
// the service natively in C++. A program can hook any vector by writing a
// new handler address into the IVT (INT 21h AH=25h) and can chain to the
// original stub address it read back with AH=35h.
//
// Conventions:
//  * results are returned in registers; CF (and ZF for INT 16h/01h) are
//    written both to the live FLAGS and to the FLAGS image saved on the
//    stack by INT, so they survive the IRET of the stub;
//  * a service that has to wait for input rewinds PC onto the BIOS
//    instruction and marks the machine idle (block()); it is re-executed
//    when the frontend delivers a key.
#include <algorithm>
#include <cctype>
#include <cstring>
#include <ctime>

#include "machine.h"

namespace p16 {

namespace {
bool wildcard(const char* pat, const char* s) {
  if (*pat == 0) return *s == 0;
  if (*pat == '*') {
    for (const char* t = s;; t++) {
      if (wildcard(pat + 1, t)) return true;
      if (*t == 0) return false;
    }
  }
  if (*s == 0) return false;
  if (*pat == '?' || toupper(uint8_t(*pat)) == toupper(uint8_t(*s))) return wildcard(pat + 1, s + 1);
  return false;
}

bool match_name(const std::string& pattern, const std::string& name) {
  // DOS-style: "*.*" matches names without extension too
  if (pattern == "*.*" || pattern == "*" || pattern.empty()) return true;
  return wildcard(pattern.c_str(), name.c_str());
}
}  // namespace

enum DosError : uint16_t {
  E_FUNCTION = 1, E_NOT_FOUND = 2, E_TOO_MANY = 4, E_ACCESS = 5, E_HANDLE = 6,
  E_MEMORY = 8, E_FORMAT = 11, E_NO_MORE = 18
};

void Machine::set_result_flag(Flag f, bool on) {
  cpu.set_flag(f, on);
  uint16_t sp = cpu.r[SP];
  uint16_t saved = cpu.read16(uint16_t(sp + 2));  // [SP]=return PC, [SP+2]=FLAGS
  saved = on ? (saved | f) : (saved & ~f);
  cpu.write16(uint16_t(sp + 2), saved);
}

void Machine::block() {
  cpu.pc -= 2;
  waiting_input_ = true;
}

std::string Machine::read_cstr(uint16_t addr, size_t max) {
  std::string s;
  for (size_t i = 0; i < max; i++) {
    char c = char(read8(uint16_t(addr + i)));
    if (!c) break;
    s += c;
  }
  return s;
}

void Machine::fault(const char* what) {
  uint16_t at = cpu.read16(cpu.r[SP]);
  char buf[96];
  snprintf(buf, sizeof buf, "\r\n%s at %04X - program terminated\r\n", what, at);
  if (video_mode() != 0x03) set_video_mode(0x03);
  for (const char* p = buf; *p; p++) tty_out(uint8_t(*p), 0x0C);
  last_error_ = buf;
  terminate(0xFF);
}

void Machine::bios_trap(uint8_t v) {
  switch (v) {
    case 0x00: fault("Divide overflow"); break;
    case 0x06: fault("Invalid opcode"); break;
    case 0x08: break;  // timer tick (counter is maintained by the machine)
    case 0x09: break;  // keyboard IRQ (keys are queued by the machine)
    case 0x10: int10_video(); break;
    case 0x16: int16_keyboard(); break;
    case 0x20: terminate(0); break;
    case 0x21: int21_dos(); break;
    case 0x33: int33_mouse(); break;
    default: break;
  }
}

// ------------------------------------------------------------------ INT 10h
void Machine::int10_video() {
  uint16_t& ax = cpu.r[AX];
  uint16_t bx = cpu.r[BX], cx = cpu.r[CX], dx = cpu.r[DX];
  uint8_t dh = dx >> 8, dl = dx & 0xFF;
  bool gfx = video_mode() == 0x13;
  switch (ah()) {
    case 0x00: set_video_mode(al()); break;
    case 0x01: mem_[mm::BDA_CUR_SHOW] = (cx & 0x2000) ? 0 : 1; break;
    case 0x02:
      mem_[mm::BDA_CUR_ROW] = std::min<uint8_t>(dh, 24);
      mem_[mm::BDA_CUR_COL] = std::min<uint8_t>(dl, gfx ? 39 : 79);
      break;
    case 0x03:
      cpu.r[DX] = uint16_t((mem_[mm::BDA_CUR_ROW] << 8) | mem_[mm::BDA_CUR_COL]);
      cpu.r[CX] = mem_[mm::BDA_CUR_SHOW] ? 0x0607 : 0x2000;
      break;
    case 0x06: {
      int top = cx >> 8, left = cx & 0xFF;
      scroll_text(std::min(top, 24), std::min(left, 79), std::min<int>(dh, 24), std::min<int>(dl, 79),
                  al(), uint8_t(bx >> 8));
      break;
    }
    case 0x08: {
      uint16_t a = uint16_t(mm::TEXT_VRAM + (mem_[mm::BDA_CUR_ROW] * 80 + mem_[mm::BDA_CUR_COL]) * 2);
      ax = uint16_t(mem_[a] | (mem_[a + 1] << 8));
      break;
    }
    case 0x09:
    case 0x0A: {
      int pos = mem_[mm::BDA_CUR_ROW] * 80 + mem_[mm::BDA_CUR_COL];
      for (int i = 0; i < cx && pos < 2000; i++, pos++) {
        if (gfx) {
          draw_gfx_char((pos % 40) * 8, (pos / 40) * 8, al(), uint8_t(bx), 0);
          continue;
        }
        mem_[mm::TEXT_VRAM + pos * 2] = al();
        if (ah() == 0x09) mem_[mm::TEXT_VRAM + pos * 2 + 1] = uint8_t(bx);
      }
      break;
    }
    case 0x0C: put_pixel(cx, dx, al()); break;
    case 0x0D: set_al((cx < 320 && dx < 200) ? gfx_[dx * 320 + cx] : 0); break;
    case 0x0E: tty_out(al(), gfx ? uint8_t(bx ? bx : 15) : mem_[mm::BDA_ATTR]); break;
    case 0x0F: ax = uint16_t(((gfx ? 40 : 80) << 8) | video_mode()); break;
    case 0x13: {  // write ASCIIZ string SI at DH,DL with attribute BL (no cursor move)
      std::string s = read_cstr(cpu.r[SI], 2000);
      int pos = dh * 80 + dl;
      for (char c : s) {
        if (pos >= 2000) break;
        if (gfx) {
          draw_gfx_char((pos % 40) * 8, (pos / 40) * 8, uint8_t(c), uint8_t(bx), -1);
        } else {
          mem_[mm::TEXT_VRAM + pos * 2] = uint8_t(c);
          mem_[mm::TEXT_VRAM + pos * 2 + 1] = uint8_t(bx);
        }
        pos++;
      }
      break;
    }
    case 0x40: {  // linear blit: SI=source, DI=framebuffer offset, CX=bytes
      uint32_t dst = cpu.r[DI];
      for (uint32_t i = 0; i < cx && dst + i < sizeof gfx_; i++) gfx_[dst + i] = read8(uint16_t(cpu.r[SI] + i));
      break;
    }
    case 0x41: {  // 2x blit: SI=source, BX=width, CX=height, DI=framebuffer offset
      int w = bx, h = cx;
      int ox = cpu.r[DI] % 320, oy = cpu.r[DI] / 320;
      uint16_t src = cpu.r[SI];
      for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
          uint8_t c = read8(uint16_t(src + y * w + x));
          int px = ox + x * 2, py = oy + y * 2;
          put_pixel(px, py, c);
          put_pixel(px + 1, py, c);
          put_pixel(px, py + 1, c);
          put_pixel(px + 1, py + 1, c);
        }
      break;
    }
    case 0x42: {  // graphics text: SI=string, CX=x, DX=y, BL=colour, BH=background (FF = none)
      std::string s = read_cstr(cpu.r[SI], 80);
      int bg = (bx >> 8) == 0xFF ? -1 : (bx >> 8);
      int x = int16_t(cx);
      for (char c : s) {
        draw_gfx_char(x, int16_t(dx), uint8_t(c), uint8_t(bx), bg);
        x += 8;
      }
      break;
    }
    case 0x43: {  // fill rectangle: CX=x, DX=y, SI=width, DI=height, BL=colour
      for (int y = 0; y < cpu.r[DI]; y++)
        for (int x = 0; x < cpu.r[SI]; x++) put_pixel(int16_t(cx) + x, int16_t(dx) + y, uint8_t(bx));
      break;
    }
    default: break;
  }
}

// ------------------------------------------------------------------ INT 16h
void Machine::int16_keyboard() {
  switch (ah()) {
    case 0x00:
    case 0x10:
      if (keys_.empty()) {
        block();
        return;
      }
      cpu.r[AX] = keys_.front();
      keys_.pop_front();
      break;
    case 0x01:
    case 0x11:
      if (keys_.empty()) {
        set_result_flag(F_ZF, true);
      } else {
        cpu.r[AX] = keys_.front();
        set_result_flag(F_ZF, false);
      }
      break;
    case 0x02: set_al(0); break;
    default: break;
  }
}

// ------------------------------------------------------------------ INT 33h
void Machine::int33_mouse() {
  switch (cpu.r[AX]) {
    case 0x0000:
      cpu.r[AX] = 0xFFFF;
      cpu.r[BX] = 3;
      mouse_shown_ = 0;
      mouse_x_ = (mouse_xmax_ + 1) / 2;
      mouse_y_ = (mouse_ymax_ + 1) / 2;
      break;
    case 0x0001: mouse_shown_ = 1; break;
    case 0x0002: mouse_shown_ = 0; break;
    case 0x0003:
      cpu.r[BX] = uint16_t(mouse_btn_);
      cpu.r[CX] = uint16_t(mouse_x_);
      cpu.r[DX] = uint16_t(mouse_y_);
      break;
    case 0x0004: mouse_move(cpu.r[CX], cpu.r[DX]); break;
    case 0x0007:
      mouse_xmin_ = cpu.r[CX];
      mouse_xmax_ = cpu.r[DX];
      mouse_move(mouse_x_, mouse_y_);
      break;
    case 0x0008:
      mouse_ymin_ = cpu.r[CX];
      mouse_ymax_ = cpu.r[DX];
      mouse_move(mouse_x_, mouse_y_);
      break;
    default: break;
  }
}

// ------------------------------------------------------------------ INT 21h
void Machine::int21_dos() {
  const uint8_t fn = ah();
  uint16_t bx = cpu.r[BX], cx = cpu.r[CX], dx = cpu.r[DX];
  uint8_t out_attr = video_mode() == 0x13 ? 15 : (mem_[mm::BDA_ATTR] ? mem_[mm::BDA_ATTR] : 0x07);
  switch (fn) {
    case 0x01:  // read key with echo -> AL (AH = scancode)
    case 0x07:  // read key, no echo
    case 0x08: {
      if (keys_.empty()) {
        block();
        return;
      }
      uint16_t k = keys_.front();
      keys_.pop_front();
      cpu.r[AX] = k;
      if (fn == 0x01 && (k & 0xFF)) tty_out(k & 0xFF, out_attr);
      cpu.r[AX] = k;
      break;
    }
    case 0x02: tty_out(dx & 0xFF, out_attr); break;
    case 0x09: {  // print ASCIIZ string at DX ('\n' is a plain line feed)
      std::string s = read_cstr(dx, 4096);
      for (char c : s) tty_out(uint8_t(c), out_attr);
      break;
    }
    case 0x0A: {  // buffered line input: [DX]=max, [DX+1]=count, [DX+2..]=chars, CR-terminated
      uint8_t max = read8(dx);
      if (!line_input_active_) {
        line_input_active_ = true;
        write8(uint16_t(dx + 1), 0);
      }
      while (!keys_.empty()) {
        uint16_t k = keys_.front();
        keys_.pop_front();
        uint8_t n = read8(uint16_t(dx + 1)), c = k & 0xFF;
        if (c == '\r') {
          write8(uint16_t(dx + 2 + n), '\r');
          tty_out('\r', out_attr);
          tty_out('\n', out_attr);
          line_input_active_ = false;
          return;
        }
        if (c == 8) {
          if (n > 0) {
            write8(uint16_t(dx + 1), uint8_t(n - 1));
            tty_out(8, out_attr); tty_out(' ', out_attr); tty_out(8, out_attr);
          }
        } else if (c == 27) {
          for (; n > 0; n--) { tty_out(8, out_attr); tty_out(' ', out_attr); tty_out(8, out_attr); }
          write8(uint16_t(dx + 1), 0);
        } else if (c >= 32 && n + 1 < max) {
          write8(uint16_t(dx + 2 + n), c);
          write8(uint16_t(dx + 1), uint8_t(n + 1));
          tty_out(c, out_attr);
        }
      }
      block();
      return;
    }
    case 0x0B: set_al(keys_.empty() ? 0x00 : 0xFF); break;
    case 0x19: set_al(0); break;
    case 0x1A: dta_ = dx; break;
    case 0x25: cpu.write16(uint16_t(al() * 4), dx); break;
    case 0x2A: {
      time_t t = time(nullptr);
      tm* lt = localtime(&t);
      cpu.r[CX] = uint16_t(lt->tm_year + 1900);
      cpu.r[DX] = uint16_t(((lt->tm_mon + 1) << 8) | lt->tm_mday);
      set_al(uint8_t(lt->tm_wday));
      break;
    }
    case 0x2C: {
      time_t t = time(nullptr);
      tm* lt = localtime(&t);
      cpu.r[CX] = uint16_t((lt->tm_hour << 8) | lt->tm_min);
      cpu.r[DX] = uint16_t(lt->tm_sec << 8);
      break;
    }
    case 0x30: cpu.r[AX] = 0x0001; cpu.r[BX] = 0x5016; break;  // PERRY-DOS 1.0, BX='P',16
    case 0x35: cpu.r[BX] = cpu.read16(uint16_t(al() * 4)); break;
    case 0x36:
      cpu.r[AX] = uint16_t(fs.free_bytes() / 1024);
      cpu.r[BX] = uint16_t(fs.total_bytes() / 1024);
      cpu.r[CX] = Pfs::kSector;
      break;
    case 0x3C:    // create / truncate file DX -> AX handle
    case 0x3D: {  // open file DX, AL = 0 read / 1 write / 2 read-write
      std::string name = read_cstr(dx);
      int idx = fn == 0x3C ? fs.create(name) : fs.find(name);
      if (idx < 0) {
        dos_error(fn == 0x3C ? E_ACCESS : E_NOT_FOUND);
        return;
      }
      int h = -1;
      for (int i = kFirstHandle; i < kMaxHandles; i++)
        if (!handles_[i].used) { h = i; break; }
      if (h < 0) {
        dos_error(E_TOO_MANY);
        return;
      }
      handles_[h].used = true;
      handles_[h].idx = idx;
      handles_[h].pos = 0;
      handles_[h].write = fn == 0x3C || (al() & 3) != 0;
      cpu.r[AX] = uint16_t(h);
      dos_ok();
      break;
    }
    case 0x3E:
      if (bx >= kMaxHandles || !handles_[bx].used) {
        dos_error(E_HANDLE);
        return;
      }
      handles_[bx] = Handle();
      fs.flush();
      dos_ok();
      break;
    case 0x3F: {  // read BX handle, CX bytes into DX -> AX bytes read
      if (bx == 0) { cpu.r[AX] = 0; dos_ok(); break; }
      if (bx >= kMaxHandles || !handles_[bx].used) {
        dos_error(E_HANDLE);
        return;
      }
      Handle& h = handles_[bx];
      std::vector<uint8_t> tmp(cx);
      uint32_t n = fs.read(h.idx, h.pos, tmp.data(), cx);
      for (uint32_t i = 0; i < n; i++) write8(uint16_t(dx + i), tmp[i]);
      h.pos += n;
      cpu.r[AX] = uint16_t(n);
      dos_ok();
      break;
    }
    case 0x40: {  // write BX handle, CX bytes from DX -> AX bytes written
      if (bx == 1 || bx == 2) {
        for (uint16_t i = 0; i < cx; i++) tty_out(read8(uint16_t(dx + i)), out_attr);
        cpu.r[AX] = cx;
        dos_ok();
        break;
      }
      if (bx >= kMaxHandles || !handles_[bx].used || !handles_[bx].write) {
        dos_error(bx < kMaxHandles && handles_[bx].used ? E_ACCESS : E_HANDLE);
        return;
      }
      Handle& h = handles_[bx];
      std::vector<uint8_t> tmp(cx);
      for (uint16_t i = 0; i < cx; i++) tmp[i] = read8(uint16_t(dx + i));
      uint32_t n = fs.write(h.idx, h.pos, tmp.data(), cx);
      h.pos += n;
      cpu.r[AX] = uint16_t(n);
      dos_ok();
      break;
    }
    case 0x41:
      if (!fs.remove(read_cstr(dx))) {
        dos_error(E_NOT_FOUND);
        return;
      }
      fs.flush();
      dos_ok();
      break;
    case 0x42: {  // seek BX, AL = 0 start / 1 current / 2 end, CX:DX offset -> DX:AX
      if (bx >= kMaxHandles || !handles_[bx].used) {
        dos_error(E_HANDLE);
        return;
      }
      Handle& h = handles_[bx];
      int32_t off = int32_t((uint32_t(cx) << 16) | dx);
      int64_t base = al() == 0 ? 0 : al() == 1 ? h.pos : fs.entry(h.idx)->size;
      int64_t np = base + off;
      if (np < 0) np = 0;
      h.pos = uint32_t(np);
      cpu.r[AX] = uint16_t(h.pos);
      cpu.r[DX] = uint16_t(h.pos >> 16);
      dos_ok();
      break;
    }
    case 0x4B: {  // EXEC: DX = program name, BX = argument string (or 0)
      std::string name = read_cstr(dx);
      std::string args = bx ? read_cstr(bx, 126) : "";
      std::string err = exec(name, args, true);
      if (!err.empty()) {
        uint16_t code = err.rfind("file", 0) == 0 ? E_NOT_FOUND
                        : err.rfind("not enough", 0) == 0 ? E_MEMORY : E_FORMAT;
        dos_error(code);
      }
      return;  // on success the child is now running
    }
    case 0x4C: terminate(al()); return;
    case 0x4D: cpu.r[AX] = last_child_code_; break;
    case 0x4E:    // find first: DX = pattern -> DTA
    case 0x4F: {  // find next
      int start = 0;
      if (fn == 0x4E) {
        find_pattern_ = Pfs::normalize(read_cstr(dx));
      } else {
        start = cpu.read16(uint16_t(dta_ + 6));
      }
      for (int i = start; i < fs.count_slots(); i++) {
        const PfsEntry* e = fs.entry(i);
        if (!e || !match_name(find_pattern_, e->name)) continue;
        write8(dta_, e->attr);
        write8(uint16_t(dta_ + 1), 0);
        cpu.write16(uint16_t(dta_ + 2), uint16_t(e->size));
        cpu.write16(uint16_t(dta_ + 4), uint16_t(e->size >> 16));
        cpu.write16(uint16_t(dta_ + 6), uint16_t(i + 1));
        for (int j = 0; j < 13; j++)
          write8(uint16_t(dta_ + 8 + j), j < int(e->name.size()) ? uint8_t(e->name[j]) : 0);
        cpu.r[AX] = 0;
        dos_ok();
        return;
      }
      dos_error(E_NO_MORE);
      return;
    }
    case 0x58: {  // PERRY-DOS: memory information
      uint32_t top = mm::RAM_START;
      uint32_t used = 0;
      for (const auto& p : procs_) {
        top = std::max(top, p.hi);
        used += p.hi - p.lo;
      }
      cpu.r[AX] = uint16_t(mm::RAM_END - top);                 // free conventional RAM
      cpu.r[BX] = uint16_t(mm::RAM_END - mm::RAM_START);       // total conventional RAM
      cpu.r[CX] = uint16_t(mm::UMA_END - mm::UMA);             // upper RAM
      cpu.r[DX] = uint16_t(used);                              // used by loaded programs
      break;
    }
    case 0x62: cpu.r[BX] = mm::PSP_CMDLINE; break;
    default:
      dos_error(E_FUNCTION);
      return;
  }
}

}  // namespace p16
