// PERRY-16 machine: memory map, devices, firmware (HLE BIOS/DOS) and the
// process manager that loads .PEX programs from disk.img.
//
//   0x0000-0x03FF  IVT: 256 vectors x 4 bytes (word 0 = handler address)
//   0x0400-0x04FF  BIOS data area (ticks, cursor, video mode, ...)
//   0x0500-0x05FF  kernel scratch
//   0x0600-0x067F  command line of the running program (ASCIIZ)
//   0x0680-0x06FF  default disk transfer area (DTA)
//   0x0700-0x0FFF  free low RAM
//   0x1000-0x9FFF  system RAM: 0x1000 shell (COMMAND.PEX), 0x3000 programs (TPA)
//   0xA000-0xB7FF  VGA window: 6 KB view into the 64000-byte 320x200 framebuffer,
//                  4 KB bank granularity, bank selected through port 0x3CD
//   0xB800-0xC79F  text VRAM 80x25 (char, attribute) pairs
//   0xC800-0xEFFF  upper RAM (10 KB, free for programs)
//   0xF000-0xF3FF  ROM: 256 interrupt stubs  "BIOS n ; IRET"
//   0xF400-0xF7FF  ROM: BIOS identification / reserved
//   0xF800-0xFFFF  ROM: 8x8 system font (256 glyphs)
#pragma once
#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <vector>

#include "cpu.h"
#include "opl2.h"
#include "pfs.h"

namespace p16 {

namespace mm {
constexpr uint16_t IVT = 0x0000;
constexpr uint16_t BDA = 0x0400;
constexpr uint16_t BDA_TICKS = 0x0400;     // u32, 70 Hz tick counter
constexpr uint16_t BDA_CUR_COL = 0x0404;   // u8
constexpr uint16_t BDA_CUR_ROW = 0x0405;   // u8
constexpr uint16_t BDA_VMODE = 0x0406;     // u8: 0x03 text, 0x13 graphics
constexpr uint16_t BDA_ATTR = 0x0407;      // u8: default text attribute
constexpr uint16_t BDA_CUR_SHOW = 0x0408;  // u8: 1 = text cursor visible
constexpr uint16_t PSP_CMDLINE = 0x0600;
constexpr uint16_t DTA_DEFAULT = 0x0680;
constexpr uint16_t RAM_START = 0x1000;
constexpr uint16_t TPA_START = 0x3000;
constexpr uint32_t RAM_END = 0xA000;
constexpr uint16_t VGA_WIN = 0xA000;
constexpr uint16_t VGA_WIN_END = 0xB800;
constexpr uint16_t TEXT_VRAM = 0xB800;
constexpr uint16_t UMA = 0xC800;
constexpr uint16_t UMA_END = 0xF000;
constexpr uint16_t ROM = 0xF000;
constexpr uint16_t ROM_ID = 0xF400;
constexpr uint16_t FONT = 0xF800;
}  // namespace mm

namespace port {
constexpr uint16_t PIT = 0x0040;        // read: free-running cycle counter (low 16 bits)
constexpr uint16_t KBD_DATA = 0x0060;   // read: last scancode (bit 7 = release)
constexpr uint16_t KBD_STATUS = 0x0064; // read: bit 0 = key waiting
constexpr uint16_t DEBUG_OUT = 0x00E9;  // write: character to host stderr
constexpr uint16_t POWER = 0x00F4;      // write: power off, value = exit code
constexpr uint16_t ADLIB_INDEX = 0x0388;  // write: register index / read: status
constexpr uint16_t ADLIB_DATA = 0x0389;   // write: register data
constexpr uint16_t DAC_READ_INDEX = 0x03C7;
constexpr uint16_t DAC_WRITE_INDEX = 0x03C8;
constexpr uint16_t DAC_DATA = 0x03C9;
constexpr uint16_t VGA_BANK = 0x03CD;   // 4 KB bank shown at 0xA000
constexpr uint16_t VGA_STATUS = 0x03DA; // read: bit 3 = vertical retrace
}  // namespace port

// Keyboard codes delivered to programs: (scancode << 8) | ascii
namespace key {
constexpr uint16_t ESC = 0x011B, ENTER = 0x1C0D, BACKSPACE = 0x0E08, TAB = 0x0F09;
constexpr uint16_t UP = 0x4800, DOWN = 0x5000, LEFT = 0x4B00, RIGHT = 0x4D00;
constexpr uint16_t HOME = 0x4700, END = 0x4F00, PGUP = 0x4900, PGDN = 0x5100;
constexpr uint16_t INS = 0x5200, DEL = 0x5300;
constexpr uint16_t F1 = 0x3B00;  // F1..F10 = 0x3B00..0x4400
uint16_t from_ascii(char c);     // printable ASCII -> keycode with PC scancode
}  // namespace key

class Machine : public Bus {
 public:
  static constexpr int kScreenW = 640, kScreenH = 400;  // rendered output size
  static constexpr int kFps = 70;

  Machine();
  ~Machine() override;

  CPU cpu{*this};
  Opl2 opl;
  Pfs fs;

  // --- configuration
  uint32_t clock_hz = 8000000;      // emulated CPU cycles per second
  bool trace = false;               // print each instruction to stderr
  std::function<void(char)> debug_sink;  // port 0xE9 output (default stderr)

  // --- lifecycle
  bool mount(const std::string& disk_path, std::string& err) { return fs.mount(disk_path, err); }
  void power_on();
  bool boot(const std::string& program, std::string& err);    // load + run a PEX as the first process
  bool boot_raw(const std::vector<uint8_t>& bin, uint16_t org, std::string& err);  // bare-metal image
  void run_frame();                     // 1/70 s of emulation + timer tick
  void run_cycles(uint64_t budget);
  bool powered_off() const { return powered_off_; }
  int exit_code() const { return exit_code_; }
  bool waiting_for_input() const { return waiting_input_; }
  std::string last_error() const { return last_error_; }

  // --- input from the frontend
  void key_press(uint16_t code);        // queue a key (scancode<<8 | ascii)
  void key_release(uint8_t scancode);
  size_t keys_pending() const { return keys_.size(); }
  void mouse_move(int x, int y);        // in mouse coordinates of the current mode
  void mouse_buttons(int buttons);      // bit0 left, bit1 right, bit2 middle
  int mouse_x() const { return mouse_x_; }
  int mouse_y() const { return mouse_y_; }
  bool mouse_visible() const { return mouse_shown_ > 0; }

  // --- output for the frontend
  void render(uint32_t* rgba);          // 640x400, 0xAARRGGBB
  int video_mode() const { return mem_[mm::BDA_VMODE]; }
  std::string text_screen() const;      // 80x25 text dump (for tests)
  const uint8_t* framebuffer() const { return gfx_; }
  const uint8_t* palette() const { return pal_; }
  const uint8_t* memory() const { return mem_; }
  void audio(int16_t* out, int n) { opl.generate(out, n); }

  // --- Bus interface
  uint8_t read8(uint16_t a) override;
  void write8(uint16_t a, uint8_t v) override;
  uint16_t io_in(uint16_t port) override;
  void io_out(uint16_t port, uint16_t v) override;
  void bios_trap(uint8_t vector) override;

 private:
  uint8_t mem_[65536];
  uint8_t gfx_[64000];
  uint8_t pal_[768];          // 6-bit VGA DAC values
  uint8_t vga_bank_ = 0;
  int dac_write_ = 0, dac_read_ = 0;
  uint64_t frame_start_cycles_ = 0;
  uint64_t frames_ = 0;

  std::deque<uint16_t> keys_;
  uint8_t last_scancode_ = 0;
  bool waiting_input_ = false;
  bool line_input_active_ = false;

  int mouse_x_ = 160, mouse_y_ = 100, mouse_btn_ = 0, mouse_shown_ = 0;
  int mouse_xmin_ = 0, mouse_xmax_ = 639, mouse_ymin_ = 0, mouse_ymax_ = 199;

  bool powered_off_ = false;
  int exit_code_ = 0;
  std::string last_error_;

  // processes
  struct Process {
    std::string name;
    uint16_t lo = 0;
    uint32_t hi = 0;
    bool has_parent = false;
    CpuState parent;  // parent CPU state captured inside its INT 21h/4Bh
  };
  std::vector<Process> procs_;
  uint8_t last_child_code_ = 0;

  // files
  struct Handle {
    bool used = false;
    int idx = -1;
    uint32_t pos = 0;
    bool write = false;
  };
  static constexpr int kFirstHandle = 5, kMaxHandles = 16;
  Handle handles_[kMaxHandles];
  uint16_t dta_ = mm::DTA_DEFAULT;
  std::string find_pattern_;

  // --- helpers (machine.cpp)
  void install_rom();
  void reset_palette();
  void set_video_mode(uint8_t mode);
  void put_pixel(int x, int y, uint8_t c) {
    if (x >= 0 && x < 320 && y >= 0 && y < 200) gfx_[y * 320 + x] = c;
  }
  void tty_out(uint8_t ch, uint8_t attr_or_color);
  void scroll_text(int top, int left, int bottom, int right, int lines, uint8_t attr);
  void draw_gfx_char(int x, int y, uint8_t ch, uint8_t fg, int bg);
  void power_off(int code, const std::string& why);

  // --- firmware services (bios.cpp)
  void int10_video();
  void int16_keyboard();
  void int21_dos();
  void int33_mouse();
  void fault(const char* what);
  void block();                          // re-execute the BIOS trap later (wait for input)
  void set_result_flag(Flag f, bool on); // set flag in live FLAGS and the stacked copy
  uint8_t ah() const { return cpu.r[AX] >> 8; }
  uint8_t al() const { return cpu.r[AX] & 0xFF; }
  void set_al(uint8_t v) { cpu.r[AX] = (cpu.r[AX] & 0xFF00) | v; }
  std::string read_cstr(uint16_t addr, size_t max = 128);
  void dos_ok() { set_result_flag(F_CF, false); }
  void dos_error(uint16_t code) {
    cpu.r[AX] = code;
    set_result_flag(F_CF, true);
  }
  void print(const std::string& s, uint8_t attr = 0x07);

 public:
  // process management (used by bios.cpp and the frontends)
  std::string exec(const std::string& name, const std::string& args, bool as_child);
  void terminate(uint8_t code);
  int process_depth() const { return int(procs_.size()); }
};

}  // namespace p16
