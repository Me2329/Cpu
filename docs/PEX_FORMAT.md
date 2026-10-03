# .PEX executables, the loader and the PFS disk format

## 1. The .PEX header

A `.PEX` ("PERRY EXecutable") file is a 32-byte header followed by the
code bytes and the initialised data bytes. All fields are little endian.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | `magic` | `"PEX\0"` |
| 4 | 1 | `ver_major` | 1 |
| 5 | 1 | `ver_minor` | 0 |
| 6 | 2 | `flags` | bit 0: uses graphics (informational, set with `PEXFLAGS 1`) |
| 8 | 2 | `load_addr` | where the image is copied, inside system RAM `1000h-9FFFh` |
| 10 | 2 | `entry` | absolute entry point, must lie inside the code |
| 12 | 2 | `code_size` | bytes of code after the header |
| 14 | 2 | `data_size` | bytes of initialised data after the code |
| 16 | 2 | `bss_size` | zero-filled bytes after the data (not stored in the file) |
| 18 | 2 | `stack_size` | stack placed after the BSS |
| 20 | 2 | `checksum` | 16-bit sum of all code + data bytes |
| 22 | 10 | reserved | zero |

In memory the image is laid out contiguously:

```
load_addr                                                     SP (initial)
   |  code_size  |  data_size  |   bss_size   |   stack_size   |
   +-------------+-------------+--------------+----------------+
   | code        | data        | zeros        | stack (grows <-)|
```

The assembler produces this directly: `ORG` sets `load_addr`, `ENTRY`
sets `entry`, `STACK` sets `stack_size`, and the `.code` / `.data` /
`.bss` sections give the three sizes. `pasm` refuses to build an image
whose end (stack included) passes `A000h`.

Programs are position-dependent (absolute addresses), like DOS `.COM`
files. Convention: the shell is linked at `1000h` (`COMMAND.PEX`,
resident) and applications at `3000h` (the TPA).

## 2. The loader (`Machine::exec`, `emu/machine.cpp`, abridged)

```cpp
std::string Machine::exec(const std::string& raw_name, const std::string& args, bool as_child) {
  std::string name = Pfs::normalize(raw_name);          // "a:\word" -> "WORD"
  int idx = fs.find(name);
  if (idx < 0 && name.find('.') == std::string::npos) { // WORD -> WORD.PEX
    name += ".PEX";
    idx = fs.find(name);
  }
  if (idx < 0) return "file not found";
  std::vector<uint8_t> file(fs.entry(idx)->size);       // 1. read the file from disk.img
  fs.read(idx, 0, file.data(), file.size());
  PexImage img;
  std::string err = pex_parse(file, img);               // 2. magic, version, sizes,
  if (!err.empty()) return "invalid executable: " + err;//    checksum, memory bounds
  const PexHeader& h = img.hdr;
  for (const auto& p : procs_)                          // 3. never overwrite a suspended parent
    if (h.load_addr < p.hi && img.image_end() > p.lo)
      return "not enough memory (image overlaps " + p.name + ")";
  Process proc{name, h.load_addr, img.image_end(), as_child};
  if (as_child) proc.parent = cpu.save();               // 4. parent context (inside its INT 21h)
  memcpy(&mem_[h.load_addr], img.payload, h.code_size + h.data_size);       // 5. code + data
  memset(&mem_[h.load_addr + h.code_size + h.data_size], 0, h.bss_size + h.stack_size);
  memcpy(&mem_[mm::PSP_CMDLINE], args.c_str(), args.size() + 1);           // 6. arguments
  procs_.push_back(proc);
  cpu.reset(h.entry);                                   // 7. PC = entry, SP = top of image,
  cpu.r[SP] = uint16_t(proc.hi);                        //    IF = 1 - the CPU loop continues
  cpu.flags = F_IF;                                     //    with the new program
  return "";
}
```

`pex_parse` (in `emu/pex.h`) validates the header: magic, version,
payload length, checksum, `load_addr >= 1000h`, image end `<= A000h`,
entry inside the code.

### Process lifetime

* **Boot:** `Machine::boot("COMMAND.PEX")` loads the shell with no parent.
* **EXEC (INT 21h AH=4Bh):** the shell's CPU context is captured *inside*
  its `INT 21h` (PC points at the `IRET` of the firmware stub, the stack
  holds the shell's return frame). The child starts immediately.
* **Exit (INT 21h AH=4Ch):** files left open are closed, the parent
  context is restored, `AX` = exit code and CF = 0 are written into the
  parent's saved frame, and the stub's `IRET` returns into the shell –
  exactly like DOS's `EXEC`.
* When the first process exits, the machine powers off.
* Faults (divide error, invalid opcode) print a message and terminate the
  current program with exit code 255.

## 3. PFS – the disk.img file system

`disk.img` is a flat image of 512-byte sectors (default 4 MB), built by
`tools/mkdisk.py` and mounted by `emu/pfs.cpp`.

| Sector | Content |
|---|---|
| 0 | superblock: `"PFS1"`, u32 total sectors, u32 directory start (1), u32 directory sectors (4), u32 data start (5), 16-byte volume label |
| 1–4 | directory: 64 entries × 32 bytes |
| 5… | file data, every file contiguous |

Directory entry:

| Offset | Size | Field |
|---|---|---|
| 0 | 13 | 8.3 name, upper case, NUL terminated |
| 13 | 1 | attributes: bit 0 used, bit 1 read-only, bit 2 system |
| 14 | 2 | reserved |
| 16 | 4 | start sector |
| 20 | 4 | size in bytes |
| 24 | 4 | allocated sectors |
| 28 | 4 | modification time (unix) |

Allocation is contiguous: a growing file is extended in place when it is
the last file on the disk, otherwise it is moved to the end. Freed space is
not compacted (rebuild the image with `mkdisk.py` to reclaim it). Writes
are kept in memory and flushed to the host file on close / exit, so files
saved by WORD/EXCEL/PAINT persist between emulator runs.

Tools:

```sh
python3 tools/mkdisk.py build/disk.img build/*.PEX disk/*   # build
python3 tools/mkdisk.py --list build/disk.img               # list
python3 tools/mkdisk.py build/disk.img --extract LETTER.TXT # copy a file out
```
