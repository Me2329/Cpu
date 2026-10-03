// PFS - the PERRY File System used by disk.img.
//
// Layout (512-byte sectors, little endian):
//   sector 0            superblock  "PFS1", total_sectors, dir_start,
//                                   dir_sectors, data_start, label[16]
//   sectors 1..4        directory: 64 entries x 32 bytes
//   sectors 5..         file data, each file stored contiguously
//
// Directory entry (32 bytes):
//   +0  name[13]   8.3 name, upper case, NUL terminated
//   +13 attr       bit0 = in use, bit1 = read only, bit2 = system
//   +14 u16        reserved
//   +16 u32        start sector
//   +20 u32        size in bytes
//   +24 u32        allocated sectors
//   +28 u32        modification time (unix seconds)
//
// The same format is produced by tools/mkdisk.py.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace p16 {

struct PfsEntry {
  std::string name;
  uint8_t attr = 0;
  uint32_t start = 0, size = 0, alloc = 0, mtime = 0;
};

class Pfs {
 public:
  static constexpr int kSector = 512;
  static constexpr int kMaxEntries = 64;
  static constexpr uint8_t kAttrUsed = 1, kAttrReadOnly = 2, kAttrSystem = 4;

  bool mount(const std::string& path, std::string& err);
  bool mounted() const { return !img_.empty(); }
  void flush();  // write the image back to the host file if dirty

  int find(const std::string& name) const;           // entry index or -1
  int create(const std::string& name);               // truncates existing; -1 = full / invalid
  bool remove(const std::string& name);
  const PfsEntry* entry(int idx) const;
  int count_slots() const { return kMaxEntries; }

  // File content access (index from find/create)
  uint32_t read(int idx, uint32_t pos, uint8_t* dst, uint32_t n) const;
  uint32_t write(int idx, uint32_t pos, const uint8_t* src, uint32_t n);  // grows file
  uint32_t free_bytes() const;
  uint32_t total_bytes() const { return total_sectors_ * kSector; }
  std::string label() const { return label_; }

  static bool valid_name(const std::string& name);
  static std::string normalize(const std::string& name);

 private:
  std::string path_;
  std::vector<uint8_t> img_;
  std::vector<PfsEntry> dir_;
  uint32_t total_sectors_ = 0, dir_start_ = 0, dir_sectors_ = 0, data_start_ = 0;
  std::string label_;
  bool dirty_ = false;

  void load_dir();
  void store_entry(int idx);
  uint32_t data_end() const;  // first sector after all allocated data
  bool grow(int idx, uint32_t new_size);
};

}  // namespace p16
