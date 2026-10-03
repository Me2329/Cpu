; PAINT.PEX - PERRY Paint, a mouse-driven graphics editor (VGA mode 13h).
;
;   PAINT [file.img]
;
; Left button paints with the selected colour, right button erases.
; Click a palette swatch to pick a colour.
; Keys: 1-8 brush size, +/- brush size, C clear, S save, L load, Esc quit.
;
; Pixels are written directly into the banked VGA window: the 64000-byte
; framebuffer is seen through 0xA000-0xAFFF, 4 KB at a time, and the bank
; is selected with OUT 0x3CD. Mouse input comes from INT 33h. The toolbar
; colour is programmed through the VGA DAC ports 0x3C8/0x3C9.
; .IMG files are the raw 320x180 canvas (57600 bytes), written straight
; out of the VGA window bank by bank.
        ORG 0x3000
        ENTRY main
        STACK 1024
        PEXFLAGS 1                  ; uses graphics mode
        %include "perry.inc"

CANVAS_H    EQU 180
CANVAS_SIZE EQU 320 * CANVAS_H
BAR_Y       EQU 180
SWATCH_Y    EQU 182
SWATCH_W    EQU 12
TEXT_Y      EQU 191
BAR_COLOR   EQU 250                 ; palette entry reprogrammed via the DAC
PAPER       EQU WHITE

SECTION .code
main:   MOV AX, 0x0013              ; 320x200 256 colours
        INT INT_VIDEO
        ; program palette entry BAR_COLOR = steel blue (6-bit DAC values)
        MOV AX, BAR_COLOR
        OUT PORT_DAC_WINDEX, AX
        MOV AX, 12
        OUT PORT_DAC_DATA, AX
        MOV AX, 20
        OUT PORT_DAC_DATA, AX
        MOV AX, 34
        OUT PORT_DAC_DATA, AX
        MOV AX, 0xFFFF
        MOV [cur_bank], AX
        MOV AX, BLACK
        MOV [color], AX
        MOV AX, 2
        MOV [brush], AX
        ; file name from the command line (default PICTURE.IMG)
        MOV SI, PSP_CMDLINE
        CALL skip_spaces
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .default
        MOV DI, filename
        CALL copy_word
        JMP .named
.default:
        MOV SI, s_default
        MOV DI, filename
        CALL str_copy
.named: CALL clear_canvas
        CALL load_image             ; ignore errors: new picture
        CALL draw_toolbar
        MOV AX, 0                   ; mouse: reset + show
        INT INT_MOUSE
        MOV AX, 1
        INT INT_MOUSE

main_loop:
        MOV AX, 0x0100              ; key waiting?
        INT INT_KEYBOARD
        JZ .mouse
        MOV AX, 0
        INT INT_KEYBOARD
        CALL handle_key
.mouse: MOV AX, 3
        INT INT_MOUSE               ; BX = buttons, CX = x, DX = y
        MOV [mx], CX
        MOV [my], DX
        MOV [buttons], BX
        TEST BX, 3
        JZ .up
        CMP DX, CANVAS_H
        JAE .bar
        MOV AX, [color]             ; left = colour, right = eraser
        TEST BX, 1
        JNZ .c
        MOV AX, PAPER
.c:     MOV [pen], AX
        MOV AX, [was_down]
        CMP AX, 0
        JZ .dot
        CALL draw_stroke            ; line from the previous sample
        JMP .down
.dot:   MOV CX, [mx]
        MOV DX, [my]
        CALL plot_brush
.down:  MOV AX, 1
        MOV [was_down], AX
        MOV AX, [mx]
        MOV [lx], AX
        MOV AX, [my]
        MOV [ly], AX
        JMP .idle
.bar:   CALL toolbar_click
.up:    MOV AX, 0
        MOV [was_down], AX
.idle:  HLT                         ; sleep until the next 70 Hz timer tick
        JMP main_loop

handle_key:
        AND AX, 0xFF
        CALL to_upper
        CMP AX, 27
        JZ quit
        CMP AX, 'C'
        JZ .clear
        CMP AX, 'S'
        JZ .save
        CMP AX, 'L'
        JZ .load
        CMP AX, '+'
        JZ .bigger
        CMP AX, '='
        JZ .bigger
        CMP AX, '-'
        JZ .smaller
        CMP AX, '1'
        JB .r
        CMP AX, '8'
        JA .r
        SUB AX, '0'
        MOV [brush], AX
        JMP .tb
.bigger:
        MOV AX, [brush]
        CMP AX, 8
        JAE .r
        INC AX
        MOV [brush], AX
        JMP .tb
.smaller:
        MOV AX, [brush]
        CMP AX, 1
        JBE .r
        DEC AX
        MOV [brush], AX
        JMP .tb
.clear: CALL clear_canvas
        JMP .tb
.save:  CALL save_image
        MOV SI, s_saved
        JNC .msg
        MOV SI, s_error
.msg:   MOV [status], SI
        JMP .tb
.load:  CALL load_image
        MOV SI, s_loaded
        JNC .msg
        MOV SI, s_error
        JMP .msg
.tb:    CALL draw_toolbar
.r:     RET

quit:   MOV AX, 2
        INT INT_MOUSE
        MOV AX, 0x0003
        INT INT_VIDEO
        MOV AX, DOS_EXIT << 8
        INT INT_DOS

; ------------------------------------------------------------ drawing
; put_pixel: CX = x, DX = y, AX = colour. Clipped to the canvas.
; Writes straight into the VGA window, switching banks when needed.
put_pixel:
        CMP CX, 320
        JAE .r
        CMP DX, CANVAS_H
        JAE .r
        PUSH BX
        PUSH DI
        MOV BX, DX                  ; offset = y*320 + x = y*256 + y*64 + x
        SHL BX, 8
        MOV DI, DX
        SHL DI, 6
        ADD BX, DI
        ADD BX, CX
        MOV DI, BX
        SHR DI, 12                  ; bank = offset / 4096
        CMP DI, [cur_bank]
        JZ .same
        MOV [cur_bank], DI
        OUT PORT_VGA_BANK, DI
.same:  AND BX, VGA_BANK_SIZE-1
        MOV.B [BX+VGA_WINDOW], AX
        POP DI
        POP BX
.r:     RET

; plot_brush: square brush of [brush] pixels centred on CX, DX with [pen]
plot_brush:
        PUSHA
        MOV BX, [brush]
        MOV SI, BX
        SHR SI, 1
        SUB CX, SI                  ; top-left corner
        SUB DX, SI
        MOV AX, [pen]
        MOV DI, BX                  ; rows left
.row:   PUSH CX
        MOV SI, BX                  ; columns left
.col:   CALL put_pixel
        INC CX
        DEC SI
        JNZ .col
        POP CX
        INC DX
        DEC DI
        JNZ .row
        POPA
        RET

; draw_stroke: Bresenham line from (lx,ly) to (mx,my) with the brush
draw_stroke:
        PUSHA
        MOV AX, [lx]
        MOV [x0], AX
        MOV AX, [ly]
        MOV [y0], AX
        MOV AX, [mx]                ; dx = |x1-x0|, sx = sign
        SUB AX, [x0]
        MOV BX, 1
        JGE .px
        NEG AX
        MOV BX, -1
.px:    MOV [ddx], AX
        MOV [sx], BX
        MOV AX, [my]                ; dy = -|y1-y0|, sy = sign
        SUB AX, [y0]
        MOV BX, 1
        JGE .py
        NEG AX
        MOV BX, -1
.py:    NEG AX
        MOV [ddy], AX
        MOV [sy], BX
        MOV AX, [ddx]
        ADD AX, [ddy]
        MOV [lerr], AX
.step:  MOV CX, [x0]
        MOV DX, [y0]
        CALL plot_brush
        CMP CX, [mx]
        JNZ .more
        CMP DX, [my]
        JZ .done
.more:  MOV AX, [lerr]
        SHL AX, 1                   ; e2 = 2*err
        CMP AX, [ddy]
        JL .noy
        MOV BX, [lerr]
        ADD BX, [ddy]
        MOV [lerr], BX
        MOV BX, [x0]
        ADD BX, [sx]
        MOV [x0], BX
.noy:   CMP AX, [ddx]
        JG .step
        MOV BX, [lerr]
        ADD BX, [ddx]
        MOV [lerr], BX
        MOV BX, [y0]
        ADD BX, [sy]
        MOV [y0], BX
        JMP .step
.done:  POPA
        RET

; clear_canvas: fill rows 0..179 with paper colour, bank by bank
clear_canvas:
        PUSHA
        MOV BX, 0                   ; bank
        MOV DX, CANVAS_SIZE         ; bytes left
.bank:  OUT PORT_VGA_BANK, BX
        MOV CX, VGA_BANK_SIZE
        CMP DX, CX
        JAE .full
        MOV CX, DX
.full:  SUB DX, CX
        MOV DI, VGA_WINDOW
        MOV AX, PAPER
        REP STOSB
        INC BX
        CMP DX, 0
        JNZ .bank
        MOV AX, 0xFFFF
        MOV [cur_bank], AX
        POPA
        RET

; ------------------------------------------------------------ toolbar
draw_toolbar:
        PUSHA
        MOV CX, 0                   ; background (INT 10h AH=43h fill rect)
        MOV DX, BAR_Y
        MOV SI, 320
        MOV DI, 20
        MOV BX, BAR_COLOR
        MOV AX, 0x4300
        INT INT_VIDEO
        MOV BX, 0                   ; 16 colour swatches
.sw:    MOV AX, BX
        MOV CX, SWATCH_W
        MUL AX, CX
        ADD AX, 2
        MOV CX, AX
        MOV DX, SWATCH_Y
        MOV SI, SWATCH_W-2
        MOV DI, 8
        PUSH BX
        MOV AX, 0x4300
        INT INT_VIDEO
        POP BX
        INC BX
        CMP BX, 16
        JB .sw
        ; current colour (with white frame)
        MOV CX, 200
        MOV DX, SWATCH_Y-1
        MOV SI, 18
        MOV DI, 10
        MOV BX, WHITE
        MOV AX, 0x4300
        INT INT_VIDEO
        MOV CX, 201
        MOV DX, SWATCH_Y
        MOV SI, 16
        MOV DI, 8
        MOV BX, [color]
        MOV AX, 0x4300
        INT INT_VIDEO
        ; brush size "SZ n"
        MOV AX, [brush]
        ADD AX, '0'
        MOV.B [s_size+3], AX
        MOV SI, s_size
        MOV CX, 226
        MOV DX, SWATCH_Y
        MOV BX, (BAR_COLOR << 8) | YELLOW
        MOV AX, 0x4200
        INT INT_VIDEO
        ; help text or status message
        MOV SI, [status]
        CMP SI, 0
        JNZ .text
        MOV SI, s_help
.text:  MOV CX, 2
        MOV DX, TEXT_Y
        MOV BX, (BAR_COLOR << 8) | WHITE
        MOV AX, 0x4200
        INT INT_VIDEO
        MOV AX, 0
        MOV [status], AX
        POPA
        RET

; toolbar_click: pick a palette colour
toolbar_click:
        MOV AX, [buttons]
        TEST AX, 1
        JZ .r
        MOV AX, [my]
        CMP AX, SWATCH_Y
        JB .r
        CMP AX, SWATCH_Y+8
        JAE .r
        MOV AX, [mx]
        SUB AX, 2
        JC .r
        MOV CX, SWATCH_W
        DIV AX, CX
        CMP AX, 16
        JAE .r
        MOV [color], AX
        CALL draw_toolbar
.r:     RET

; ------------------------------------------------------------ files
; save_image / load_image: the canvas goes through the VGA window, 4 KB
; per bank, with INT 21h write/read. CF = 1 on error.
save_image:
        MOV DX, filename
        MOV AX, DOS_CREATE << 8
        INT INT_DOS
        JC .r
        MOV [fh], AX
        MOV AX, DOS_WRITE << 8
        CALL transfer
        PUSHF
        MOV BX, [fh]
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        POPF
.r:     RET

load_image:
        MOV DX, filename
        MOV AX, DOS_OPEN << 8
        INT INT_DOS
        JC .r
        MOV [fh], AX
        MOV AX, DOS_READ << 8
        CALL transfer
        PUSHF
        MOV BX, [fh]
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        POPF
.r:     RET

; transfer: AX = DOS read or write function; moves the canvas bank by bank
transfer:
        PUSHA
        MOV [xfer_fn], AX
        MOV BX, 0
        MOV [xfer_bank], BX
        MOV AX, CANVAS_SIZE
        MOV [xfer_left], AX
.bank:  MOV BX, [xfer_bank]
        OUT PORT_VGA_BANK, BX
        MOV CX, VGA_BANK_SIZE
        MOV AX, [xfer_left]
        CMP AX, CX
        JAE .n
        MOV CX, AX
.n:     MOV BX, [fh]
        MOV DX, VGA_WINDOW
        MOV AX, [xfer_fn]
        INT INT_DOS
        JC .fail
        CMP AX, 0
        JZ .done                    ; end of file on load
        MOV BX, [xfer_left]
        SUB BX, AX
        MOV [xfer_left], BX
        MOV BX, [xfer_bank]
        INC BX
        MOV [xfer_bank], BX
        MOV BX, [xfer_left]
        CMP BX, 0
        JNZ .bank
.done:  MOV AX, 0xFFFF
        MOV [cur_bank], AX
        POPA
        CLC
        RET
.fail:  MOV AX, 0xFFFF
        MOV [cur_bank], AX
        POPA
        STC
        RET

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

        %include "lib/stdio.inc"

SECTION .data
s_default:  DB "PICTURE.IMG", 0
s_size:     DB "SZ 2", 0
s_help:     DB "C:Clear S:Save L:Load +-:Size Esc:Quit", 0
s_saved:    DB "Picture saved.", 0
s_loaded:   DB "Picture loaded.", 0
s_error:    DB "Disk error!", 0

SECTION .bss
filename:   RESB 16
status:     RESW 1
color:      RESW 1
pen:        RESW 1
brush:      RESW 1
cur_bank:   RESW 1
mx:         RESW 1
my:         RESW 1
buttons:    RESW 1
was_down:   RESW 1
lx:         RESW 1
ly:         RESW 1
x0:         RESW 1
y0:         RESW 1
ddx:        RESW 1
ddy:        RESW 1
sx:         RESW 1
sy:         RESW 1
lerr:       RESW 1
fh:         RESW 1
xfer_fn:    RESW 1
xfer_bank:  RESW 1
xfer_left:  RESW 1
