// .PEX - PERRY EXecutable format.
//
//   offset size  field
//   0      4     magic        "PEX\0"
//   4      1     ver_major    1
//   5      1     ver_minor    0
//   6      2     flags        bit0 = uses graphics mode (informational)
//   8      2     load_addr    where code is copied (inside 0x1000-0x9FFF)
//   10     2     entry        absolute entry point address
//   12     2     code_size    bytes of code following the header
//   14     2     data_size    bytes of initialised data following the code
//   16     2     bss_size     zero-filled bytes after data
//   18     2     stack_size   stack placed after BSS; SP = top of it
//   20     2     checksum     16-bit sum of all code+data bytes
//   22     10    reserved     zero
//   32     ...   code bytes, then data bytes
//
// In memory:  load_addr: [code][data][bss][stack]^SP
#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace p16 {

struct PexHeader {
  char magic[4];
  uint8_t ver_major, ver_minor;
  uint16_t flags, load_addr, entry, code_size, data_size, bss_size, stack_size, checksum;
  uint8_t reserved[10];
};
static_assert(sizeof(PexHeader) == 32, "PEX header must be 32 bytes");

struct PexImage {
  PexHeader hdr;
  const uint8_t* payload;  // code followed by data
  uint32_t image_end() const {  // first address after the stack
    return uint32_t(hdr.load_addr) + hdr.code_size + hdr.data_size + hdr.bss_size + hdr.stack_size;
  }
};

// Validates a .PEX file held in memory. Returns an empty string on success.
inline std::string pex_parse(const std::vector<uint8_t>& file, PexImage& out) {
  if (file.size() < sizeof(PexHeader)) return "file too small";
  memcpy(&out.hdr, file.data(), sizeof(PexHeader));  // host is little endian
  const PexHeader& h = out.hdr;
  if (memcmp(h.magic, "PEX\0", 4) != 0) return "bad magic (not a PEX file)";
  if (h.ver_major != 1) return "unsupported PEX version";
  size_t payload = size_t(h.code_size) + h.data_size;
  if (file.size() < sizeof(PexHeader) + payload) return "truncated image";
  out.payload = file.data() + sizeof(PexHeader);
  uint16_t sum = 0;
  for (size_t i = 0; i < payload; i++) sum = uint16_t(sum + out.payload[i]);
  if (sum != h.checksum) return "checksum mismatch";
  if (h.load_addr < 0x1000 || out.image_end() > 0xA000) return "image outside system RAM 0x1000-0x9FFF";
  if (h.entry < h.load_addr || h.entry >= h.load_addr + h.code_size) return "entry point outside code";
  return "";
}

}  // namespace p16
