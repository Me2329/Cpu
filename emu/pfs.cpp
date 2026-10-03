#include "pfs.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <ctime>
#include <fstream>

namespace p16 {

namespace {
uint32_t rd32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24); }
void wr32(uint8_t* p, uint32_t v) {
  p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = v >> 24;
}
}  // namespace

bool Pfs::mount(const std::string& path, std::string& err) {
  std::ifstream f(path, std::ios::binary);
  if (!f) {
    err = "cannot open disk image " + path;
    return false;
  }
  img_.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
  if (img_.size() < kSector * 8 || memcmp(img_.data(), "PFS1", 4) != 0) {
    err = path + " is not a PFS disk image (run tools/mkdisk.py)";
    img_.clear();
    return false;
  }
  path_ = path;
  total_sectors_ = rd32(&img_[4]);
  dir_start_ = rd32(&img_[8]);
  dir_sectors_ = rd32(&img_[12]);
  data_start_ = rd32(&img_[16]);
  label_.assign(reinterpret_cast<const char*>(&img_[20]), strnlen(reinterpret_cast<const char*>(&img_[20]), 16));
  if (img_.size() < size_t(total_sectors_) * kSector) img_.resize(size_t(total_sectors_) * kSector);
  load_dir();
  return true;
}

void Pfs::load_dir() {
  dir_.assign(kMaxEntries, PfsEntry());
  for (int i = 0; i < kMaxEntries; i++) {
    const uint8_t* e = &img_[dir_start_ * kSector + i * 32];
    PfsEntry& d = dir_[i];
    d.attr = e[13];
    if (!(d.attr & kAttrUsed)) continue;
    d.name.assign(reinterpret_cast<const char*>(e), strnlen(reinterpret_cast<const char*>(e), 13));
    d.start = rd32(e + 16);
    d.size = rd32(e + 20);
    d.alloc = rd32(e + 24);
    d.mtime = rd32(e + 28);
  }
}

void Pfs::store_entry(int idx) {
  uint8_t* e = &img_[dir_start_ * kSector + idx * 32];
  memset(e, 0, 32);
  const PfsEntry& d = dir_[idx];
  if (d.attr & kAttrUsed) {
    memcpy(e, d.name.c_str(), std::min<size_t>(d.name.size(), 12));
    e[13] = d.attr;
    wr32(e + 16, d.start);
    wr32(e + 20, d.size);
    wr32(e + 24, d.alloc);
    wr32(e + 28, d.mtime);
  }
  dirty_ = true;
}

void Pfs::flush() {
  if (!dirty_ || path_.empty()) return;
  std::ofstream f(path_, std::ios::binary | std::ios::trunc);
  f.write(reinterpret_cast<const char*>(img_.data()), std::streamsize(img_.size()));
  dirty_ = false;
}

std::string Pfs::normalize(const std::string& name) {
  std::string s;
  for (char c : name) {
    if (c == ' ' || c == '\0') break;
    s += char(toupper(uint8_t(c)));
  }
  // accept "A:\NAME.EXT" / "\NAME.EXT"
  if (s.size() >= 2 && s[1] == ':') s = s.substr(2);
  while (!s.empty() && (s[0] == '\\' || s[0] == '/')) s = s.substr(1);
  return s;
}

bool Pfs::valid_name(const std::string& n) {
  if (n.empty() || n.size() > 12) return false;
  size_t dot = n.find('.');
  std::string base = n.substr(0, dot), ext = dot == std::string::npos ? "" : n.substr(dot + 1);
  if (base.empty() || base.size() > 8 || ext.size() > 3 || ext.find('.') != std::string::npos) return false;
  for (char c : n)
    if (!(isalnum(uint8_t(c)) || c == '.' || c == '_' || c == '-' || c == '$' || c == '~')) return false;
  return true;
}

int Pfs::find(const std::string& raw) const {
  std::string name = normalize(raw);
  for (int i = 0; i < kMaxEntries; i++)
    if ((dir_[i].attr & kAttrUsed) && dir_[i].name == name) return i;
  return -1;
}

const PfsEntry* Pfs::entry(int idx) const {
  if (idx < 0 || idx >= kMaxEntries || !(dir_[idx].attr & kAttrUsed)) return nullptr;
  return &dir_[idx];
}

uint32_t Pfs::data_end() const {
  uint32_t end = data_start_;
  for (const auto& d : dir_)
    if (d.attr & kAttrUsed) end = std::max(end, d.start + d.alloc);
  return end;
}

uint32_t Pfs::free_bytes() const {
  return (total_sectors_ - data_end()) * kSector;
}

int Pfs::create(const std::string& raw) {
  std::string name = normalize(raw);
  if (!valid_name(name)) return -1;
  int idx = find(name);
  if (idx >= 0) {
    if (dir_[idx].attr & kAttrReadOnly) return -1;
    dir_[idx].size = 0;
    dir_[idx].mtime = uint32_t(time(nullptr));
    store_entry(idx);
    return idx;
  }
  for (int i = 0; i < kMaxEntries; i++) {
    if (!(dir_[i].attr & kAttrUsed)) {
      dir_[i] = PfsEntry();
      dir_[i].name = name;
      dir_[i].attr = kAttrUsed;
      dir_[i].start = data_end();
      dir_[i].mtime = uint32_t(time(nullptr));
      store_entry(i);
      return i;
    }
  }
  return -1;
}

bool Pfs::remove(const std::string& raw) {
  int idx = find(raw);
  if (idx < 0 || (dir_[idx].attr & (kAttrReadOnly | kAttrSystem))) return false;
  dir_[idx] = PfsEntry();
  store_entry(idx);
  return true;
}

uint32_t Pfs::read(int idx, uint32_t pos, uint8_t* dst, uint32_t n) const {
  const PfsEntry* e = entry(idx);
  if (!e || pos >= e->size) return 0;
  n = std::min(n, e->size - pos);
  memcpy(dst, &img_[size_t(e->start) * kSector + pos], n);
  return n;
}

// Make sure entry idx has room for new_size bytes. Files are contiguous:
// grow in place when the file is last on disk, otherwise move it to the end.
bool Pfs::grow(int idx, uint32_t new_size) {
  PfsEntry& e = dir_[idx];
  uint32_t need = (new_size + kSector - 1) / kSector;
  if (need <= e.alloc) return true;
  uint32_t end = data_end();
  if (e.start + e.alloc == end) {
    if (e.start + need > total_sectors_) return false;
    e.alloc = need;
    return true;
  }
  if (end + need > total_sectors_) return false;
  memmove(&img_[size_t(end) * kSector], &img_[size_t(e.start) * kSector], e.size);
  e.start = end;
  e.alloc = need;
  return true;
}

uint32_t Pfs::write(int idx, uint32_t pos, const uint8_t* src, uint32_t n) {
  if (!entry(idx) || (dir_[idx].attr & kAttrReadOnly)) return 0;
  PfsEntry& e = dir_[idx];
  uint32_t end = pos + n;
  if (!grow(idx, end)) {
    // write as much as fits
    uint32_t room = (total_sectors_ - e.start) * kSector;
    if (pos >= room) return 0;
    n = room - pos;
    end = pos + n;
    if (!grow(idx, end)) return 0;
  }
  if (pos > e.size) memset(&img_[size_t(e.start) * kSector + e.size], 0, pos - e.size);
  memcpy(&img_[size_t(e.start) * kSector + pos], src, n);
  e.size = std::max(e.size, end);
  e.mtime = uint32_t(time(nullptr));
  store_entry(idx);
  return n;
}

}  // namespace p16
