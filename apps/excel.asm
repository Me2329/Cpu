; EXCEL.PEX - PERRY Excel, a small spreadsheet.
;
;   EXCEL [file.xls]
;
; Grid of 8 columns (A-H) x 20 rows. A cell holds up to 15 characters:
;   a number        123, -45
;   text            Rent
;   a formula       =B4+C4*2   =SUM(B4:D4)   =AVG(B4:B7)   =MIN(..) =MAX(..)
; Formulas use 16-bit signed integers, + - * / with normal precedence,
; parentheses and cell references; they are recalculated on every redraw
; (recursively, with a depth limit that reports circular references as
; #ERR).
;
; Keys: arrows move, Enter edits the cell, typing starts a new entry,
; Del clears, F2 save, F3 open, Esc quit.
; File format (.XLS): one text line per non-empty cell, e.g.  "B4=800"
;                     or "E4==SUM(B4:D4)".
        ORG 0x3000
        ENTRY main
        STACK 2048
        %include "perry.inc"

NCOLS       EQU 8
NROWS       EQU 20
NCELLS      EQU NCOLS * NROWS
CELL_SIZE   EQU 16
COL_WIDTH   EQU 9
GRID_LEFT   EQU 4
GRID_TOP    EQU 3
IOBUF_SIZE  EQU 4096
MAX_DEPTH   EQU 24

T_EMPTY     EQU 0
T_NUM       EQU 1
T_TEXT      EQU 2
T_FORMULA   EQU 3
T_ERR       EQU 4

ATTR_TITLE  EQU 0x2F
ATTR_BAR    EQU 0x70
ATTR_HEAD   EQU 0x70
ATTR_CELL   EQU 0xF0
ATTR_FORM   EQU 0xF1
ATTR_ERRC   EQU 0xF4
ATTR_SEL    EQU 0x1F
ATTR_GRIDL  EQU 0xF7
ATTR_EDIT   EQU 0x0E

SECTION .code
main:   MOV AX, 0x0003
        INT INT_VIDEO
        CALL tui_cursor_off
        MOV SI, PSP_CMDLINE
        CALL skip_spaces
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .loop
        MOV DI, filename
        CALL copy_word
        CALL load_file
        JNC .loop
        MOV SI, s_newfile
        MOV [msg], SI
.loop:  CALL redraw
        CALL tui_getkey
        MOV BX, [editing]
        CMP BX, 0
        JZ .nav
        CALL edit_key
        JMP .loop
.nav:   CALL nav_key
        JMP .loop

; ------------------------------------------------------------ keys
nav_key:
        MOV BX, 0
        MOV [msg], BX
        CMP AX, KEY_ESC
        JZ quit
        CMP AX, KEY_F2
        JZ save_file
        CMP AX, KEY_F3
        JZ open_file
        CMP AX, KEY_UP
        JZ move_up
        CMP AX, KEY_DOWN
        JZ move_down
        CMP AX, KEY_LEFT
        JZ move_left
        CMP AX, KEY_RIGHT
        JZ move_right
        CMP AX, KEY_TAB
        JZ move_right
        CMP AX, KEY_DEL
        JZ clear_cell
        CMP AX, KEY_ENTER
        JZ .edit_existing
        AND AX, 0xFF
        CMP AX, ' '
        JB .r
        CMP AX, 127
        JAE .r
        ; start a fresh entry with this character
        MOV.B [editbuf], AX
        MOV BX, 0
        MOV.B [editbuf+1], BX
        MOV BX, 1
        MOV [editlen], BX
        MOV [editing], BX
.r:     RET
.edit_existing:
        MOV AX, [cur]
        CALL cell_ptr
        MOV DI, editbuf
        CALL str_copy
        CALL str_len
        MOV [editlen], CX
        MOV AX, 1
        MOV [editing], AX
        RET

edit_key:
        CMP AX, KEY_ESC
        JZ .cancel
        CMP AX, KEY_ENTER
        JZ .enter
        CMP AX, KEY_UP
        JZ .commit_move
        CMP AX, KEY_DOWN
        JZ .commit_move
        CMP AX, KEY_LEFT
        JZ .commit_move
        CMP AX, KEY_RIGHT
        JZ .commit_move
        CMP AX, KEY_TAB
        JZ .commit_move
        CMP AX, KEY_BACKSPACE
        JZ .bs
        AND AX, 0xFF
        CMP AX, ' '
        JB .r
        CMP AX, 127
        JAE .r
        MOV BX, [editlen]
        CMP BX, CELL_SIZE-1
        JAE .r
        MOV.B [BX+editbuf], AX
        INC BX
        MOV [editlen], BX
        MOV AX, 0
        MOV.B [BX+editbuf], AX
.r:     RET
.bs:    MOV BX, [editlen]
        CMP BX, 0
        JZ .r
        DEC BX
        MOV [editlen], BX
        MOV AX, 0
        MOV.B [BX+editbuf], AX
        RET
.cancel:
        MOV AX, 0
        MOV [editing], AX
        RET
.enter: CALL commit
        CALL move_down
        RET
.commit_move:
        PUSH AX
        CALL commit
        POP AX
        CALL nav_key
        RET

commit: MOV AX, [cur]
        CALL cell_ptr
        MOV DI, SI
        MOV SI, editbuf
        CALL str_copy
        MOV AX, 0
        MOV [editing], AX
        MOV AX, 1
        MOV [dirty], AX
        RET

clear_cell:
        MOV AX, [cur]
        CALL cell_ptr
        MOV AX, 0
        MOV.B [SI], AX
        MOV AX, 1
        MOV [dirty], AX
        RET

move_up:
        MOV AX, [cur]
        CMP AX, NCOLS
        JB .r
        SUB AX, NCOLS
        MOV [cur], AX
.r:     RET

move_down:
        MOV AX, [cur]
        ADD AX, NCOLS
        CMP AX, NCELLS
        JAE .r
        MOV [cur], AX
.r:     RET

move_left:
        MOV AX, [cur]
        TEST AX, NCOLS-1
        JZ .r
        DEC AX
        MOV [cur], AX
.r:     RET

move_right:
        MOV AX, [cur]
        MOV BX, AX
        AND BX, NCOLS-1
        CMP BX, NCOLS-1
        JZ .r
        INC AX
        MOV [cur], AX
.r:     RET

; cell_ptr: AX = cell index -> SI = cell text
cell_ptr:
        MOV SI, AX
        SHL SI, 4
        ADD SI, cells
        RET

; ------------------------------------------------------------ evaluation
; eval_top: AX = cell index -> AX = value, DX = type
eval_top:
        PUSH BX
        MOV BX, 0
        MOV [err], BX
        MOV [depth], BX
        MOV BX, AX
        CALL eval_cell
        POP BX
        RET

; eval_cell: BX = cell index -> AX = value, DX = type (T_*)
;            sets [err] on errors; re-entrant (formulas recurse into it)
eval_cell:
        PUSH SI
        PUSH BX
        MOV AX, [depth]
        INC AX
        MOV [depth], AX
        CMP AX, MAX_DEPTH
        JA .circ
        MOV SI, BX
        SHL SI, 4
        ADD SI, cells
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .empty
        CMP AX, '='
        JZ .formula
        PUSH SI
        CALL atoi
        MOV.B DX, [SI]
        POP SI
        JC .text
        CMP DX, 0
        JNZ .text
        MOV DX, T_NUM
        JMP .out
.formula:
        INC SI
        CALL parse_expr
        CALL skip_spaces
        MOV.B DX, [SI]
        CMP DX, 0
        JZ .fok
        MOV DX, 1
        MOV [err], DX
.fok:   MOV DX, [err]
        CMP DX, 0
        JNZ .error
        MOV DX, T_FORMULA
        JMP .out
.text:  MOV AX, 0
        MOV DX, T_TEXT
        JMP .out
.empty: MOV AX, 0
        MOV DX, T_EMPTY
        JMP .out
.circ:  MOV DX, 1
        MOV [err], DX
.error: MOV AX, 0
        MOV DX, T_ERR
.out:   PUSH AX
        MOV AX, [depth]
        DEC AX
        MOV [depth], AX
        POP AX
        POP BX
        POP SI
        RET

; parse_expr: sum := product { (+|-) product }        SI -> AX
parse_expr:
        PUSH BX
        PUSH CX
        CALL parse_product
.loop:  CALL skip_spaces
        MOV.B BX, [SI]
        CMP BX, '+'
        JZ .op
        CMP BX, '-'
        JZ .op
        POP CX
        POP BX
        RET
.op:    INC SI
        PUSH AX
        PUSH BX
        CALL parse_product
        POP BX
        POP CX
        CMP BX, '+'
        JNZ .sub
        ADD CX, AX
        JMP .st
.sub:   SUB CX, AX
.st:    MOV AX, CX
        JMP .loop

; parse_product: product := term { (*|/) term }        SI -> AX
parse_product:
        PUSH BX
        PUSH CX
        PUSH DX
        CALL parse_term
.loop:  CALL skip_spaces
        MOV.B BX, [SI]
        CMP BX, '*'
        JZ .op
        CMP BX, '/'
        JZ .op
        POP DX
        POP CX
        POP BX
        RET
.op:    INC SI
        PUSH AX
        PUSH BX
        CALL parse_term
        POP BX
        POP CX
        CMP BX, '*'
        JNZ .div
        IMUL CX, AX
        JMP .st
.div:   CMP AX, 0
        JZ .div0
        IDIV CX, AX
        JMP .st
.div0:  MOV CX, 1
        MOV [err], CX
        MOV CX, 0
.st:    MOV AX, CX
        JMP .loop

; parse_term: number | -term | (expr) | cellref | FUNC(range)
parse_term:
        PUSH BX
        PUSH CX
        CALL skip_spaces
        MOV.B AX, [SI]
        CMP AX, '('
        JNZ .notpar
        INC SI
        CALL parse_expr
        CALL skip_spaces
        MOV.B BX, [SI]
        CMP BX, ')'
        JNZ .err
        INC SI
        JMP .done
.notpar:
        CMP AX, '-'
        JNZ .notneg
        INC SI
        CALL parse_term
        NEG AX
        JMP .done
.notneg:
        CMP AX, '0'
        JB .notnum
        CMP AX, '9'
        JA .notnum
        CALL atoi
        JMP .done
.notnum:
        CALL to_upper
        CMP AX, 'A'
        JB .err
        CMP AX, 'Z'
        JA .err
        MOV.B BX, [SI+3]
        CMP BX, '('
        JNZ .ref
        CALL parse_function
        JMP .done
.ref:   CALL parse_ref
        JC .err
        PUSH DX
        CALL eval_cell
        CMP DX, T_ERR
        POP DX
        JNZ .done
        MOV AX, 0
        JMP .done
.err:   MOV AX, 1
        MOV [err], AX
        MOV AX, 0
.done:  POP CX
        POP BX
        RET

; parse_ref: SI at "B12" -> BX = cell index, SI advanced; CF = 1 if invalid
parse_ref:
        PUSH AX
        MOV.B AX, [SI]
        CALL to_upper
        SUB AX, 'A'
        JC .bad
        CMP AX, NCOLS
        JAE .bad
        MOV BX, AX
        INC SI
        MOV.B AX, [SI]
        CMP AX, '0'
        JB .bad
        CMP AX, '9'
        JA .bad
        CALL atoi
        CMP AX, 1
        JL .bad
        CMP AX, NROWS
        JG .bad
        DEC AX
        SHL AX, 3
        ADD BX, AX
        POP AX
        CLC
        RET
.bad:   POP AX
        STC
        RET

; parse_function: SI at "SUM(A1:B3)" -> AX. Locals live on the stack
; (BP frame) because evaluation can recurse into another function.
F_ID    EQU -2
F_R1    EQU -4
F_R2    EQU -6
F_C1    EQU -8
F_C2    EQU -10
F_SUM   EQU -12
F_CNT   EQU -14
F_MIN   EQU -16
F_MAX   EQU -18
F_R     EQU -20
F_C     EQU -22
parse_function:
        PUSH BX
        PUSH CX
        PUSH DX
        PUSH DI
        PUSH BP
        MOV BP, SP
        SUB SP, 24
        MOV DI, func_names
        MOV CX, 0
.find:  CMP CX, 4
        JAE .bad
        CALL match3
        JZ .found
        ADD DI, 4
        INC CX
        JMP .find
.found: MOV [BP+F_ID], CX
        ADD SI, 4
        CALL parse_ref
        JC .bad
        MOV AX, BX
        MOV.B DX, [SI]
        CMP DX, ':'
        JNZ .bad
        INC SI
        PUSH AX
        CALL parse_ref
        POP AX
        JC .bad
        MOV.B DX, [SI]
        CMP DX, ')'
        JNZ .bad
        INC SI
        MOV CX, AX
        SHR CX, 3
        MOV [BP+F_R1], CX
        AND AX, NCOLS-1
        MOV [BP+F_C1], AX
        MOV CX, BX
        SHR CX, 3
        MOV [BP+F_R2], CX
        AND BX, NCOLS-1
        MOV [BP+F_C2], BX
        MOV AX, [BP+F_R1]           ; normalise the corners
        CMP AX, [BP+F_R2]
        JBE .rok
        MOV CX, [BP+F_R2]
        MOV [BP+F_R2], AX
        MOV [BP+F_R1], CX
.rok:   MOV AX, [BP+F_C1]
        CMP AX, [BP+F_C2]
        JBE .cok
        MOV CX, [BP+F_C2]
        MOV [BP+F_C2], AX
        MOV [BP+F_C1], CX
.cok:   MOV AX, 0
        MOV [BP+F_SUM], AX
        MOV [BP+F_CNT], AX
        MOV AX, 0x7FFF
        MOV [BP+F_MIN], AX
        MOV AX, 0x8000
        MOV [BP+F_MAX], AX
        MOV AX, [BP+F_R1]
        MOV [BP+F_R], AX
.rloop: MOV AX, [BP+F_C1]
        MOV [BP+F_C], AX
.cloop: MOV BX, [BP+F_R]
        SHL BX, 3
        ADD BX, [BP+F_C]
        CALL eval_cell
        CMP DX, T_NUM
        JZ .acc
        CMP DX, T_FORMULA
        JNZ .skip
.acc:   MOV CX, [BP+F_SUM]
        ADD CX, AX
        MOV [BP+F_SUM], CX
        MOV CX, [BP+F_CNT]
        INC CX
        MOV [BP+F_CNT], CX
        CMP AX, [BP+F_MIN]
        JGE .nmin
        MOV [BP+F_MIN], AX
.nmin:  CMP AX, [BP+F_MAX]
        JLE .skip
        MOV [BP+F_MAX], AX
.skip:  MOV AX, [BP+F_C]
        INC AX
        MOV [BP+F_C], AX
        CMP AX, [BP+F_C2]
        JBE .cloop
        MOV AX, [BP+F_R]
        INC AX
        MOV [BP+F_R], AX
        CMP AX, [BP+F_R2]
        JBE .rloop
        MOV CX, [BP+F_ID]
        MOV AX, [BP+F_SUM]
        CMP CX, 0
        JZ .ret                     ; SUM
        MOV DX, [BP+F_CNT]
        CMP DX, 0
        JZ .zero
        CMP CX, 1
        JNZ .minmax
        MOV CX, DX                  ; AVG = SUM / COUNT
        IDIV AX, CX
        JMP .ret
.minmax:
        MOV AX, [BP+F_MIN]
        CMP CX, 2
        JZ .ret                     ; MIN
        MOV AX, [BP+F_MAX]          ; MAX
        JMP .ret
.zero:  MOV AX, 0
        JMP .ret
.bad:   MOV AX, 1
        MOV [err], AX
        MOV AX, 0
.ret:   MOV SP, BP
        POP BP
        POP DI
        POP DX
        POP CX
        POP BX
        RET

; match3: compare 3 characters at SI (case-insensitive) with DI -> ZF
match3: PUSH AX
        PUSH BX
        PUSH CX
        PUSH SI
        PUSH DI
        MOV CX, 3
.l:     MOV.B AX, [SI]
        CALL to_upper
        MOV.B BX, [DI]
        CMP AX, BX
        JNZ .d
        INC SI
        INC DI
        LOOP .l
        CMP AX, AX
.d:     POP DI
        POP SI
        POP CX
        POP BX
        POP AX
        RET

; ------------------------------------------------------------ display
redraw: MOV DX, 0x0000              ; title
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
.named: MOV DX, 0x0011
        MOV BX, 0x2E
        CALL tui_puts
        MOV AX, [dirty]
        CMP AX, 0
        JZ .clean
        MOV SI, s_modified
        MOV DX, 0x001F
        MOV BX, 0x2C
        CALL tui_puts
.clean: CALL draw_formula_bar
        ; column headers
        MOV DX, 0x0200
        MOV CX, 0x0150
        MOV AX, (ATTR_HEAD << 8) | ' '
        CALL tui_fill
        MOV CX, 0
.hdr:   MOV AX, CX
        MOV BX, COL_WIDTH
        MUL AX, BX
        ADD AX, GRID_LEFT + 4
        MOV DX, 0x0200
        OR DX, AX
        MOV AX, CX
        ADD AX, 'A'
        MOV BX, ATTR_HEAD
        CALL tui_putc
        INC CX
        CMP CX, NCOLS
        JB .hdr
        ; grid background (right margin)
        MOV DX, (GRID_TOP << 8) | 76
        MOV CX, (NROWS << 8) | 4
        MOV AX, (ATTR_HEAD << 8) | ' '
        CALL tui_fill
        ; rows
        MOV CX, 0
.row:   CALL draw_row_header
        INC CX
        CMP CX, NROWS
        JB .row
        MOV AX, 0
.cell:  CALL draw_cell
        INC AX
        CMP AX, NCELLS
        JB .cell
        ; help + message lines
        MOV DX, 0x1700
        MOV CX, 0x0150
        MOV AX, (ATTR_BAR << 8) | ' '
        CALL tui_fill
        MOV SI, s_help
        MOV DX, 0x1701
        MOV BX, ATTR_BAR
        CALL tui_puts
        MOV DX, 0x1800
        MOV CX, 0x0150
        MOV AX, 0x0020
        CALL tui_fill
        MOV SI, [msg]
        CMP SI, 0
        JZ .done
        MOV DX, 0x1801
        MOV BX, 0x0E
        CALL tui_puts
.done:  RET

; draw_row_header: CX = row
draw_row_header:
        PUSHA
        MOV DX, CX
        ADD DX, GRID_TOP
        SHL DX, 8
        PUSH CX
        MOV CX, 0x0104
        MOV AX, (ATTR_HEAD << 8) | ' '
        CALL tui_fill
        POP AX
        INC AX
        MOV DI, numbuf
        CALL utoa
        MOV SI, numbuf
        ADD DX, 3
        SUB DX, CX
        MOV BX, ATTR_HEAD
        CALL tui_puts
        POPA
        RET

; draw_cell: AX = cell index
draw_cell:
        PUSHA
        MOV [dc_idx], AX
        MOV BX, AX                  ; screen position
        SHR BX, 3
        ADD BX, GRID_TOP
        SHL BX, 8
        AND AX, NCOLS-1
        MOV CX, COL_WIDTH
        MUL AX, CX
        ADD AX, GRID_LEFT
        OR BX, AX
        MOV [dc_pos], BX
        MOV BX, ATTR_CELL
        MOV AX, [dc_idx]
        CMP AX, [cur]
        JNZ .a
        MOV BX, ATTR_SEL
.a:     MOV [dc_attr], BX
        MOV DX, [dc_pos]            ; background + grid separator
        MOV AX, BX
        SHL AX, 8
        OR AX, ' '
        MOV CX, 0x0100 | (COL_WIDTH-1)
        CALL tui_fill
        ADD DX, COL_WIDTH-1
        MOV AX, 0xB3
        MOV BX, ATTR_GRIDL
        CALL tui_putc
        MOV AX, [dc_idx]
        CALL eval_top
        CMP DX, T_EMPTY
        JZ .done
        CMP DX, T_TEXT
        JZ .text
        CMP DX, T_ERR
        JZ .error
        ; number / formula: right aligned
        MOV BX, [dc_attr]
        CMP BX, ATTR_SEL
        JZ .attr_ok
        CMP DX, T_FORMULA
        JNZ .attr_ok
        MOV BX, ATTR_FORM
.attr_ok:
        MOV DI, numbuf
        CALL itoa
        MOV SI, numbuf
        JMP .right
.error: MOV SI, s_err
        MOV CX, 4
        MOV BX, [dc_attr]
        CMP BX, ATTR_SEL
        JZ .right
        MOV BX, ATTR_ERRC
.right: MOV DX, [dc_pos]
        ADD DX, COL_WIDTH-1
        SUB DX, CX
        CALL tui_puts
        JMP .done
.text:  MOV AX, [dc_idx]
        CALL cell_ptr
        MOV DX, [dc_pos]
        MOV BX, [dc_attr]
        MOV CX, COL_WIDTH-1
        CALL tui_putsn
.done:  POPA
        RET

draw_formula_bar:
        MOV DX, 0x0100
        MOV CX, 0x0150
        MOV AX, (ATTR_BAR << 8) | ' '
        CALL tui_fill
        ; cell name, e.g. "C7"
        MOV AX, [cur]
        AND AX, NCOLS-1
        ADD AX, 'A'
        MOV DX, 0x0101
        MOV BX, 0x70
        CALL tui_putc
        MOV AX, [cur]
        SHR AX, 3
        INC AX
        MOV DI, numbuf
        CALL utoa
        MOV SI, numbuf
        MOV DX, 0x0102
        CALL tui_puts
        MOV AX, 0xB3
        MOV DX, 0x0106
        CALL tui_putc
        MOV AX, [editing]
        CMP AX, 0
        JZ .show
        MOV DX, 0x0108              ; edit field with cursor block
        MOV CX, 0x0110
        MOV AX, (ATTR_EDIT << 8) | ' '
        CALL tui_fill
        MOV SI, editbuf
        MOV BX, ATTR_EDIT
        CALL tui_puts
        MOV AX, [editlen]
        ADD DX, AX
        MOV AX, 0xDB
        CALL tui_putc
        RET
.show:  MOV AX, [cur]
        CALL cell_ptr
        MOV DX, 0x0108
        MOV BX, 0x70
        CALL tui_puts
        ; computed value of formulas
        MOV.B AX, [SI]
        CMP AX, '='
        JNZ .r
        MOV AX, [cur]
        CALL eval_top
        MOV SI, s_arrow
        MOV DX, 0x011C
        MOV BX, 0x71
        CALL tui_puts
        CMP DX, T_ERR
        JZ .e
        MOV DI, numbuf
        CALL itoa
        MOV SI, numbuf
.e2:    MOV DX, 0x011F
        CALL tui_puts
.r:     RET
.e:     MOV SI, s_err_long
        JMP .e2

; ------------------------------------------------------------ files
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

clear_all:
        MOV DI, cells
        MOV CX, NCELLS * CELL_SIZE / 2
        MOV AX, 0
        REP STOSW
        RET

; load_file: parse "REF=text" lines from `filename`. CF = 1 if missing
load_file:
        MOV DX, filename
        MOV AX, DOS_OPEN << 8
        INT INT_DOS
        JC .fail
        MOV BX, AX
        MOV CX, IOBUF_SIZE-1
        MOV DX, iobuf
        MOV AX, DOS_READ << 8
        INT INT_DOS
        MOV DI, AX
        MOV AX, 0
        MOV.B [DI+iobuf], AX
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        CALL clear_all
        MOV SI, iobuf
.line:  MOV.B AX, [SI]
        CMP AX, 0
        JZ .done
        CMP AX, ' '
        JA .parse
        INC SI
        JMP .line
.parse: CALL parse_ref
        JC .skipline
        MOV.B AX, [SI]
        CMP AX, '='
        JNZ .skipline
        INC SI
        MOV DI, BX
        SHL DI, 4
        ADD DI, cells
        MOV CX, CELL_SIZE-1
.copy:  MOV.B AX, [SI]
        CMP AX, 10
        JZ .term
        CMP AX, 13
        JZ .term
        CMP AX, 0
        JZ .term
        MOV.B [DI], AX
        INC DI
        INC SI
        LOOP .copy
.term:  MOV AX, 0
        MOV.B [DI], AX
.skipline:
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .done
        INC SI
        CMP AX, 10
        JNZ .skipline
        JMP .line
.done:  MOV AX, 0
        MOV [cur], AX
        MOV [dirty], AX
        MOV SI, s_loaded
        MOV [msg], SI
        CLC
        RET
.fail:  STC
        RET

save_file:
        MOV.B AX, [filename]
        CMP AX, 0
        JNZ .named
        MOV SI, s_ask_save
        CALL ask_filename
        JC .r
.named: MOV DI, iobuf
        MOV BX, 0
.cell:  MOV AX, BX
        CALL cell_ptr
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .next
        MOV AX, BX
        AND AX, NCOLS-1
        ADD AX, 'A'
        MOV.B [DI], AX
        INC DI
        MOV AX, BX
        SHR AX, 3
        INC AX
        CALL utoa
        ADD DI, CX
        MOV AX, '='
        MOV.B [DI], AX
        INC DI
.copy:  MOV.B AX, [SI]
        CMP AX, 0
        JZ .eol
        MOV.B [DI], AX
        INC SI
        INC DI
        JMP .copy
.eol:   MOV AX, 10
        MOV.B [DI], AX
        INC DI
.next:  INC BX
        CMP BX, NCELLS
        JB .cell
        SUB DI, iobuf
        MOV [save_len], DI
        MOV DX, filename
        MOV AX, DOS_CREATE << 8
        INT INT_DOS
        JC .err
        MOV BX, AX
        MOV CX, [save_len]
        MOV DX, iobuf
        MOV AX, DOS_WRITE << 8
        INT INT_DOS
        JC .err
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        MOV AX, 0
        MOV [dirty], AX
        MOV SI, s_saved
        MOV [msg], SI
        CLC
.r:     RET
.err:   MOV SI, s_save_err
        MOV [msg], SI
        STC
        RET

open_file:
        CALL confirm_discard
        JC .r
        MOV SI, s_ask_open
        CALL ask_filename
        JC .r
        CALL load_file
        JNC .r
        CALL clear_all
        MOV SI, s_newfile
        MOV [msg], SI
.r:     RET

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

show_prompt:
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH DX
        MOV DX, 0x1800
        MOV CX, 0x0150
        MOV AX, 0x4F20
        CALL tui_fill
        MOV DX, 0x1801
        MOV BX, 0x4F
        CALL tui_puts
        POP DX
        POP CX
        POP BX
        POP AX
        RET

; ask_filename: SI = prompt -> filename. CF = 1 if cancelled
ask_filename:
        MOV [prompt_text], SI
        MOV AX, 0
        MOV [inlen], AX
        MOV.B [inbuf], AX
.draw:  MOV SI, [prompt_text]
        CALL show_prompt
        CALL str_len
        MOV DX, 0x1801
        ADD DX, CX
        MOV SI, inbuf
        MOV BX, 0x4F
        CALL tui_puts
        MOV AX, [inlen]
        ADD DX, AX
        MOV AX, 0xDB
        CALL tui_putc
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
func_names:   DB "SUM", 0, "AVG", 0, "MIN", 0, "MAX", 0
s_title:      DB 0xFE, " PERRY Excel", 0
s_untitled:   DB "(untitled)", 0
s_modified:   DB "[modified]", 0
s_help:       DB 0x18, 0x19, 0x1B, 0x1A, " Move  Enter Edit  Type to enter  Del Clear  F2 Save  F3 Open  Esc Exit", 0
s_err:        DB "#ERR", 0
s_err_long:   DB "#ERR (bad formula or circular reference)", 0
s_arrow:      DB " = ", 0
s_newfile:    DB "New spreadsheet - press F2 to save it", 0
s_loaded:     DB "Spreadsheet loaded", 0
s_saved:      DB "Spreadsheet saved", 0
s_save_err:   DB "Error: could not save the file", 0
s_ask_save:   DB "Save as: ", 0
s_ask_open:   DB "Open file: ", 0
s_ask_discard: DB "Save changes? (Y/N, Esc = cancel) ", 0

SECTION .bss
filename:     RESB 16
inbuf:        RESB 16
inlen:        RESW 1
prompt_text:  RESW 1
editbuf:      RESB CELL_SIZE + 2
editlen:      RESW 1
editing:      RESW 1
msg:          RESW 1
cur:          RESW 1
dirty:        RESW 1
err:          RESW 1
depth:        RESW 1
save_len:     RESW 1
dc_idx:       RESW 1
dc_pos:       RESW 1
dc_attr:      RESW 1
cells:        RESB NCELLS * CELL_SIZE
iobuf:        RESB IOBUF_SIZE
