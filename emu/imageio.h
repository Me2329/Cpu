// Tiny dependency-free PNG / PPM / WAV writers used for screenshots and
// audio capture in headless mode.
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace p16 {

inline uint32_t crc32(const uint8_t* d, size_t n, uint32_t c = 0) {
  static uint32_t table[256];
  static bool init = false;
  if (!init) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t v = i;
      for (int k = 0; k < 8; k++) v = (v & 1) ? 0xEDB88320u ^ (v >> 1) : v >> 1;
      table[i] = v;
    }
    init = true;
  }
  c ^= 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) c = table[(c ^ d[i]) & 0xFF] ^ (c >> 8);
  return c ^ 0xFFFFFFFFu;
}

// Writes an RGB PNG using uncompressed ("stored") deflate blocks.
inline bool write_png(const std::string& path, const uint32_t* argb, int w, int h) {
  std::vector<uint8_t> raw;
  raw.reserve(size_t(h) * (w * 3 + 1));
  for (int y = 0; y < h; y++) {
    raw.push_back(0);  // filter: none
    for (int x = 0; x < w; x++) {
      uint32_t p = argb[y * w + x];
      raw.push_back((p >> 16) & 0xFF);
      raw.push_back((p >> 8) & 0xFF);
      raw.push_back(p & 0xFF);
    }
  }
  std::vector<uint8_t> z = {0x78, 0x01};
  size_t pos = 0;
  while (pos < raw.size() || raw.empty()) {
    size_t n = std::min<size_t>(65535, raw.size() - pos);
    bool last = pos + n == raw.size();
    z.push_back(last ? 1 : 0);
    z.push_back(n & 0xFF);
    z.push_back(n >> 8);
    z.push_back(~n & 0xFF);
    z.push_back((~n >> 8) & 0xFF);
    z.insert(z.end(), raw.begin() + long(pos), raw.begin() + long(pos + n));
    pos += n;
    if (last) break;
  }
  uint32_t a = 1, b = 0;
  for (uint8_t v : raw) {
    a = (a + v) % 65521;
    b = (b + a) % 65521;
  }
  uint32_t adler = (b << 16) | a;
  for (int i = 3; i >= 0; i--) z.push_back((adler >> (i * 8)) & 0xFF);

  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return false;
  auto be32 = [&](uint32_t v) {
    uint8_t o[4] = {uint8_t(v >> 24), uint8_t(v >> 16), uint8_t(v >> 8), uint8_t(v)};
    fwrite(o, 1, 4, f);
  };
  auto chunk = [&](const char* type, const std::vector<uint8_t>& data) {
    be32(uint32_t(data.size()));
    std::vector<uint8_t> td(type, type + 4);
    td.insert(td.end(), data.begin(), data.end());
    fwrite(td.data(), 1, td.size(), f);
    be32(crc32(td.data(), td.size()));
  };
  static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
  fwrite(sig, 1, 8, f);
  std::vector<uint8_t> ihdr = {uint8_t(w >> 24), uint8_t(w >> 16), uint8_t(w >> 8), uint8_t(w),
                               uint8_t(h >> 24), uint8_t(h >> 16), uint8_t(h >> 8), uint8_t(h),
                               8, 2, 0, 0, 0};
  chunk("IHDR", ihdr);
  chunk("IDAT", z);
  chunk("IEND", {});
  fclose(f);
  return true;
}

inline bool write_ppm(const std::string& path, const uint32_t* argb, int w, int h) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return false;
  fprintf(f, "P6\n%d %d\n255\n", w, h);
  for (int i = 0; i < w * h; i++) {
    uint8_t px[3] = {uint8_t(argb[i] >> 16), uint8_t(argb[i] >> 8), uint8_t(argb[i])};
    fwrite(px, 1, 3, f);
  }
  fclose(f);
  return true;
}

inline bool write_wav(const std::string& path, const std::vector<int16_t>& s, int rate) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return false;
  auto le32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
  auto le16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
  uint32_t bytes = uint32_t(s.size() * 2);
  fwrite("RIFF", 1, 4, f); le32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
  le32(16); le16(1); le16(1); le32(uint32_t(rate)); le32(uint32_t(rate * 2)); le16(2); le16(16);
  fwrite("data", 1, 4, f); le32(bytes);
  fwrite(s.data(), 2, s.size(), f);
  fclose(f);
  return true;
}

}  // namespace p16
