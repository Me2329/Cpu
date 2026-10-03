; WORD.PEX - PERRY Word, a full-screen text editor.
;
;   WORD [file.txt]
;
; Keys: arrows/Home/End/PgUp/PgDn move, typing inserts, Enter splits a
; line, Backspace/Del delete, Tab inserts spaces,
; F2 save, F3 open, F4 new document, Esc quit (asks to save changes).
;
; The document is a flat byte buffer with '\n' line separators. Files are
; read and written through INT 21h (AH=3Dh/3Ch/3Fh/40h/3Eh); CR bytes are
; dropped on load so DOS-style CR LF files work too.
        ORG 0x3000
        ENTRY main
        STACK 1024
        %include "perry.inc"

BUF_SIZE    EQU 16384
TEXT_TOP    EQU 2
TEXT_ROWS   EQU 21
ATTR_TITLE  EQU 0x1F
ATTR_MENU   EQU 0x70
ATTR_TEXT   EQU 0xF0
ATTR_STATUS EQU 0x3F
ATTR_MSG    EQU 0x0E
ATTR_PROMPT EQU 0x4F

SECTION .code
main:   MOV AX, 0x0003
        INT INT_VIDEO
        CALL new_doc
        MOV SI, PSP_CMDLINE
        CALL skip_spaces
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .loop
        MOV DI, filename
        CALL copy_word
        CALL load_file
        JNC .loaded
        MOV SI, s_newfile
        CALL set_message
        JMP .loop
.loaded:
        CALL msg_loaded
.loop:  CALL redraw
        CALL tui_getkey
        CALL handle_key
        JMP .loop

; ------------------------------------------------------------ key dispatch
handle_key:
        MOV BX, 0
        MOV [msg], BX
        CMP AX, KEY_ESC
        JZ quit
        CMP AX, KEY_F2
        JZ save_file
        CMP AX, KEY_F3
        JZ open_file
        CMP AX, KEY_F4
        JZ cmd_new
        CMP AX, KEY_LEFT
        JZ move_left
        CMP AX, KEY_RIGHT
        JZ move_right
        CMP AX, KEY_UP
        JZ move_up
        CMP AX, KEY_DOWN
        JZ move_down
        CMP AX, KEY_HOME
        JZ move_home
        CMP AX, KEY_END
        JZ move_end
        CMP AX, KEY_PGUP
        JZ page_up
        CMP AX, KEY_PGDN
        JZ page_down
        CMP AX, KEY_ENTER
        JZ .newline
        CMP AX, KEY_BACKSPACE
        JZ backspace
        CMP AX, KEY_DEL
        JZ delete_char
        CMP AX, KEY_TAB
        JZ .tab
        AND AX, 0xFF
        CMP AX, 32
        JB .ignore
        CMP AX, 127
        JAE .ignore
        CALL insert_char
.ignore:
        RET
.newline:
        MOV AX, 10
        CALL insert_char
        RET
.tab:   MOV AX, ' '
        CALL insert_char
        MOV AX, [cursor]
        CALL line_start
        MOV BX, [cursor]
        SUB BX, AX
        TEST BX, 3
        JNZ .tab
        RET

; ------------------------------------------------------------ editing
; insert_char: AL = character inserted at the cursor
insert_char:
        PUSH AX
        MOV CX, [len]
        CMP CX, BUF_SIZE-1
        JAE .full
        MOV SI, buf
        ADD SI, CX
        SUB CX, [cursor]
        JCXZ .put
.mv:    DEC SI
        MOV.B BX, [SI]
        MOV.B [SI+1], BX
        LOOP .mv
.put:   POP AX
        MOV SI, [cursor]
        MOV.B [SI+buf], AX
        INC SI
        MOV [cursor], SI
        MOV AX, [len]
        INC AX
        MOV [len], AX
        MOV AX, 1
        MOV [dirty], AX
        RET
.full:  POP AX
        MOV SI, s_full
        CALL set_message
        RET

; delete_at: AX = offset of the character to remove
delete_at:
        CMP AX, [len]
        JAE .r
        MOV DI, buf
        ADD DI, AX
        MOV SI, DI
        INC SI
        MOV CX, [len]
        SUB CX, AX
        DEC CX
        REP MOVSB
        MOV AX, [len]
        DEC AX
        MOV [len], AX
        MOV AX, 1
        MOV [dirty], AX
.r:     RET

backspace:
        MOV AX, [cursor]
        CMP AX, 0
        JZ .r
        DEC AX
        MOV [cursor], AX
        CALL delete_at
.r:     RET

delete_char:
        MOV AX, [cursor]
        CALL delete_at
        RET

; ------------------------------------------------------------ navigation
; line_start: AX = offset -> AX = first offset of its line
line_start:
        PUSH BX
        PUSH SI
.l:     CMP AX, 0
        JZ .d
        MOV SI, AX
        MOV.B BX, [SI+buf-1]
        CMP BX, 10
        JZ .d
        DEC AX
        JMP .l
.d:     POP SI
        POP BX
        RET

; line_end: AX = offset -> AX = offset of the line's '\n' (or len)
line_end:
        PUSH BX
        PUSH SI
.l:     CMP AX, [len]
        JAE .d
        MOV SI, AX
        MOV.B BX, [SI+buf]
        CMP BX, 10
        JZ .d
        INC AX
        JMP .l
.d:     POP SI
        POP BX
        RET

move_left:
        MOV AX, [cursor]
        CMP AX, 0
        JZ .r
        DEC AX
        MOV [cursor], AX
.r:     RET

move_right:
        MOV AX, [cursor]
        CMP AX, [len]
        JAE .r
        INC AX
        MOV [cursor], AX
.r:     RET

move_home:
        MOV AX, [cursor]
        CALL line_start
        MOV [cursor], AX
        RET

move_end:
        MOV AX, [cursor]
        CALL line_end
        MOV [cursor], AX
        RET

move_up:
        MOV AX, [cursor]
        CALL line_start
        CMP AX, 0
        JZ .r
        MOV BX, [cursor]
        SUB BX, AX                  ; column
        DEC AX
        CALL line_start
        CALL goto_col
.r:     RET

move_down:
        MOV AX, [cursor]
        CALL line_start
        MOV BX, [cursor]
        SUB BX, AX                  ; column
        MOV AX, [cursor]
        CALL line_end
        CMP AX, [len]
        JAE .r
        INC AX
        CALL goto_col
.r:     RET

; goto_col: AX = line start, BX = column -> cursor (clamped to line end)
goto_col:
        PUSH AX
        CALL line_end
        MOV CX, AX
        POP AX
        ADD AX, BX
        CMP AX, CX
        JBE .ok
        MOV AX, CX
.ok:    MOV [cursor], AX
        RET

page_up:
        MOV CX, TEXT_ROWS-1
.l:     PUSH CX
        CALL move_up
        POP CX
        LOOP .l
        RET

page_down:
        MOV CX, TEXT_ROWS-1
.l:     PUSH CX
        CALL move_down
        POP CX
        LOOP .l
        RET

; ------------------------------------------------------------ display
; scroll_into_view: adjust top/left so the cursor is visible and compute
;                   cur_row / cur_col
scroll_into_view:
        MOV AX, [cursor]
        CALL line_start
        MOV [cur_ls], AX
        MOV CX, 0
        CMP AX, [top]
        JAE .count
        MOV [top], AX
        JMP .horiz
.count: MOV AX, [top]
.cnt:   CMP AX, [cur_ls]
        JAE .adv
        CALL line_end
        INC AX
        INC CX
        JMP .cnt
.adv:   CMP CX, TEXT_ROWS
        JB .horiz
        MOV AX, [top]
        CALL line_end
        INC AX
        MOV [top], AX
        DEC CX
        JMP .adv
.horiz: MOV [cur_row], CX
        MOV AX, [cursor]
        SUB AX, [cur_ls]
        MOV [cur_col], AX
        CMP AX, [left]
        JAE .right
        MOV [left], AX
        RET
.right: MOV BX, [left]
        ADD BX, 79
        CMP AX, BX
        JBE .done
        SUB AX, 79
        MOV [left], AX
.done:  RET

redraw: CALL scroll_into_view
        ; title bar
        MOV DX, 0x0000
        MOV CX, 0x0150
        MOV AX, (ATTR_TITLE << 8) | ' '
        CALL tui_fill
        MOV SI, s_title
        MOV DX, 0x0001
        MOV BX, ATTR_TITLE
        CALL tui_puts
        MOV SI, filename
        MOV.B AX, [SI]
        CMP AX, 0
        JNZ .named
        MOV SI, s_untitled
.named: MOV DX, 0x0010
        MOV BX, 0x1E
        CALL tui_puts
        MOV AX, [dirty]
        CMP AX, 0
        JZ .clean
        MOV SI, s_modified
        MOV DX, 0x001E
        MOV BX, 0x1C
        CALL tui_puts
.clean: ; menu bar
        MOV DX, 0x0100
        MOV CX, 0x0150
        MOV AX, (ATTR_MENU << 8) | ' '
        CALL tui_fill
        MOV SI, s_menu
        MOV DX, 0x0101
        MOV BX, ATTR_MENU
        CALL tui_puts
        ; document text
        MOV AX, [top]
        MOV [line_ptr], AX
        MOV DX, TEXT_TOP << 8
        MOV CX, TEXT_ROWS
.row:   CALL draw_line
        ADD DX, 0x0100
        LOOP .row
        CALL draw_status
        ; message line
        MOV DX, 0x1800
        MOV CX, 0x0150
        MOV AX, 0x0020
        CALL tui_fill
        MOV SI, [msg]
        CMP SI, 0
        JZ .nomsg
        MOV DX, 0x1801
        MOV BX, ATTR_MSG
        CALL tui_puts
.nomsg: ; hardware cursor
        MOV DX, [cur_row]
        ADD DX, TEXT_TOP
        SHL DX, 8
        MOV AX, [cur_col]
        SUB AX, [left]
        OR DX, AX
        CALL tui_cursor
        RET

; draw_line: DX = row << 8; draws the line at [line_ptr] (0xFFFF = none)
;            and advances line_ptr to the next line
draw_line:
        PUSHA
        CALL tui_addr
        MOV CX, 80
        MOV SI, [line_ptr]
        CMP SI, 0xFFFF
        JZ .fill
        MOV AX, SI
        CALL line_end
        MOV [line_end_v], AX
        ADD SI, [left]
.draw:  CMP SI, [line_end_v]
        JAE .next
        MOV.B AX, [SI+buf]
        OR AX, ATTR_TEXT << 8
        MOV [DI], AX
        ADD DI, 2
        INC SI
        LOOP .draw
.next:  MOV AX, [line_end_v]
        CMP AX, [len]
        JB .more
        MOV AX, 0xFFFF
        JMP .set
.more:  INC AX
.set:   MOV [line_ptr], AX
.fill:  JCXZ .done
        MOV AX, (ATTR_TEXT << 8) | ' '
        REP STOSW
.done:  POPA
        RET

; draw_status: line/column/size/word count on row 23
draw_status:
        MOV DX, 0x1700
        MOV CX, 0x0150
        MOV AX, (ATTR_STATUS << 8) | ' '
        CALL tui_fill
        MOV BX, ATTR_STATUS
        MOV SI, s_ln
        MOV DX, 0x1701
        CALL tui_puts
        ; line number = newlines before the cursor + 1
        MOV CX, [cursor]
        MOV SI, buf
        MOV AX, 1
        JCXZ .lnd
.lnl:   MOV.B DI, [SI]
        INC SI
        CMP DI, 10
        JNZ .lnn
        INC AX
.lnn:   LOOP .lnl
.lnd:   MOV DX, 0x1705
        CALL put_number
        MOV SI, s_col
        MOV DX, 0x170C
        CALL tui_puts
        MOV AX, [cur_col]
        INC AX
        MOV DX, 0x1711
        CALL put_number
        MOV SI, s_chars
        MOV DX, 0x1718
        CALL tui_puts
        MOV AX, [len]
        MOV DX, 0x171F
        CALL put_number
        MOV SI, s_words
        MOV DX, 0x1727
        CALL tui_puts
        CALL count_words
        MOV DX, 0x172E
        CALL put_number
        MOV SI, s_ins
        MOV DX, 0x1746
        CALL tui_puts
        RET

; put_number: AX at DX with attribute BL
put_number:
        PUSH CX
        PUSH DI
        PUSH SI
        MOV DI, numbuf
        CALL utoa
        MOV SI, numbuf
        CALL tui_puts
        POP SI
        POP DI
        POP CX
        RET

; count_words: AX = number of words in the document
count_words:
        PUSH BX
        PUSH CX
        PUSH SI
        PUSH DI
        MOV AX, 0
        MOV BX, 0                   ; 1 while inside a word
        MOV SI, buf
        MOV CX, [len]
        JCXZ .d
.l:     MOV.B DI, [SI]
        INC SI
        CMP DI, ' '
        JBE .space
        CMP BX, 0
        JNZ .n
        INC AX
        MOV BX, 1
        JMP .n
.space: MOV BX, 0
.n:     LOOP .l
.d:     POP DI
        POP SI
        POP CX
        POP BX
        RET

set_message:
        MOV [msg], SI
        RET

; ------------------------------------------------------------ files
new_doc:
        MOV AX, 0
        MOV [len], AX
        MOV [cursor], AX
        MOV [top], AX
        MOV [left], AX
        MOV [dirty], AX
        MOV.B [filename], AX
        RET

cmd_new:
        CALL confirm_discard
        JC .r
        CALL new_doc
.r:     RET

; copy_word: SI -> DI, upper case, stops at blank/NUL, max 12 characters
copy_word:
        PUSH AX
        PUSH CX
        PUSH DI
        MOV CX, 12
.l:     MOV.B AX, [SI]
        CMP AX, ' '
        JBE .d
        CALL to_upper
        MOV.B [DI], AX
        INC SI
        INC DI
        LOOP .l
.d:     MOV AX, 0
        MOV.B [DI], AX
        POP DI
        POP CX
        POP AX
        RET

; load_file: read `filename` into the buffer. CF = 1 if it cannot be opened.
load_file:
        MOV DX, filename
        MOV AX, DOS_OPEN << 8
        INT INT_DOS
        JC .fail
        MOV BX, AX
        MOV CX, BUF_SIZE-1
        MOV DX, buf
        MOV AX, DOS_READ << 8
        INT INT_DOS
        MOV [len], AX
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        ; drop carriage returns
        MOV SI, buf
        MOV DI, buf
        MOV CX, [len]
        JCXZ .stripped
.s:     MOV.B AX, [SI]
        INC SI
        CMP AX, 13
        JZ .skip
        MOV.B [DI], AX
        INC DI
.skip:  LOOP .s
.stripped:
        SUB DI, buf
        MOV [len], DI
        MOV AX, 0
        MOV [cursor], AX
        MOV [top], AX
        MOV [left], AX
        MOV [dirty], AX
        CLC
        RET
.fail:  STC
        RET

msg_loaded:
        MOV DI, msgbuf
        MOV SI, s_loaded
        CALL str_copy
        CALL compose_name_size
        MOV SI, msgbuf
        CALL set_message
        RET

; compose_name_size: append "FILENAME (N bytes)" to msgbuf
compose_name_size:
        MOV DI, msgbuf
        CALL str_end
        MOV SI, filename
        CALL str_copy
        CALL str_end
        MOV SI, s_paren
        CALL str_copy
        CALL str_end
        MOV AX, [len]
        CALL utoa
        CALL str_end
        MOV SI, s_bytes
        CALL str_copy
        RET

; str_end: DI -> DI at the terminating NUL of the string at DI
str_end:
        PUSH AX
.l:     MOV.B AX, [DI]
        CMP AX, 0
        JZ .d
        INC DI
        JMP .l
.d:     POP AX
        RET

save_file:
        MOV.B AX, [filename]
        CMP AX, 0
        JNZ .named
        MOV SI, s_ask_save
        CALL ask_filename
        JC .r
.named: MOV DX, filename
        MOV AX, DOS_CREATE << 8
        INT INT_DOS
        JC .err
        MOV BX, AX
        MOV CX, [len]
        MOV DX, buf
        MOV AX, DOS_WRITE << 8
        INT INT_DOS
        JC .err
        CMP AX, [len]
        JNZ .err
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        MOV AX, 0
        MOV [dirty], AX
        MOV DI, msgbuf
        MOV SI, s_saved
        CALL str_copy
        CALL compose_name_size
        MOV SI, msgbuf
        CALL set_message
        CLC
.r:     RET
.err:   MOV SI, s_save_err
        CALL set_message
        STC
        RET

open_file:
        CALL confirm_discard
        JC .r
        MOV SI, s_ask_open
        CALL ask_filename
        JC .r
        CALL load_file
        JC .nf
        CALL msg_loaded
        RET
.nf:    CALL new_doc_keep_name
        MOV SI, s_newfile
        CALL set_message
.r:     RET

new_doc_keep_name:
        MOV AX, 0
        MOV [len], AX
        MOV [cursor], AX
        MOV [top], AX
        MOV [left], AX
        MOV [dirty], AX
        RET

; confirm_discard: if modified ask "Save changes?". CF = 1 -> cancelled
confirm_discard:
        MOV AX, [dirty]
        CMP AX, 0
        JZ .ok
        MOV SI, s_ask_discard
        CALL show_prompt
.key:   CALL tui_getkey
        CMP AX, KEY_ESC
        JZ .cancel
        AND AX, 0xFF
        CALL to_upper
        CMP AX, 'N'
        JZ .ok
        CMP AX, 'Y'
        JNZ .key
        CALL save_file
        JC .cancel
.ok:    CLC
        RET
.cancel:
        STC
        RET

quit:   CALL confirm_discard
        JC .r
        MOV AX, 0x0003
        INT INT_VIDEO
        MOV AX, DOS_EXIT << 8
        INT INT_DOS
.r:     RET

; show_prompt: SI = text on the message line (prompt colours)
show_prompt:
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH DX
        MOV DX, 0x1800
        MOV CX, 0x0150
        MOV AX, (ATTR_PROMPT << 8) | ' '
        CALL tui_fill
        MOV DX, 0x1801
        MOV BX, ATTR_PROMPT
        CALL tui_puts
        CALL str_len
        ADD DX, CX
        CALL tui_cursor
        POP DX
        POP CX
        POP BX
        POP AX
        RET

; ask_filename: SI = prompt. Edits `filename` (8.3, upper case).
;               CF = 1 when cancelled with Esc or left empty.
ask_filename:
        MOV [prompt_text], SI
        MOV DI, inbuf
        MOV AX, 0
        MOV.B [DI], AX
        MOV [inlen], AX
.draw:  MOV SI, [prompt_text]
        CALL show_prompt
        CALL str_len
        MOV DX, 0x1801
        ADD DX, CX
        MOV SI, inbuf
        MOV BX, ATTR_PROMPT
        CALL tui_puts
        MOV AX, [inlen]
        ADD DX, AX
        CALL tui_cursor
        CALL tui_getkey
        CMP AX, KEY_ESC
        JZ .cancel
        CMP AX, KEY_ENTER
        JZ .done
        CMP AX, KEY_BACKSPACE
        JZ .bs
        AND AX, 0xFF
        CMP AX, ' '
        JBE .draw
        MOV BX, [inlen]
        CMP BX, 12
        JAE .draw
        CALL to_upper
        MOV.B [BX+inbuf], AX
        INC BX
        MOV [inlen], BX
        MOV AX, 0
        MOV.B [BX+inbuf], AX
        JMP .draw
.bs:    MOV BX, [inlen]
        CMP BX, 0
        JZ .draw
        DEC BX
        MOV [inlen], BX
        MOV AX, 0
        MOV.B [BX+inbuf], AX
        JMP .draw
.done:  MOV AX, [inlen]
        CMP AX, 0
        JZ .cancel
        MOV SI, inbuf
        MOV DI, filename
        CALL str_copy
        CLC
        RET
.cancel:
        STC
        RET

        %include "lib/stdio.inc"
        %include "lib/tui.inc"

SECTION .data
s_title:      DB 0x0F, " PERRY Word", 0
s_untitled:   DB "(untitled)", 0
s_modified:   DB "[modified]", 0
s_menu:       DB "F2 Save   F3 Open   F4 New   Esc Exit   ", 0xB3, "  Arrows/Home/End/PgUp/PgDn move", 0
s_ln:         DB "Ln", 0
s_col:        DB "Col", 0
s_chars:      DB "Chars", 0
s_words:      DB "Words", 0
s_ins:        DB "INS  TXT", 0
s_newfile:    DB "New file - press F2 to save it", 0
s_loaded:     DB "Loaded ", 0
s_saved:      DB "Saved ", 0
s_paren:      DB " (", 0
s_bytes:      DB " bytes)", 0
s_full:       DB "Document is full (16 KB)", 0
s_save_err:   DB "Error: could not save the file", 0
s_ask_save:   DB "Save as: ", 0
s_ask_open:   DB "Open file: ", 0
s_ask_discard: DB "Save changes to the document? (Y/N, Esc = cancel) ", 0

SECTION .bss
filename:     RESB 16
inbuf:        RESB 16
inlen:        RESW 1
prompt_text:  RESW 1
msg:          RESW 1
msgbuf:       RESB 64
len:          RESW 1
cursor:       RESW 1
top:          RESW 1
left:         RESW 1
dirty:        RESW 1
cur_ls:       RESW 1
cur_row:      RESW 1
cur_col:      RESW 1
line_ptr:     RESW 1
line_end_v:   RESW 1
buf:          RESB BUF_SIZE
