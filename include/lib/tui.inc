; lib/tui.inc - text-mode UI drawing straight into text VRAM (0xB800).
; Each cell is a word: low byte = character, high byte = attribute
; (attribute = background << 4 | foreground).
; Positions are passed as DX = (row << 8) | column.

; tui_addr: DX = row/col -> DI = VRAM address of that cell
tui_addr:
        PUSH AX
        PUSH DX
        MOV DI, DX
        SHR DI, 8               ; row
        MOV AX, DI
        SHL DI, 6               ; row*64
        SHL AX, 4               ; row*16
        ADD DI, AX              ; row*80
        AND DX, 0xFF
        ADD DI, DX
        SHL DI, 1
        ADD DI, TEXT_VRAM
        POP DX
        POP AX
        RET

; tui_putc: AL = char, DX = row/col, BL = attribute
tui_putc:
        PUSH DI
        CALL tui_addr
        MOV.B [DI], AX
        MOV.B [DI+1], BX
        POP DI
        RET

; tui_puts: SI = ASCIIZ string, DX = row/col, BL = attribute
tui_puts:
        PUSH AX
        PUSH SI
        PUSH DI
        CALL tui_addr
.l:     MOV.B AX, [SI]
        CMP AX, 0
        JZ .d
        MOV.B [DI], AX
        MOV.B [DI+1], BX
        ADD DI, 2
        INC SI
        JMP .l
.d:     POP DI
        POP SI
        POP AX
        RET

; tui_putsn: like tui_puts but writes exactly CX cells (pads with blanks,
;            truncates long strings)
tui_putsn:
        PUSH AX
        PUSH CX
        PUSH SI
        PUSH DI
        CALL tui_addr
        JCXZ .d
.l:     MOV.B AX, [SI]
        CMP AX, 0
        JZ .pad
        INC SI
        JMP .put
.pad:   MOV AX, ' '
.put:   MOV.B [DI], AX
        MOV.B [DI+1], BX
        ADD DI, 2
        LOOP .l
.d:     POP DI
        POP SI
        POP CX
        POP AX
        RET

; tui_fill: DX = top-left, CX = (height << 8) | width, AX = (attr << 8) | char
tui_fill:
        PUSHA
        MOV BX, CX
        SHR BX, 8               ; rows
        AND CX, 0xFF            ; columns
        JCXZ .done
.row:   CMP BX, 0
        JZ .done
        CALL tui_addr
        PUSH CX
        REP STOSW
        POP CX
        ADD DX, 0x0100
        DEC BX
        JMP .row
.done:  POPA
        RET

; tui_clear: fill the whole screen with AX = (attr << 8) | char
tui_clear:
        PUSH CX
        PUSH DI
        MOV DI, TEXT_VRAM
        MOV CX, 2000
        REP STOSW
        POP DI
        POP CX
        RET

; tui_box: single-line frame. DX = top-left, CX = (height << 8) | width,
;          BL = attribute
tui_box:
        PUSHA
        MOV SI, CX
        SHR SI, 8               ; SI = height
        AND CX, 0xFF            ; CX = width
        MOV BP, BX              ; BP = attribute << 8
        AND BP, 0xFF
        SHL BP, 8
        ; top edge
        PUSH CX
        PUSH DX
        MOV AX, BP
        OR AX, 0xC4
        SUB CX, 2
        OR CX, 0x0100
        INC DX
        CALL tui_fill
        POP DX
        POP CX
        ; bottom edge
        PUSH CX
        PUSH DX
        MOV DI, SI
        DEC DI
        SHL DI, 8
        ADD DX, DI
        MOV AX, BP
        OR AX, 0xC4
        SUB CX, 2
        OR CX, 0x0100
        INC DX
        CALL tui_fill
        POP DX
        POP CX
        ; left and right edges
        PUSH CX
        PUSH DX
        MOV AX, BP
        OR AX, 0xB3
        ADD DX, 0x0100
        MOV DI, SI
        SUB DI, 2
        SHL DI, 8
        OR DI, 1
        PUSH CX
        MOV CX, DI
        CALL tui_fill           ; left
        POP CX
        ADD DX, CX
        DEC DX
        MOV CX, DI
        CALL tui_fill           ; right
        POP DX
        POP CX
        ; corners
        MOV AX, 0xDA
        CALL tui_putc
        PUSH DX
        ADD DX, CX
        DEC DX
        MOV AX, 0xBF
        CALL tui_putc
        POP DX
        MOV DI, SI
        DEC DI
        SHL DI, 8
        ADD DX, DI
        MOV AX, 0xC0
        CALL tui_putc
        ADD DX, CX
        DEC DX
        MOV AX, 0xD9
        CALL tui_putc
        POPA
        RET

; tui_cursor: move the hardware cursor to DX = row/col
tui_cursor:
        PUSH AX
        PUSH BX
        MOV AX, 0x0200
        MOV BX, 0
        INT 0x10
        POP BX
        POP AX
        RET

; tui_cursor_off / tui_cursor_on
tui_cursor_off:
        PUSH AX
        PUSH CX
        MOV AX, 0x0100
        MOV CX, 0x2000
        INT 0x10
        POP CX
        POP AX
        RET

tui_cursor_on:
        PUSH AX
        PUSH CX
        MOV AX, 0x0100
        MOV CX, 0x0607
        INT 0x10
        POP CX
        POP AX
        RET

; tui_getkey: wait for a key -> AX = (scancode << 8) | ascii
tui_getkey:
        MOV AX, 0
        INT 0x16
        RET
