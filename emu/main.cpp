// perry16 - PERRY-16 emulator frontends.
//
//   perry16 [disk.img]                  SDL2 window (if built with SDL), else terminal
//   perry16 --term [disk.img]           ANSI terminal frontend (Ctrl+Q quits)
//   perry16 --headless --script s.txt   scripted run for tests / screenshots
//   perry16 --raw prog.bin [--org N]    bare-metal binary, port 0xE9 -> stdout
//
// Options: --boot NAME.PEX  --mhz N  --trace  --wav out.wav  --frames N
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "imageio.h"
#include "machine.h"

#ifdef PERRY_SDL
#include <SDL.h>
#endif

#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

using namespace p16;

namespace {

struct Options {
  std::string disk = "build/disk.img";
  std::string boot = "COMMAND.PEX";
  std::string script, raw, wav;
  uint16_t org = 0x1000;
  uint32_t mhz = 8;
  bool headless = false, term = false, sdl = false, trace = false;
  long max_frames = -1;
};

std::vector<int16_t> g_wav;

void run_frame_with_audio(Machine& m) {
  m.run_frame();
  if (!g_wav.empty() || m.opl.active()) {
    // capture audio only once the program has started using the OPL2
    int16_t buf[44100 / Machine::kFps + 1];
    m.audio(buf, 44100 / Machine::kFps);
    g_wav.insert(g_wav.end(), buf, buf + 44100 / Machine::kFps);
  }
}

uint16_t key_by_name(const std::string& n) {
  static const struct { const char* name; uint16_t code; } names[] = {
    {"ENTER", key::ENTER}, {"RETURN", key::ENTER}, {"ESC", key::ESC}, {"BKSP", key::BACKSPACE},
    {"BACKSPACE", key::BACKSPACE}, {"TAB", key::TAB}, {"UP", key::UP}, {"DOWN", key::DOWN},
    {"LEFT", key::LEFT}, {"RIGHT", key::RIGHT}, {"HOME", key::HOME}, {"END", key::END},
    {"PGUP", key::PGUP}, {"PGDN", key::PGDN}, {"INS", key::INS}, {"DEL", key::DEL},
    {"SPACE", 0x3920}};
  for (auto& e : names)
    if (n == e.name) return e.code;
  if (n.size() >= 2 && n[0] == 'F') {
    int f = atoi(n.c_str() + 1);
    if (f >= 1 && f <= 10) return uint16_t(key::F1 + ((f - 1) << 8));
  }
  if (n.rfind("0x", 0) == 0) return uint16_t(strtol(n.c_str(), nullptr, 16));
  if (n.size() == 1) return key::from_ascii(n[0]);
  return 0;
}

std::string unescape(const std::string& s) {
  std::string o;
  for (size_t i = 0; i < s.size(); i++) {
    if (s[i] == '\\' && i + 1 < s.size()) {
      char c = s[++i];
      o += c == 'n' ? '\r' : c == 't' ? '\t' : c == 'e' ? '\x1b' : c == 'b' ? '\b' : c == 's' ? ' ' : c;
    } else {
      o += s[i];
    }
  }
  return o;
}

bool save_screenshot(Machine& m, const std::string& path) {
  std::vector<uint32_t> px(Machine::kScreenW * Machine::kScreenH);
  m.render(px.data());
  bool ppm = path.size() > 4 && path.substr(path.size() - 4) == ".ppm";
  return ppm ? write_ppm(path, px.data(), Machine::kScreenW, Machine::kScreenH)
             : write_png(path, px.data(), Machine::kScreenW, Machine::kScreenH);
}

// ---------------------------------------------------------------- headless
int run_headless(Machine& m, const Options& o) {
  std::vector<std::string> lines;
  if (!o.script.empty()) {
    std::ifstream f(o.script);
    if (!f) {
      fprintf(stderr, "perry16: cannot open script %s\n", o.script.c_str());
      return 2;
    }
    for (std::string l; std::getline(f, l);) lines.push_back(l);
  }
  auto frames_for = [](long ms) { return std::max(1L, ms * Machine::kFps / 1000); };
  int status = 0;
  for (size_t ln = 0; ln < lines.size(); ln++) {
    std::string line = lines[ln];
    size_t start = line.find_first_not_of(" \t");
    if (start == std::string::npos || line[start] == '#') continue;
    line = line.substr(start);
    std::string cmd = line.substr(0, line.find(' '));
    std::string arg = line.size() > cmd.size() ? line.substr(cmd.size() + 1) : "";
    bool runs = cmd == "wait" || cmd == "waitidle" || cmd == "type" || cmd == "key" || cmd == "mouse";
    if (runs && m.powered_off()) continue;  // machine is off: only inspection commands remain
    if (cmd == "wait") {
      for (long i = 0, n = frames_for(atol(arg.c_str())); i < n && !m.powered_off(); i++) run_frame_with_audio(m);
    } else if (cmd == "waitidle") {
      long n = frames_for(arg.empty() ? 5000 : atol(arg.c_str()));
      run_frame_with_audio(m);
      long i = 0;
      for (; i < n && !m.waiting_for_input() && !m.powered_off(); i++) run_frame_with_audio(m);
      if (i == n) {
        fprintf(stderr, "script:%zu: timeout waiting for the program to become idle\n", ln + 1);
        status = 4;
      }
    } else if (cmd == "type") {
      for (char c : unescape(arg)) {
        // never overflow the 32-key BIOS buffer: let the program catch up
        for (int i = 0; i < 1000 && m.keys_pending() >= 16 && !m.powered_off(); i++) run_frame_with_audio(m);
        m.key_press(key::from_ascii(c));
      }
    } else if (cmd == "key") {
      std::istringstream ss(arg);
      std::string name;
      int count = 1;
      ss >> name >> count;
      uint16_t k = key_by_name(name);
      if (!k) {
        fprintf(stderr, "script:%zu: unknown key %s\n", ln + 1, name.c_str());
        return 2;
      }
      for (int i = 0; i < std::max(1, count); i++) {
        m.key_press(k);
        // feed keys at a human-ish pace so programs that poll see each one
        run_frame_with_audio(m);
      }
    } else if (cmd == "mouse") {
      int x = 0, y = 0, b = 0;
      sscanf(arg.c_str(), "%d %d %d", &x, &y, &b);
      m.mouse_move(x, y);
      m.mouse_buttons(b);
      run_frame_with_audio(m);
      run_frame_with_audio(m);
    } else if (cmd == "expect" || cmd == "expectnot") {
      std::string txt = unescape(arg);
      bool found = m.text_screen().find(txt) != std::string::npos;
      if (found != (cmd == "expect")) {
        fprintf(stderr, "script:%zu: %s \"%s\" failed. Screen:\n%s", ln + 1, cmd.c_str(), txt.c_str(),
                m.text_screen().c_str());
        status = 3;
        break;
      }
    } else if (cmd == "expectmode") {
      int mode = int(strtol(arg.c_str(), nullptr, 0));
      if (m.video_mode() != mode) {
        fprintf(stderr, "script:%zu: video mode is 0x%02X, expected 0x%02X\n", ln + 1, m.video_mode(), mode);
        status = 3;
        break;
      }
    } else if (cmd == "expectpixel") {
      int x = 0, y = 0, c = 0;
      sscanf(arg.c_str(), "%d %d %d", &x, &y, &c);
      int got = m.framebuffer()[y * 320 + x];
      if (got != c) {
        fprintf(stderr, "script:%zu: pixel (%d,%d) is %d, expected %d\n", ln + 1, x, y, got, c);
        status = 3;
        break;
      }
    } else if (cmd == "screenshot") {
      if (!save_screenshot(m, arg)) fprintf(stderr, "script:%zu: cannot write %s\n", ln + 1, arg.c_str());
    } else if (cmd == "dump") {
      fputs(m.text_screen().c_str(), stdout);
    } else if (cmd == "quit") {
      break;
    } else {
      fprintf(stderr, "script:%zu: unknown command %s\n", ln + 1, cmd.c_str());
      return 2;
    }
  }
  if (lines.empty()) {  // no script: run until power off (or frame limit)
    for (long i = 0; !m.powered_off() && (o.max_frames < 0 || i < o.max_frames); i++) {
      if (m.waiting_for_input()) break;
      run_frame_with_audio(m);
    }
  }
  if (status == 0 && m.powered_off()) status = m.exit_code();
  if (!m.last_error().empty() && status == 0 && o.raw.empty()) fprintf(stderr, "%s\n", m.last_error().c_str());
  return status;
}

// ---------------------------------------------------------------- terminal
const char* cp437_utf8(uint8_t c) {
  switch (c) {
    case 0xB0: return "░"; case 0xB1: return "▒"; case 0xB2: return "▓";
    case 0xB3: return "│"; case 0xB4: return "┤"; case 0xBA: return "║";
    case 0xBB: return "╗"; case 0xBC: return "╝"; case 0xBF: return "┐";
    case 0xC0: return "└"; case 0xC1: return "┴"; case 0xC2: return "┬";
    case 0xC3: return "├"; case 0xC4: return "─"; case 0xC5: return "┼";
    case 0xC8: return "╚"; case 0xC9: return "╔"; case 0xCD: return "═";
    case 0xD9: return "┘"; case 0xDA: return "┌"; case 0xDB: return "█";
    case 0xDC: return "▄"; case 0xDD: return "▌"; case 0xDE: return "▐";
    case 0xDF: return "▀"; case 0xFA: return "·"; case 0xFE: return "■";
    case 0x10: return "►"; case 0x11: return "◄"; case 0x1E: return "▲";
    case 0x1F: return "▼"; case 0x07: return "•"; case 0x01: return "☺";
    case 0x0F: return "☼"; case 0x18: return "↑"; case 0x19: return "↓";
    case 0x1A: return "→"; case 0x1B: return "←";
    default: return nullptr;
  }
}

struct TermGuard {
  termios saved{};
  bool ok = false;
  TermGuard() {
    if (tcgetattr(0, &saved) == 0) {
      termios raw = saved;
      cfmakeraw(&raw);
      tcsetattr(0, TCSANOW, &raw);
      ok = true;
    }
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
    // alternate screen, hide cursor, SGR mouse tracking (any motion)
    fputs("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[2J", stdout);
    fflush(stdout);
  }
  ~TermGuard() {
    fputs("\x1b[?1003l\x1b[?1006l\x1b[0m\x1b[?25h\x1b[?1049l", stdout);
    fflush(stdout);
    if (ok) tcsetattr(0, TCSANOW, &saved);
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) & ~O_NONBLOCK);
  }
};

int run_terminal(Machine& m) {
  TermGuard guard;
  std::string pending;
  std::vector<uint32_t> px(Machine::kScreenW * Machine::kScreenH);
  auto frame_time = std::chrono::microseconds(1000000 / Machine::kFps);
  auto next = std::chrono::steady_clock::now();
  std::string last_out;
  int frame = 0;
  int mouse_btn = 0;
  while (!m.powered_off()) {
    // ---- input
    char buf[256];
    ssize_t n;
    while ((n = read(0, buf, sizeof buf)) > 0) pending.append(buf, size_t(n));
    while (!pending.empty()) {
      unsigned char c = uint8_t(pending[0]);
      if (c == 0x11) return 0;  // Ctrl+Q
      if (c != 0x1b) {
        if (c == '\r' || c == '\n') m.key_press(key::ENTER);
        else if (c == 0x7f || c == 8) m.key_press(key::BACKSPACE);
        else m.key_press(key::from_ascii(char(c)));
        pending.erase(0, 1);
        continue;
      }
      if (pending.size() == 1) {  // lone ESC
        m.key_press(key::ESC);
        pending.clear();
        break;
      }
      size_t end = 1;
      if (pending[1] == '[' || pending[1] == 'O') {
        end = 2;
        while (end < pending.size() && !(pending[end] >= 0x40 && pending[end] <= 0x7E)) end++;
        if (end >= pending.size()) break;  // incomplete sequence; wait for more
        end++;
      } else {
        m.key_press(key::ESC);
        pending.erase(0, 1);
        continue;
      }
      std::string seq = pending.substr(0, end);
      pending.erase(0, end);
      if (seq.rfind("\x1b[<", 0) == 0) {  // SGR mouse: ESC [ < b ; x ; y M|m
        int b = 0, x = 0, y = 0;
        sscanf(seq.c_str() + 3, "%d;%d;%d", &b, &x, &y);
        bool release = seq.back() == 'm';
        int gx, gy;
        if (m.video_mode() == 0x13) {
          winsize ws{};
          ioctl(1, TIOCGWINSZ, &ws);
          int cols = std::min<int>(ws.ws_col ? ws.ws_col : 80, 160);
          gx = (x - 1) * 320 / cols;
          gy = (y - 1) * 4;
        } else {
          gx = (x - 1) * 8;
          gy = (y - 1) * 8;
        }
        m.mouse_move(gx, gy);
        int btn = b & 3;
        if (b & 32) {  // motion
        } else if (release) {
          mouse_btn = 0;
        } else if (btn == 0) {
          mouse_btn = 1;
        } else if (btn == 2) {
          mouse_btn = 2;
        }
        m.mouse_buttons(mouse_btn);
        continue;
      }
      static const struct { const char* s; uint16_t k; } map[] = {
        {"\x1b[A", key::UP}, {"\x1b[B", key::DOWN}, {"\x1b[C", key::RIGHT}, {"\x1b[D", key::LEFT},
        {"\x1b[H", key::HOME}, {"\x1b[F", key::END}, {"\x1b[1~", key::HOME}, {"\x1b[4~", key::END},
        {"\x1b[5~", key::PGUP}, {"\x1b[6~", key::PGDN}, {"\x1b[3~", key::DEL}, {"\x1b[2~", key::INS},
        {"\x1bOP", key::F1}, {"\x1bOQ", 0x3C00}, {"\x1bOR", 0x3D00}, {"\x1bOS", 0x3E00},
        {"\x1b[15~", 0x3F00}, {"\x1b[17~", 0x4000}, {"\x1b[18~", 0x4100}, {"\x1b[19~", 0x4200},
        {"\x1b[20~", 0x4300}, {"\x1b[21~", 0x4400}, {"\x1bOH", key::HOME}, {"\x1bOF", key::END}};
      for (auto& e : map)
        if (seq == e.s) m.key_press(e.k);
    }
    // ---- emulate
    m.run_frame();
    if (m.opl.active()) {  // keep the synth state advancing even without audio output
      int16_t sink[44100 / Machine::kFps];
      m.audio(sink, 44100 / Machine::kFps);
    }
    // ---- render (35 fps)
    if (++frame % 2 == 0) {
      std::string out = "\x1b[H";
      const uint8_t* mem = m.memory();
      if (m.video_mode() == 0x13) {
        winsize ws{};
        ioctl(1, TIOCGWINSZ, &ws);
        int cols = std::min<int>(ws.ws_col ? ws.ws_col : 80, 160);
        const uint8_t* fb = m.framebuffer();
        const uint8_t* pal = m.palette();
        char tmp[64];
        for (int row = 0; row < 50; row++) {
          for (int col = 0; col < cols; col++) {
            int x = col * 320 / cols;
            const uint8_t* a = pal + fb[(row * 4) * 320 + x] * 3;
            const uint8_t* b = pal + fb[(row * 4 + 2) * 320 + x] * 3;
            snprintf(tmp, sizeof tmp, "\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm▀", a[0] * 4, a[1] * 4,
                     a[2] * 4, b[0] * 4, b[1] * 4, b[2] * 4);
            out += tmp;
          }
          out += "\x1b[0m\r\n";
        }
      } else {
        static const uint32_t cga[16] = {0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA,
                                         0xAA5500, 0xAAAAAA, 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
                                         0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF};
        int last_attr = -1;
        int cur_c = mem[mm::BDA_CUR_COL], cur_r = mem[mm::BDA_CUR_ROW];
        bool show_cur = mem[mm::BDA_CUR_SHOW];
        int mcol = m.mouse_x() / 8, mrow = m.mouse_y() / 8;
        char tmp[64];
        for (int row = 0; row < 25; row++) {
          for (int col = 0; col < 80; col++) {
            uint8_t ch = mem[mm::TEXT_VRAM + (row * 80 + col) * 2];
            int at = mem[mm::TEXT_VRAM + (row * 80 + col) * 2 + 1];
            if ((show_cur && row == cur_r && col == cur_c) || (m.mouse_visible() && row == mrow && col == mcol))
              at = ((at & 0x0F) << 4) | (at >> 4);  // inverse video for cursor / mouse
            if (at != last_attr) {
              uint32_t f = cga[at & 15], b = cga[at >> 4];
              snprintf(tmp, sizeof tmp, "\x1b[38;2;%u;%u;%um\x1b[48;2;%u;%u;%um", f >> 16, (f >> 8) & 255,
                       f & 255, b >> 16, (b >> 8) & 255, b & 255);
              out += tmp;
              last_attr = at;
            }
            const char* u = cp437_utf8(ch);
            if (u) out += u;
            else out += (ch >= 32 && ch < 127) ? char(ch) : ' ';
          }
          out += "\x1b[0m\r\n";
          last_attr = -1;
        }
      }
      if (out != last_out) {
        fwrite(out.data(), 1, out.size(), stdout);
        fflush(stdout);
        last_out = out;
      }
    }
    next += frame_time;
    std::this_thread::sleep_until(next);
    if (std::chrono::steady_clock::now() > next + frame_time * 10) next = std::chrono::steady_clock::now();
  }
  (void)px;
  return m.exit_code();
}

// ---------------------------------------------------------------- SDL2
#ifdef PERRY_SDL
uint16_t sdl_special_key(SDL_Keycode k) {
  switch (k) {
    case SDLK_RETURN: case SDLK_KP_ENTER: return key::ENTER;
    case SDLK_ESCAPE: return key::ESC;
    case SDLK_BACKSPACE: return key::BACKSPACE;
    case SDLK_TAB: return key::TAB;
    case SDLK_UP: return key::UP;
    case SDLK_DOWN: return key::DOWN;
    case SDLK_LEFT: return key::LEFT;
    case SDLK_RIGHT: return key::RIGHT;
    case SDLK_HOME: return key::HOME;
    case SDLK_END: return key::END;
    case SDLK_PAGEUP: return key::PGUP;
    case SDLK_PAGEDOWN: return key::PGDN;
    case SDLK_INSERT: return key::INS;
    case SDLK_DELETE: return key::DEL;
    default:
      if (k >= SDLK_F1 && k <= SDLK_F10) return uint16_t(key::F1 + ((k - SDLK_F1) << 8));
      return 0;
  }
}

int run_sdl(Machine& m) {
  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) != 0) {
    fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
    return 1;
  }
  SDL_Window* win = SDL_CreateWindow("PERRY-16", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                     Machine::kScreenW * 2, Machine::kScreenH * 2, SDL_WINDOW_RESIZABLE);
  SDL_Renderer* ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
  if (!ren) ren = SDL_CreateRenderer(win, -1, 0);
  SDL_RenderSetLogicalSize(ren, Machine::kScreenW, Machine::kScreenH);
  SDL_Texture* tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
                                       Machine::kScreenW, Machine::kScreenH);
  SDL_AudioSpec want{}, have{};
  want.freq = 44100;
  want.format = AUDIO_S16SYS;
  want.channels = 1;
  want.samples = 1024;
  SDL_AudioDeviceID audio = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
  if (audio) SDL_PauseAudioDevice(audio, 0);
  SDL_StartTextInput();

  std::vector<uint32_t> px(Machine::kScreenW * Machine::kScreenH);
  const int spf = 44100 / Machine::kFps;
  std::vector<int16_t> samples(spf);
  uint64_t freq = SDL_GetPerformanceFrequency(), next = SDL_GetPerformanceCounter();
  int buttons = 0;
  bool quit = false;
  while (!quit && !m.powered_off()) {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
      switch (e.type) {
        case SDL_QUIT: quit = true; break;
        case SDL_TEXTINPUT:
          for (const char* p = e.text.text; *p; p++)
            if (uint8_t(*p) < 128) m.key_press(key::from_ascii(*p));
          break;
        case SDL_KEYDOWN: {
          uint16_t k = sdl_special_key(e.key.keysym.sym);
          if (k) m.key_press(k);
          break;
        }
        case SDL_KEYUP: {
          uint16_t k = sdl_special_key(e.key.keysym.sym);
          if (k) m.key_release(uint8_t(k >> 8));
          break;
        }
        case SDL_MOUSEMOTION:
          if (m.video_mode() == 0x13) m.mouse_move(e.motion.x / 2, e.motion.y / 2);
          else m.mouse_move(e.motion.x, e.motion.y / 2);
          break;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP: {
          int bit = e.button.button == SDL_BUTTON_LEFT ? 1 : e.button.button == SDL_BUTTON_RIGHT ? 2 : 4;
          buttons = e.type == SDL_MOUSEBUTTONDOWN ? (buttons | bit) : (buttons & ~bit);
          m.mouse_buttons(buttons);
          break;
        }
        default: break;
      }
    }
    m.run_frame();
    m.audio(samples.data(), spf);
    if (audio && SDL_GetQueuedAudioSize(audio) < uint32_t(spf * 2 * 6))
      SDL_QueueAudio(audio, samples.data(), uint32_t(spf * 2));
    SDL_ShowCursor(m.mouse_visible() ? SDL_DISABLE : SDL_ENABLE);
    m.render(px.data());
    SDL_UpdateTexture(tex, nullptr, px.data(), Machine::kScreenW * 4);
    SDL_RenderClear(ren);
    SDL_RenderCopy(ren, tex, nullptr, nullptr);
    SDL_RenderPresent(ren);
    next += freq / Machine::kFps;
    uint64_t now = SDL_GetPerformanceCounter();
    if (next > now) SDL_Delay(uint32_t((next - now) * 1000 / freq));
    else if (now - next > freq / 4) next = now;
  }
  if (audio) SDL_CloseAudioDevice(audio);
  SDL_DestroyTexture(tex);
  SDL_DestroyRenderer(ren);
  SDL_DestroyWindow(win);
  SDL_Quit();
  return m.exit_code();
}
#endif

void usage() {
  puts("usage: perry16 [options] [disk.img]\n"
       "  --sdl | --term | --headless   choose frontend\n"
       "  --script FILE                 headless test script (see tests/scripts)\n"
       "  --boot NAME.PEX               first program to run (default COMMAND.PEX)\n"
       "  --raw FILE.bin [--org ADDR]   run a bare-metal binary (port 0xE9 -> stdout)\n"
       "  --mhz N                       emulated clock in MHz (default 8)\n"
       "  --frames N                    headless: stop after N frames\n"
       "  --wav FILE                    headless: record AdLib output\n"
       "  --trace                       trace every instruction to stderr");
}

}  // namespace

int main(int argc, char** argv) {
  Options o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) {
        fprintf(stderr, "perry16: %s needs an argument\n", a.c_str());
        exit(2);
      }
      return argv[++i];
    };
    if (a == "--headless") o.headless = true;
    else if (a == "--term") o.term = true;
    else if (a == "--sdl") o.sdl = true;
    else if (a == "--script") { o.script = next(); o.headless = true; }
    else if (a == "--boot") o.boot = next();
    else if (a == "--raw") o.raw = next();
    else if (a == "--org") o.org = uint16_t(strtol(next().c_str(), nullptr, 0));
    else if (a == "--mhz") o.mhz = uint32_t(std::max(1, std::min(4000, atoi(next().c_str()))));
    else if (a == "--frames") o.max_frames = atol(next().c_str());
    else if (a == "--wav") o.wav = next();
    else if (a == "--trace") o.trace = true;
    else if (a == "-h" || a == "--help") { usage(); return 0; }
    else if (!a.empty() && a[0] == '-') { usage(); return 2; }
    else o.disk = a;
  }

  Machine m;
  m.clock_hz = o.mhz * 1000000u;
  m.trace = o.trace;
  std::string err;
  if (!o.raw.empty()) {
    std::ifstream f(o.raw, std::ios::binary);
    if (!f) {
      fprintf(stderr, "perry16: cannot open %s\n", o.raw.c_str());
      return 2;
    }
    std::vector<uint8_t> bin((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    m.debug_sink = [](char c) { fputc(c, stdout); };
    if (!m.boot_raw(bin, o.org, err)) {
      fprintf(stderr, "perry16: %s\n", err.c_str());
      return 2;
    }
    if (o.max_frames < 0) o.max_frames = 70 * 60;
    o.headless = true;
  } else {
    if (!m.mount(o.disk, err)) {
      fprintf(stderr, "perry16: %s\n", err.c_str());
      return 2;
    }
    if (!m.boot(o.boot, err)) fprintf(stderr, "perry16: boot failed: %s\n", err.c_str());
  }

  int rc;
  if (o.headless) {
    rc = run_headless(m, o);
  } else if (o.term) {
    rc = run_terminal(m);
  } else {
#ifdef PERRY_SDL
    rc = run_sdl(m);
#else
    if (o.sdl) fprintf(stderr, "perry16: built without SDL2, using the terminal frontend\n");
    rc = run_terminal(m);
#endif
  }
  if (!o.wav.empty()) {
    write_wav(o.wav, g_wav, 44100);
    fprintf(stderr, "perry16: wrote %zu audio samples to %s\n", g_wav.size(), o.wav.c_str());
  }
  return rc;
}
