# PERRY-16 build
#   make            emulator + all guest software + disk image
#   make test       run the full test-suite (CPU, assembler, OS, apps, RTL)
#   make run        boot PERRY-DOS (SDL window if available, else terminal)
#   make term       boot PERRY-DOS in the terminal frontend

CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
PYTHON   ?= python3
BUILD    := build

SDL_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL_LIBS   := $(shell pkg-config --libs sdl2 2>/dev/null)
ifneq ($(SDL_LIBS),)
  CXXFLAGS += -DPERRY_SDL $(SDL_CFLAGS)
  LDLIBS   += $(SDL_LIBS)
endif

EMU_SRC := emu/cpu.cpp emu/machine.cpp emu/bios.cpp emu/pfs.cpp emu/opl2.cpp emu/main.cpp
EMU_HDR := $(wildcard emu/*.h)
EMU     := $(BUILD)/perry16

PASM    := $(PYTHON) tools/pasm.py
INC     := $(wildcard include/*.inc include/lib/*.inc)

PROGRAMS := $(BUILD)/COMMAND.PEX $(BUILD)/WORD.PEX $(BUILD)/EXCEL.PEX \
            $(BUILD)/PAINT.PEX $(BUILD)/RAYCAST.PEX $(BUILD)/HELLO.PEX
DISK_FILES := $(wildcard disk/*)

.PHONY: all emu programs disk test run term clean rtl-test screenshots

all: emu programs disk

emu: $(EMU)

$(EMU): $(EMU_SRC) $(EMU_HDR) | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ $(EMU_SRC) $(LDLIBS)

$(BUILD):
	mkdir -p $(BUILD)

emu/font8x8.h: tools/genfont.py
	$(PYTHON) tools/genfont.py

# one rule per program: build/NAME.PEX from its source (+ listing)
define PEX_RULE
$(BUILD)/$(1).PEX: $(2) $(INC) $(3) | $(BUILD)
	$(PASM) $(2) -o $$@ -l $(BUILD)/$(1).LST
endef
$(eval $(call PEX_RULE,COMMAND,os/command.asm))
$(eval $(call PEX_RULE,WORD,apps/word.asm))
$(eval $(call PEX_RULE,EXCEL,apps/excel.asm))
$(eval $(call PEX_RULE,PAINT,apps/paint.asm))
$(eval $(call PEX_RULE,HELLO,apps/hello.asm))
$(eval $(call PEX_RULE,RAYCAST,games/raycast.asm,games/trig.inc))

games/trig.inc: tools/gentables.py
	$(PYTHON) tools/gentables.py

$(BUILD)/MAZE.WAD: tools/mkwad.py | $(BUILD)
	$(PYTHON) tools/mkwad.py $@

programs: $(PROGRAMS)

disk: $(BUILD)/disk.img

$(BUILD)/disk.img: $(PROGRAMS) $(BUILD)/MAZE.WAD $(DISK_FILES) tools/mkdisk.py
	$(PYTHON) tools/mkdisk.py $@ $(PROGRAMS) $(BUILD)/MAZE.WAD $(DISK_FILES)

test: all
	$(PYTHON) tests/run_tests.py

rtl-test:
	$(PYTHON) tests/run_tests.py --only rtl

run: all
	$(EMU) $(BUILD)/disk.img

term: all
	$(EMU) --term $(BUILD)/disk.img

clean:
	rm -rf $(BUILD)

# regenerate the documentation screenshots
screenshots: all
	cp $(BUILD)/disk.img $(BUILD)/shots.img
	$(EMU) --script tests/screenshots.txt $(BUILD)/shots.img
	$(PYTHON) tools/pngopt.py docs/img/*.png
