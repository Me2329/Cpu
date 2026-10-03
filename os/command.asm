; COMMAND.PEX - PERRY-DOS 1.0 command interpreter and file explorer.
;
; Resident at 0x1000-0x2FFF; applications are loaded at 0x3000 (TPA) by
; INT 21h AH=4Bh (EXEC) and return here when they call AH=4Ch.
;
; Commands: DIR [pattern]  RUN file [args]  TYPE file  DEL file  CLS  MEM
;           VER  DATE  TIME  ECHO text  EXPLORER (EXP)  HELP  EXIT
; Typing the name of a .PEX (with or without extension) runs it; typing
; the name of a .TXT/.XLS/.WAD/.IMG opens it in its associated program.
        ORG 0x1000
        ENTRY main
        STACK 768
        %include "perry.inc"

MAX_FILES   EQU 64
NAME_SIZE   EQU 16          ; bytes per file-name slot (16 = shift by 4)
LIST_TOP    EQU 3           ; first row of the explorer file list
LIST_ROWS   EQU 18          ; visible list rows
ATTR_DESK   EQU 0x17        ; explorer background
ATTR_FRAME  EQU 0x1F
ATTR_ITEM   EQU 0x1F
ATTR_SEL    EQU 0x30
ATTR_BAR    EQU 0x70
; The explorer's directory cache lives in upper RAM: it is rebuilt after
; every program run, so programs may freely reuse that memory.
names       EQU 0xE800                      ; MAX_FILES * NAME_SIZE bytes
sizes_lo    EQU names + MAX_FILES*NAME_SIZE ; MAX_FILES words
sizes_hi    EQU sizes_lo + MAX_FILES*2      ; MAX_FILES words

SECTION .code
; =================================================================== main
main:   MOV AX, 0x0003              ; text mode 80x25 (clears the screen)
        INT INT_VIDEO
        MOV AX, 0x07
        MOV.B [BDA_ATTR], AX
        CALL banner
prompt_loop:
        CALL ensure_text_mode
        MOV SI, s_prompt
        CALL print_str
        MOV DX, linebuf             ; buffered line input
        MOV AX, DOS_GETLINE << 8
        INT INT_DOS
        MOV.B BX, [linebuf+1]       ; number of characters typed
        MOV AX, 0
        MOV.B [BX+linebuf+2], AX    ; NUL-terminate
        MOV SI, linebuf+2
        CALL execute_line
        JMP prompt_loop

; banner: coloured welcome header
banner: MOV DX, 0x0000
        MOV CX, 0x0350
        MOV AX, 0x1F20
        CALL tui_fill
        MOV SI, s_banner1
        MOV DX, 0x0002
        MOV BX, 0x1F
        CALL tui_puts
        MOV SI, s_banner2
        MOV DX, 0x0102
        MOV BX, 0x1B
        CALL tui_puts
        MOV SI, s_banner3
        MOV DX, 0x0202
        MOV BX, 0x1E
        CALL tui_puts
        MOV DX, 0x0400
        CALL tui_cursor
        RET

; ensure_text_mode: return to 80x25 text if a program left graphics on
ensure_text_mode:
        PUSH AX
        PUSH BX
        MOV AX, 0x0F00
        INT INT_VIDEO
        AND AX, 0xFF
        CMP AX, 0x03
        JZ .ok
        MOV AX, 0x0003
        INT INT_VIDEO
.ok:    MOV AX, 0x0002              ; hide the mouse cursor
        INT INT_MOUSE
        CALL tui_cursor_on
        POP BX
        POP AX
        RET

; =================================================================== parser
; execute_line: SI = command line
execute_line:
        CALL skip_spaces
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .empty
        MOV DI, cmdword
.copy:  MOV.B AX, [SI]
        CMP AX, 0
        JZ .endw
        CMP AX, ' '
        JZ .endw
        INC SI
        CMP DI, cmdword+15
        JAE .copy
        CALL to_upper
        MOV.B [DI], AX
        INC DI
        JMP .copy
.endw:  MOV AX, 0
        MOV.B [DI], AX
        CALL skip_spaces
        MOV [args_ptr], SI
        MOV BX, cmd_table
.next:  MOV DI, [BX]
        CMP DI, 0
        JZ .external
        MOV SI, cmdword
        CALL str_cmpi
        JZ .found
        ADD BX, 4
        JMP .next
.found: MOV SI, [args_ptr]
        MOV AX, [BX+2]
        CALL AX
        RET
.external:
        MOV SI, cmdword
        MOV DI, [args_ptr]
        CALL open_file
        JNC .empty
        CALL print_str              ; SI = error message
        CALL print_nl
.empty: RET

; split_word: SI = text. Copies the first word to `argword` (upper case)
;             and leaves SI on the following argument text.
split_word:
        PUSH AX
        PUSH DI
        CALL skip_spaces
        MOV DI, argword
.copy:  MOV.B AX, [SI]
        CMP AX, 0
        JZ .end
        CMP AX, ' '
        JZ .end
        INC SI
        CMP DI, argword+15
        JAE .copy
        CALL to_upper
        MOV.B [DI], AX
        INC DI
        JMP .copy
.end:   MOV AX, 0
        MOV.B [DI], AX
        CALL skip_spaces
        POP DI
        POP AX
        RET

; =================================================================== programs
; get_ext: SI = file name -> DI = extension after the last '.' (or "")
get_ext:
        PUSH AX
        PUSH SI
        MOV DI, s_empty
.l:     MOV.B AX, [SI]
        CMP AX, 0
        JZ .d
        INC SI
        CMP AX, '.'
        JNZ .l
        MOV DI, SI
        JMP .l
.d:     POP SI
        POP AX
        RET

; find_type: SI = file name -> BX = entry of type_table
;   entry: +0 ext, +2 description, +4 handler program (0 = executable,
;          0xFFFF = none), +6 icon char, +7 icon colour
find_type:
        PUSH SI
        PUSH DI
        CALL get_ext
        MOV SI, DI
        MOV BX, type_table
.l:     MOV DI, [BX]
        CMP DI, 0
        JZ .d
        CALL str_cmpi
        JZ .d
        ADD BX, 8
        JMP .l
.d:     POP DI
        POP SI
        RET

; open_file: SI = name, DI = arguments.
;   .PEX (or no extension)  -> run it
;   associated data file    -> run the associated program with SI as argument
;   CF = 1 on error with SI = message
open_file:
        PUSH AX
        PUSH BX
        PUSH DI
        CALL get_ext
        MOV.B AX, [DI]
        POP DI
        CMP AX, 0
        JZ .exec                    ; no extension: try NAME.PEX
        CALL find_type
        MOV AX, [BX+4]
        CMP AX, 0
        JZ .exec
        CMP AX, 0xFFFF
        JZ .noassoc
        MOV DI, SI                  ; argument = data file name
        MOV SI, AX                  ; program  = handler
.exec:  CALL run_program
        POP BX
        POP AX
        RET
.noassoc:
        MOV SI, s_noassoc
        STC
        POP BX
        POP AX
        RET

; run_program: SI = program name (".PEX" appended if missing), DI = args.
;   CF = 1 on error with SI = message; otherwise last_code = exit code
run_program:
        PUSH AX
        PUSH BX
        PUSH DX
        PUSH DI
        MOV DI, progname
        CALL str_copy
        MOV SI, progname
        CALL get_ext
        MOV.B AX, [DI]
        CMP AX, 0
        JNZ .named
        MOV SI, progname            ; append the default extension
        CALL str_len
        MOV DI, progname
        ADD DI, CX
        MOV SI, s_pexext
        CALL str_copy
.named: POP BX                      ; BX = argument string
        PUSH BX
        MOV DX, progname
        MOV AX, DOS_EXEC << 8
        INT INT_DOS
        JC .err
        MOV [last_code], AX
        CALL ensure_text_mode
        CLC
        JMP .out
.err:   MOV SI, s_badcmd
        CMP AX, 2
        JZ .fail
        MOV SI, s_nomem
        CMP AX, 8
        JZ .fail
        MOV SI, s_badexe
.fail:  STC
.out:   POP DI
        POP DX
        POP BX
        POP AX
        RET

; =================================================================== commands
cmd_help:
        MOV SI, s_help
        CALL print_str
        RET

cmd_ver:
        MOV SI, s_ver
        CALL print_str
        RET

cmd_cls:
        MOV AX, 0x0003
        INT INT_VIDEO
        RET

cmd_exit:
        MOV AX, DOS_EXIT << 8
        INT INT_DOS
        RET

cmd_echo:
        CALL print_str
        CALL print_nl
        RET

cmd_run:
        CALL split_word
        MOV AX, 0
        MOV.B AX, [argword]
        CMP AX, 0
        JZ .usage
        MOV DI, SI
        MOV SI, argword
        CALL open_file
        JNC .ok
        CALL print_str
        CALL print_nl
.ok:    RET
.usage: MOV SI, s_run_usage
        CALL print_str
        RET

; DIR [pattern]
cmd_dir:
        MOV.B AX, [SI]
        CMP AX, 0
        JNZ .pat
        MOV SI, s_star
.pat:   MOV [dir_pat], SI
        MOV SI, s_dir_head
        CALL print_str
        MOV AX, 0
        MOV [dir_files], AX
        MOV [dir_tot_lo], AX
        MOV [dir_tot_hi], AX
        MOV DX, [dir_pat]
        MOV AX, DOS_FINDFIRST << 8
        INT INT_DOS
        JC .none
.entry: MOV SI, DTA_DEFAULT+DTA_NAME
        CALL print_str              ; name padded to 14 columns
        CALL str_len
        MOV AX, 14
        SUB AX, CX
        MOV CX, AX
        CALL print_spaces
        MOV AX, [DTA_DEFAULT+DTA_SIZE_LO]
        MOV DX, [DTA_DEFAULT+DTA_SIZE_HI]
        ADD [dir_tot_lo], AX
        ADC [dir_tot_hi], DX
        MOV CX, 9
        CALL print_dec32_w
        MOV CX, 3
        CALL print_spaces
        MOV SI, DTA_DEFAULT+DTA_NAME
        CALL find_type
        MOV SI, [BX+2]
        CALL print_str
        CALL print_nl
        MOV AX, [dir_files]
        INC AX
        MOV [dir_files], AX
        MOV AX, DOS_FINDNEXT << 8
        INT INT_DOS
        JNC .entry
.none:  MOV AX, [dir_files]
        MOV CX, 10
        CALL print_dec_w
        MOV SI, s_dir_files
        CALL print_str
        MOV AX, [dir_tot_lo]
        MOV DX, [dir_tot_hi]
        MOV CX, 9
        CALL print_dec32_w
        MOV SI, s_dir_bytes
        CALL print_str
        MOV AX, DOS_DISKFREE << 8
        INT INT_DOS
        MOV CX, 10
        CALL print_dec_w
        MOV SI, s_dir_free
        CALL print_str
        RET

; MEM: memory map report
cmd_mem:
        MOV AX, DOS_MEMINFO << 8
        INT INT_DOS
        MOV [mem_free], AX
        MOV [mem_total], BX
        MOV [mem_upper], CX
        MOV [mem_used], DX
        MOV SI, s_mem_head
        CALL print_str
        MOV SI, s_mem_conv
        CALL print_str
        MOV AX, [mem_total]
        MOV CX, 9
        CALL print_dec_w
        MOV AX, [mem_used]
        CALL print_dec_w
        MOV AX, [mem_free]
        CALL print_dec_w
        CALL print_nl
        MOV SI, s_mem_upper
        CALL print_str
        MOV AX, [mem_upper]
        CALL print_dec_w
        MOV AX, 0
        CALL print_dec_w
        MOV AX, [mem_upper]
        CALL print_dec_w
        CALL print_nl
        MOV SI, s_mem_vram
        CALL print_str
        MOV SI, s_mem_tpa
        CALL print_str
        MOV AX, RAM_END - TPA_START
        MOV CX, 0
        CALL print_dec_w
        MOV SI, s_mem_bytes
        CALL print_str
        RET

; TYPE file
cmd_type:
        CALL split_word
        MOV DX, argword
        MOV AX, DOS_OPEN << 8
        INT INT_DOS
        JC .nf
        MOV [type_handle], AX
.chunk: MOV BX, [type_handle]
        MOV CX, 128
        MOV DX, iobuf
        MOV AX, DOS_READ << 8
        INT INT_DOS
        CMP AX, 0
        JZ .eof
        MOV CX, AX
        MOV SI, iobuf
.ch:    MOV.B AX, [SI]
        INC SI
        CMP AX, 13
        JZ .skip
        CMP AX, 10
        JNZ .put
        CALL print_nl
        JMP .skip
.put:   CALL print_char
.skip:  LOOP .ch
        JMP .chunk
.eof:   MOV BX, [type_handle]
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        CALL print_nl
        RET
.nf:    MOV SI, s_notfound
        CALL print_str
        RET

; DEL file
cmd_del:
        CALL split_word
        MOV DX, argword
        MOV AX, DOS_DELETE << 8
        INT INT_DOS
        JNC .ok
        MOV SI, s_delfail
        CALL print_str
.ok:    RET

; DATE / TIME
cmd_date:
        MOV SI, s_date
        CALL print_str
        MOV AX, DOS_DATE << 8
        INT INT_DOS
        MOV AX, CX
        CALL print_dec
        MOV AX, '-'
        CALL print_char
        MOV AX, DX
        SHR AX, 8
        CALL print2
        MOV AX, '-'
        CALL print_char
        MOV AX, DX
        AND AX, 0xFF
        CALL print2
        CALL print_nl
        RET

cmd_time:
        MOV SI, s_time
        CALL print_str
        MOV AX, DOS_TIME << 8
        INT INT_DOS
        MOV AX, CX
        SHR AX, 8
        CALL print2
        MOV AX, ':'
        CALL print_char
        MOV AX, CX
        AND AX, 0xFF
        CALL print2
        MOV AX, ':'
        CALL print_char
        MOV AX, DX
        SHR AX, 8
        CALL print2
        CALL print_nl
        RET

; print2: AX (0..99) with a leading zero
print2: CMP AX, 10
        JAE .two
        PUSH AX
        MOV AX, '0'
        CALL print_char
        POP AX
.two:   CALL print_dec
        RET

; =================================================================== explorer
cmd_explorer:
        CALL tui_cursor_off
        MOV AX, 0
        MOV [sel], AX
        MOV [top], AX
.reload:
        CALL load_files
.redraw:
        CALL draw_explorer
.key:   CALL tui_getkey
        CMP AX, KEY_ESC
        JZ .exit
        CMP AX, KEY_UP
        JZ .up
        CMP AX, KEY_DOWN
        JZ .down
        CMP AX, KEY_HOME
        JZ .home
        CMP AX, KEY_END
        JZ .end
        CMP AX, KEY_PGUP
        JZ .pgup
        CMP AX, KEY_PGDN
        JZ .pgdn
        CMP AX, KEY_ENTER
        JZ .open
        CMP AX, KEY_DEL
        JZ .delete
        CMP AX, KEY_F5
        JZ .reload
        JMP .key
.up:    MOV AX, [sel]
        CMP AX, 0
        JZ .key
        DEC AX
        JMP .setsel
.down:  MOV AX, [sel]
        INC AX
        JMP .setsel
.home:  MOV AX, 0
        JMP .setsel
.end:   MOV AX, [count]
        JMP .setsel
.pgup:  MOV AX, [sel]
        SUB AX, LIST_ROWS
        JNC .setsel
        MOV AX, 0
        JMP .setsel
.pgdn:  MOV AX, [sel]
        ADD AX, LIST_ROWS
.setsel:
        CALL select
        JMP .redraw
.open:  MOV AX, [count]
        CMP AX, 0
        JZ .key
        MOV AX, [sel]
        CALL name_ptr
        MOV DI, s_empty
        CALL open_file
        JNC .back
        CALL status_message         ; SI = error
.back:  CALL tui_cursor_off
        JMP .reload
.delete:
        MOV AX, [count]
        CMP AX, 0
        JZ .key
        MOV SI, s_confirm
        CALL status_message_nowait
        CALL tui_getkey
        AND AX, 0xFF
        CALL to_upper
        CMP AX, 'Y'
        JNZ .redraw
        MOV AX, [sel]
        CALL name_ptr
        MOV DX, SI
        MOV AX, DOS_DELETE << 8
        INT INT_DOS
        JNC .reload
        MOV SI, s_delfail
        CALL status_message
        JMP .redraw
.exit:  MOV AX, 0x0720
        CALL tui_clear
        MOV DX, 0
        CALL tui_cursor
        CALL tui_cursor_on
        RET

; select: AX = wanted index -> clamp to the list and scroll into view
select: MOV BX, [count]
        CMP BX, 0
        JZ .zero
        CMP AX, BX
        JB .inrange
        MOV AX, BX
        DEC AX
.inrange:
        MOV [sel], AX
        MOV BX, [top]
        CMP AX, BX
        JAE .below
        MOV [top], AX
        RET
.below: ADD BX, LIST_ROWS
        CMP AX, BX
        JB .ok
        SUB AX, LIST_ROWS-1
        MOV [top], AX
.ok:    RET
.zero:  MOV AX, 0
        MOV [sel], AX
        MOV [top], AX
        RET

; name_ptr: AX = file index -> SI = its name
name_ptr:
        MOV SI, AX
        SHL SI, 4
        ADD SI, names
        RET

; load_files: read the directory into names[] / sizes
load_files:
        MOV AX, 0
        MOV [count], AX
        MOV DX, s_star
        MOV AX, DOS_FINDFIRST << 8
        INT INT_DOS
        JC .done
.entry: MOV AX, [count]
        CMP AX, MAX_FILES
        JAE .done
        CALL name_ptr
        MOV DI, SI
        MOV SI, DTA_DEFAULT+DTA_NAME
        CALL str_copy
        MOV BX, [count]
        SHL BX, 1
        MOV AX, [DTA_DEFAULT+DTA_SIZE_LO]
        MOV [BX+sizes_lo], AX
        MOV AX, [DTA_DEFAULT+DTA_SIZE_HI]
        MOV [BX+sizes_hi], AX
        MOV AX, [count]
        INC AX
        MOV [count], AX
        MOV AX, DOS_FINDNEXT << 8
        INT INT_DOS
        JNC .entry
.done:  MOV AX, [sel]
        CALL select
        RET

; draw_explorer: full redraw of the explorer screen
draw_explorer:
        MOV AX, (ATTR_DESK << 8) | ' '
        CALL tui_clear
        ; title bar
        MOV DX, 0x0000
        MOV CX, 0x0150
        MOV AX, (ATTR_BAR << 8) | ' '
        CALL tui_fill
        MOV SI, s_exp_title
        MOV DX, 0x0001
        MOV BX, ATTR_BAR
        CALL tui_puts
        MOV SI, s_exp_drive
        MOV DX, 0x0046
        CALL tui_puts
        ; frames
        MOV DX, 0x0100
        MOV CX, (22 << 8) | 55
        MOV BX, ATTR_FRAME
        CALL tui_box
        MOV DX, 0x0137
        MOV CX, (22 << 8) | 25
        CALL tui_box
        MOV SI, s_exp_files
        MOV DX, 0x0102
        CALL tui_puts
        MOV SI, s_exp_details
        MOV DX, 0x0139
        CALL tui_puts
        MOV SI, s_exp_cols
        MOV DX, 0x0202
        MOV BX, 0x1E
        CALL tui_puts
        ; list rows
        MOV AX, 0
.row:   CALL draw_row
        INC AX
        CMP AX, LIST_ROWS
        JB .row
        CALL draw_details
        ; status bars
        MOV DX, 0x1700
        MOV CX, 0x0150
        MOV AX, (ATTR_BAR << 8) | ' '
        CALL tui_fill
        MOV SI, s_exp_keys
        MOV DX, 0x1701
        MOV BX, ATTR_BAR
        CALL tui_puts
        MOV DX, 0x1800
        MOV CX, 0x0150
        MOV AX, 0x1B20
        CALL tui_fill
        MOV AX, [count]
        MOV DI, numbuf
        CALL utoa
        MOV SI, numbuf
        MOV DX, 0x1801
        MOV BX, 0x1B
        CALL tui_puts
        MOV SI, s_exp_nfiles
        ADD DX, CX
        CALL tui_puts
        MOV AX, DOS_DISKFREE << 8
        INT INT_DOS
        MOV BX, 0x1B
        MOV DI, numbuf
        CALL utoa
        MOV SI, numbuf
        MOV DX, 0x1814
        CALL tui_puts
        ADD DX, CX
        MOV SI, s_exp_free
        CALL tui_puts
        RET

; draw_row: AX = visible row (0..LIST_ROWS-1)
draw_row:
        PUSHA
        MOV [row_vis], AX
        MOV BX, AX
        ADD BX, [top]
        MOV [row_idx], BX
        MOV DX, AX
        ADD DX, LIST_TOP
        SHL DX, 8
        OR DX, 1
        MOV [row_pos], DX
        MOV BX, ATTR_ITEM
        MOV AX, [row_idx]
        CMP AX, [sel]
        JNZ .attr
        MOV BX, ATTR_SEL
.attr:  MOV [row_attr], BX
        MOV AX, BX
        SHL AX, 8
        OR AX, ' '
        MOV CX, 0x0135
        CALL tui_fill
        MOV AX, [row_idx]
        CMP AX, [count]
        JAE .done
        CALL name_ptr
        CALL find_type
        ; icon (keeps the row background, own foreground colour)
        MOV.B AX, [BX+7]
        MOV CX, [row_attr]
        AND CX, 0xF0
        OR AX, CX
        PUSH BX
        MOV DX, [row_pos]
        ADD DX, 2
        MOV CX, BX
        MOV BX, AX
        MOV.B AX, [CX+6]
        CALL tui_putc
        POP BX
        ; name and type description
        MOV CX, BX
        MOV BX, [row_attr]
        MOV DX, [row_pos]
        ADD DX, 4
        CALL tui_puts
        MOV DI, CX
        MOV SI, [DI+2]
        MOV DX, [row_pos]
        ADD DX, 18
        CALL tui_puts
        ; size, right-aligned to column 53
        MOV BX, [row_idx]
        SHL BX, 1
        MOV AX, [BX+sizes_lo]
        MOV DX, [BX+sizes_hi]
        MOV DI, numbuf
        CALL u32toa
        MOV DX, [row_pos]
        AND DX, 0xFF00
        OR DX, 53
        SUB DX, CX
        MOV SI, numbuf
        MOV BX, [row_attr]
        CALL tui_puts
.done:  POPA
        RET

; draw_details: right-hand panel for the selected file
draw_details:
        MOV AX, [count]
        CMP AX, 0
        JZ .none
        MOV AX, [sel]
        CALL name_ptr
        MOV [det_name], SI
        MOV BX, 0x1E
        MOV DX, 0x0339
        PUSH SI
        MOV SI, s_det_name
        CALL tui_puts
        POP SI
        MOV DX, 0x0439
        MOV BX, 0x1F
        CALL tui_puts
        MOV DX, 0x0639
        MOV BX, 0x1E
        PUSH SI
        MOV SI, s_det_type
        CALL tui_puts
        POP SI
        CALL find_type
        MOV [det_type], BX
        MOV SI, [BX+2]
        MOV DX, 0x0739
        MOV BX, 0x1F
        CALL tui_puts
        MOV SI, s_det_size
        MOV DX, 0x0939
        MOV BX, 0x1E
        CALL tui_puts
        MOV BX, [sel]
        SHL BX, 1
        MOV AX, [BX+sizes_lo]
        MOV DX, [BX+sizes_hi]
        MOV DI, numbuf
        CALL u32toa
        MOV SI, numbuf
        MOV DX, 0x0A39
        MOV BX, 0x1F
        CALL tui_puts
        ADD DX, CX
        MOV SI, s_det_bytes
        CALL tui_puts
        MOV SI, s_det_opens
        MOV DX, 0x0C39
        MOV BX, 0x1E
        CALL tui_puts
        MOV BX, [det_type]
        MOV SI, [BX+4]
        CMP SI, 0
        JNZ .h1
        MOV SI, s_det_self
        JMP .h2
.h1:    CMP SI, 0xFFFF
        JNZ .h2
        MOV SI, s_det_noprog
.h2:    MOV DX, 0x0D39
        MOV BX, 0x1F
        CALL tui_puts
        MOV SI, s_det_hint
        MOV DX, 0x1339
        MOV BX, 0x17
        CALL tui_puts
        MOV SI, s_det_hint2
        MOV DX, 0x1439
        CALL tui_puts
.none:  RET

; status_message: show SI on the status bar and wait for a key
status_message:
        CALL status_message_nowait
        CALL tui_getkey
        RET

status_message_nowait:
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH DX
        MOV DX, 0x1700
        MOV CX, 0x0150
        MOV AX, 0x4F20
        CALL tui_fill
        MOV DX, 0x1701
        MOV BX, 0x4F
        CALL tui_puts
        POP DX
        POP CX
        POP BX
        POP AX
        RET

        %include "lib/stdio.inc"
        %include "lib/tui.inc"

; =================================================================== data
SECTION .data
cmd_table:
        DW s_c_dir, cmd_dir
        DW s_c_cls, cmd_cls
        DW s_c_mem, cmd_mem
        DW s_c_run, cmd_run
        DW s_c_type, cmd_type
        DW s_c_del, cmd_del
        DW s_c_ver, cmd_ver
        DW s_c_date, cmd_date
        DW s_c_time, cmd_time
        DW s_c_echo, cmd_echo
        DW s_c_help, cmd_help
        DW s_c_q, cmd_help
        DW s_c_exp, cmd_explorer
        DW s_c_explorer, cmd_explorer
        DW s_c_exit, cmd_exit
        DW 0, 0

; type table: ext, description, handler (0 = run, 0xFFFF = none), icon, colour
type_table:
        DW s_x_pex, s_t_pex, 0
        DB 0x0F, 14
        DW s_x_txt, s_t_txt, s_word
        DB 0xFE, 15
        DW s_x_xls, s_t_xls, s_excel
        DB 0xFE, 10
        DW s_x_wad, s_t_wad, s_raycast
        DB 0x07, 12
        DW s_x_img, s_t_img, s_paint
        DB 0xFE, 13
        DW 0, s_t_other, 0xFFFF
        DB 0xFA, 7

s_c_dir:      DB "DIR", 0
s_c_cls:      DB "CLS", 0
s_c_mem:      DB "MEM", 0
s_c_run:      DB "RUN", 0
s_c_type:     DB "TYPE", 0
s_c_del:      DB "DEL", 0
s_c_ver:      DB "VER", 0
s_c_date:     DB "DATE", 0
s_c_time:     DB "TIME", 0
s_c_echo:     DB "ECHO", 0
s_c_help:     DB "HELP", 0
s_c_q:        DB "?", 0
s_c_exp:      DB "EXP", 0
s_c_explorer: DB "EXPLORER", 0
s_c_exit:     DB "EXIT", 0

s_x_pex:      DB "PEX", 0
s_x_txt:      DB "TXT", 0
s_x_xls:      DB "XLS", 0
s_x_wad:      DB "WAD", 0
s_x_img:      DB "IMG", 0
s_t_pex:      DB "Program", 0
s_t_txt:      DB "Text document", 0
s_t_xls:      DB "Spreadsheet", 0
s_t_wad:      DB "Game data (WAD)", 0
s_t_img:      DB "Paint image", 0
s_t_other:    DB "File", 0
s_word:       DB "WORD.PEX", 0
s_excel:      DB "EXCEL.PEX", 0
s_raycast:    DB "RAYCAST.PEX", 0
s_paint:      DB "PAINT.PEX", 0

s_banner1:    DB "PERRY-DOS 1.0   ", 0xB3, "   PERRY-16 CPU  ", 0xB3, "  36 KB system RAM  ", 0xB3, "  VGA + AdLib", 0
s_banner2:    DB "Type HELP for commands, EXPLORER for the file browser.", 0
s_banner3:    DB "Apps: WORD  EXCEL  PAINT  RAYCAST   (run them by name)", 0
s_prompt:     DB "A:\\> ", 0
s_empty:      DB 0
s_star:       DB "*.*", 0
s_pexext:     DB ".PEX", 0
s_badcmd:     DB "Bad command or file name", 0
s_nomem:      DB "Not enough memory to load program", 0
s_badexe:     DB "Not a valid PERRY executable", 0
s_noassoc:    DB "No program is associated with this file type", 0
s_notfound:   DB "File not found", 13, 10, 0
s_delfail:    DB "Cannot delete file (missing or protected)", 13, 10, 0
s_run_usage:  DB "Usage: RUN <program> [arguments]", 13, 10, 0
s_ver:        DB 13, 10, "PERRY-DOS Version 1.0 for the PERRY-16 CPU", 13, 10
              DB "16-bit ISA, 64 KB address space, VGA mode 13h, AdLib OPL2", 13, 10, 13, 10, 0
s_date:       DB "Current date is ", 0
s_time:       DB "Current time is ", 0
s_help:       DB "PERRY-DOS commands:", 13, 10
              DB "  DIR [pattern]     list files (e.g. DIR *.PEX)", 13, 10
              DB "  RUN file [args]   run a program or open a document", 13, 10
              DB "  TYPE file         show a text file", 13, 10
              DB "  DEL file          delete a file", 13, 10
              DB "  CLS               clear the screen", 13, 10
              DB "  MEM               memory usage", 13, 10
              DB "  EXPLORER (EXP)    full-screen file explorer", 13, 10
              DB "  VER, DATE, TIME, ECHO, HELP, EXIT", 13, 10
              DB "Typing a program name runs it: WORD NOTES.TXT, EXCEL, PAINT, RAYCAST", 13, 10, 0
s_dir_head:   DB 13, 10, " Volume in drive A is PERRY-DOS", 13, 10
              DB " Directory of A:\\", 13, 10, 13, 10, 0
s_dir_files:  DB " file(s) ", 0
s_dir_bytes:  DB " bytes", 13, 10, 0
s_dir_free:   DB " KB free", 13, 10, 13, 10, 0
s_mem_head:   DB 13, 10, "Memory type          Total     Used     Free", 13, 10
              DB "-----------------  -------  -------  -------", 13, 10, 0
s_mem_conv:   DB "Conventional     ", 0
s_mem_upper:  DB "Upper (C800-EFFF)", 0
s_mem_vram:   DB "Video: 64000 bytes VGA (A000 window, banked) + 4000 bytes text (B800)", 13, 10, 0
s_mem_tpa:    DB "Largest executable program: ", 0
s_mem_bytes:  DB " bytes (TPA 3000-9FFF)", 13, 10, 13, 10, 0

s_exp_title:  DB "PERRY-DOS Explorer", 0
s_exp_drive:  DB "Drive A:\\", 0
s_exp_files:  DB " Files ", 0
s_exp_details: DB " Details ", 0
s_exp_cols:   DB "   Name          Type                     Size", 0
s_exp_keys:   DB 0x18, 0x19, " Select   Enter Open   Del Delete   F5 Refresh   Esc Command prompt", 0
s_exp_nfiles: DB " file(s)", 0
s_exp_free:   DB " KB free", 0
s_confirm:    DB "Delete the selected file? (Y/N)", 0
s_det_name:   DB "Name", 0
s_det_type:   DB "Type", 0
s_det_size:   DB "Size", 0
s_det_bytes:  DB " bytes", 0
s_det_opens:  DB "Opens with", 0
s_det_self:   DB "(runs as program)", 0
s_det_noprog: DB "(nothing)", 0
s_det_hint:   DB "Enter: open/run", 0
s_det_hint2:  DB "Del: delete", 0

linebuf:      DB 78, 0
              TIMES 80 DB 0

SECTION .bss
cmdword:      RESB 16
argword:      RESB 16
progname:     RESB 20
args_ptr:     RESW 1
last_code:    RESW 1
dir_pat:      RESW 1
dir_files:    RESW 1
dir_tot_lo:   RESW 1
dir_tot_hi:   RESW 1
mem_free:     RESW 1
mem_total:    RESW 1
mem_upper:    RESW 1
mem_used:     RESW 1
type_handle:  RESW 1
iobuf:        RESB 128
count:        RESW 1
sel:          RESW 1
top:          RESW 1
row_vis:      RESW 1
row_idx:      RESW 1
row_pos:      RESW 1
row_attr:     RESW 1
det_name:     RESW 1
det_type:     RESW 1
