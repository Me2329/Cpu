; perry.inc - PERRY-16 system definitions (memory map, ports, services)
; Included by every guest program:   %include "perry.inc"

; ------------------------------------------------------------ memory map
IVT             EQU 0x0000      ; 256 vectors x 4 bytes
BDA             EQU 0x0400      ; BIOS data area
BDA_TICKS       EQU 0x0400      ; u32: 70 Hz tick counter
BDA_CUR_COL     EQU 0x0404      ; u8
BDA_CUR_ROW     EQU 0x0405      ; u8
BDA_VMODE       EQU 0x0406      ; u8: 0x03 text / 0x13 graphics
BDA_ATTR        EQU 0x0407      ; u8: default text attribute for DOS output
BDA_CUR_SHOW    EQU 0x0408      ; u8: text cursor visible
PSP_CMDLINE     EQU 0x0600      ; ASCIIZ command line of the running program
DTA_DEFAULT     EQU 0x0680      ; default disk transfer area
RAM_START       EQU 0x1000      ; system RAM (shell lives here)
TPA_START       EQU 0x3000      ; transient program area (applications)
RAM_END         EQU 0xA000
VGA_WINDOW      EQU 0xA000      ; 6 KB window into the 320x200 framebuffer
VGA_BANK_SIZE   EQU 0x1000      ; bank granularity (4 KB)
TEXT_VRAM       EQU 0xB800      ; 80x25 x (char, attr)
UPPER_RAM       EQU 0xC800      ; 10 KB free RAM (0xC800-0xEFFF)
UPPER_RAM_END   EQU 0xF000
ROM_FONT        EQU 0xF800      ; 8x8 font, 8 bytes per glyph, bit7 = left

; ------------------------------------------------------------ I/O ports
PORT_PIT        EQU 0x0040      ; free running counter (read)
PORT_KBD_DATA   EQU 0x0060      ; last scancode, bit7 = released
PORT_KBD_STATUS EQU 0x0064      ; bit0 = key waiting
PORT_DEBUG      EQU 0x00E9      ; debug console character out
PORT_POWER      EQU 0x00F4      ; power off (value = exit code)
PORT_ADLIB_IDX  EQU 0x0388      ; AdLib OPL2 register index / status
PORT_ADLIB_DATA EQU 0x0389      ; AdLib OPL2 register data
PORT_DAC_RINDEX EQU 0x03C7
PORT_DAC_WINDEX EQU 0x03C8      ; palette index for writing
PORT_DAC_DATA   EQU 0x03C9      ; R,G,B (6 bit each)
PORT_VGA_BANK   EQU 0x03CD      ; framebuffer bank at 0xA000 (offset = bank*4096)
PORT_VGA_STATUS EQU 0x03DA      ; bit3 = vertical retrace

; ------------------------------------------------------------ interrupts
INT_VIDEO       EQU 0x10
INT_KEYBOARD    EQU 0x16
INT_EXIT        EQU 0x20
INT_DOS         EQU 0x21
INT_MOUSE       EQU 0x33

; INT 21h functions (in AH)
DOS_GETCHE      EQU 0x01
DOS_PUTC        EQU 0x02
DOS_GETCH       EQU 0x07
DOS_PUTS        EQU 0x09        ; DX = ASCIIZ string
DOS_GETLINE     EQU 0x0A        ; DX = [max][count][chars...]
DOS_KBHIT       EQU 0x0B
DOS_SETDTA      EQU 0x1A
DOS_SETVEC      EQU 0x25
DOS_DATE        EQU 0x2A
DOS_TIME        EQU 0x2C
DOS_VERSION     EQU 0x30
DOS_GETVEC      EQU 0x35
DOS_DISKFREE    EQU 0x36
DOS_CREATE      EQU 0x3C
DOS_OPEN        EQU 0x3D
DOS_CLOSE       EQU 0x3E
DOS_READ        EQU 0x3F
DOS_WRITE       EQU 0x40
DOS_DELETE      EQU 0x41
DOS_SEEK        EQU 0x42
DOS_EXEC        EQU 0x4B
DOS_EXIT        EQU 0x4C
DOS_RETCODE     EQU 0x4D
DOS_FINDFIRST   EQU 0x4E
DOS_FINDNEXT    EQU 0x4F
DOS_MEMINFO     EQU 0x58
DOS_CMDLINE     EQU 0x62

; DTA layout (find first / next)
DTA_ATTR        EQU 0
DTA_SIZE_LO     EQU 2
DTA_SIZE_HI     EQU 4
DTA_NAME        EQU 8

; ------------------------------------------------------------ keys
; INT 16h / INT 21h return AX = (scancode << 8) | ascii
KEY_ESC         EQU 0x011B
KEY_ENTER       EQU 0x1C0D
KEY_BACKSPACE   EQU 0x0E08
KEY_TAB         EQU 0x0F09
KEY_UP          EQU 0x4800
KEY_DOWN        EQU 0x5000
KEY_LEFT        EQU 0x4B00
KEY_RIGHT       EQU 0x4D00
KEY_HOME        EQU 0x4700
KEY_END         EQU 0x4F00
KEY_PGUP        EQU 0x4900
KEY_PGDN        EQU 0x5100
KEY_DEL         EQU 0x5300
KEY_F1          EQU 0x3B00
KEY_F2          EQU 0x3C00
KEY_F3          EQU 0x3D00
KEY_F4          EQU 0x3E00
KEY_F5          EQU 0x3F00
KEY_F10         EQU 0x4400
SC_ESC          EQU 0x01
SC_UP           EQU 0x48
SC_DOWN         EQU 0x50
SC_LEFT         EQU 0x4B
SC_RIGHT        EQU 0x4D

; ------------------------------------------------------------ colours
BLACK           EQU 0
BLUE            EQU 1
GREEN           EQU 2
CYAN            EQU 3
RED             EQU 4
MAGENTA         EQU 5
BROWN           EQU 6
LIGHTGRAY       EQU 7
DARKGRAY        EQU 8
LIGHTBLUE       EQU 9
LIGHTGREEN      EQU 10
LIGHTCYAN       EQU 11
LIGHTRED        EQU 12
LIGHTMAGENTA    EQU 13
YELLOW          EQU 14
WHITE           EQU 15
