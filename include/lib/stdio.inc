; lib/stdio.inc - console output, number formatting and string helpers.
;
; Calling convention used by every library routine:
;   arguments and results in registers (documented per routine),
;   all other registers preserved, FLAGS are not preserved.
; Note: word-sized MUL/IMUL/DIV/IDIV write DX (high word / remainder),
; which is why several routines here use shifts instead.

; print_str: SI = ASCIIZ string -> console
print_str:
        PUSH AX
        PUSH DX
        MOV DX, SI
        MOV AX, 0x0900
        INT 0x21
        POP DX
        POP AX
        RET

; print_char: AL = character
print_char:
        PUSH AX
        PUSH DX
        MOV DX, AX
        AND DX, 0xFF
        MOV AX, 0x0200
        INT 0x21
        POP DX
        POP AX
        RET

; print_nl: CR LF
print_nl:
        PUSH AX
        MOV AX, 13
        CALL print_char
        MOV AX, 10
        CALL print_char
        POP AX
        RET

; print_spaces: CX spaces
print_spaces:
        PUSH AX
        PUSH CX
        JCXZ .done
        MOV AX, ' '
.l:     CALL print_char
        LOOP .l
.done:  POP CX
        POP AX
        RET

; utoa: AX unsigned -> ASCIIZ at DI, CX = number of digits
utoa:
        PUSH AX
        PUSH BX
        PUSH DX
        PUSH DI
        MOV BX, 10
        XOR CX, CX
.div:   DIV AX, BX              ; AX = quotient, DX = remainder
        ADD DX, '0'
        PUSH DX
        INC CX
        CMP AX, 0
        JNZ .div
        MOV BX, CX
.store: POP DX
        MOV.B [DI], DX
        INC DI
        LOOP .store
        MOV AX, 0
        MOV.B [DI], AX
        MOV CX, BX
        POP DI
        POP DX
        POP BX
        POP AX
        RET

; itoa: AX signed -> ASCIIZ at DI, CX = length
itoa:
        PUSH AX
        PUSH DI
        CMP AX, 0
        JGE .pos
        PUSH AX
        MOV AX, '-'
        MOV.B [DI], AX
        POP AX
        INC DI
        NEG AX
        CALL utoa
        INC CX
        JMP .done
.pos:   CALL utoa
.done:  POP DI
        POP AX
        RET

; print_dec: AX unsigned decimal
print_dec:
        PUSH CX
        PUSH DI
        PUSH SI
        MOV DI, numbuf
        CALL utoa
        MOV SI, numbuf
        CALL print_str
        POP SI
        POP DI
        POP CX
        RET

; print_sdec: AX signed decimal
print_sdec:
        PUSH CX
        PUSH DI
        PUSH SI
        MOV DI, numbuf
        CALL itoa
        MOV SI, numbuf
        CALL print_str
        POP SI
        POP DI
        POP CX
        RET

; print_dec_w: AX unsigned, right-aligned in a field of CX characters
print_dec_w:
        PUSH CX
        PUSH DI
        PUSH SI
        PUSH BX
        MOV BX, CX
        MOV DI, numbuf
        CALL utoa
        SUB BX, CX
        JBE .print
        MOV CX, BX
        CALL print_spaces
.print: MOV SI, numbuf
        CALL print_str
        POP BX
        POP SI
        POP DI
        POP CX
        RET

; print_hex: AX as 4 hex digits
print_hex:
        PUSH AX
        PUSH BX
        PUSH CX
        MOV BX, AX
        MOV CX, 4
.l:     ROL BX, 4
        MOV AX, BX
        AND AX, 0x0F
        MOV.B AX, [AX+hexdigits]
        CALL print_char
        LOOP .l
        POP CX
        POP BX
        POP AX
        RET

; udiv32: DX:AX / BX -> DX:AX quotient, CX remainder (BX <= 0x7FFF)
udiv32:
        PUSH SI
        XOR CX, CX
        MOV SI, 32
.bit:   SHL AX, 1
        ADC DX, DX
        ADC CX, CX
        CMP CX, BX
        JB .skip
        SUB CX, BX
        INC AX
.skip:  DEC SI
        JNZ .bit
        POP SI
        RET

; u32toa: DX:AX unsigned 32-bit -> ASCIIZ at DI, CX = length
u32toa:
        PUSH AX
        PUSH BX
        PUSH DX
        PUSH DI
        PUSH SI
        MOV BX, 10
        XOR SI, SI
.div:   CALL udiv32             ; CX = digit
        ADD CX, '0'
        PUSH CX
        INC SI
        MOV CX, AX
        OR CX, DX
        JNZ .div
        MOV CX, SI
.store: POP AX
        MOV.B [DI], AX
        INC DI
        LOOP .store
        MOV AX, 0
        MOV.B [DI], AX
        MOV CX, SI
        POP SI
        POP DI
        POP DX
        POP BX
        POP AX
        RET

; print_dec32_w: DX:AX unsigned, right-aligned in CX characters
print_dec32_w:
        PUSH BX
        PUSH CX
        PUSH DI
        PUSH SI
        MOV BX, CX
        MOV DI, numbuf
        CALL u32toa
        SUB BX, CX
        JBE .print
        MOV CX, BX
        CALL print_spaces
.print: MOV SI, numbuf
        CALL print_str
        POP SI
        POP DI
        POP CX
        POP BX
        RET

; ------------------------------------------------------------ strings

; to_upper: AX (character) -> AX upper case
to_upper:
        CMP AX, 'a'
        JB .x
        CMP AX, 'z'
        JA .x
        SUB AX, 32
.x:     RET

; str_len: SI -> CX
str_len:
        PUSH AX
        PUSH SI
        XOR CX, CX
.l:     MOV.B AX, [SI]
        CMP AX, 0
        JZ .d
        INC CX
        INC SI
        JMP .l
.d:     POP SI
        POP AX
        RET

; str_copy: SI -> DI (including the terminating NUL)
str_copy:
        PUSH AX
        PUSH SI
        PUSH DI
.l:     MOV.B AX, [SI]
        MOV.B [DI], AX
        INC SI
        INC DI
        CMP AX, 0
        JNZ .l
        POP DI
        POP SI
        POP AX
        RET

; str_upper: SI string converted to upper case in place
str_upper:
        PUSH AX
        PUSH SI
.l:     MOV.B AX, [SI]
        CMP AX, 0
        JZ .d
        CALL to_upper
        MOV.B [SI], AX
        INC SI
        JMP .l
.d:     POP SI
        POP AX
        RET

; str_cmpi: compare SI and DI ignoring case -> ZF = 1 when equal
str_cmpi:
        PUSH AX
        PUSH BX
        PUSH SI
        PUSH DI
.l:     MOV.B AX, [SI]
        CALL to_upper
        MOV BX, AX
        MOV.B AX, [DI]
        CALL to_upper
        CMP AX, BX
        JNZ .done
        CMP AX, 0
        JZ .done
        INC SI
        INC DI
        JMP .l
.done:  POP DI
        POP SI
        POP BX
        POP AX
        RET

; str_ends_with: does SI end with DI (ignoring case)? -> ZF = 1 if yes
str_ends_with:
        PUSH AX
        PUSH CX
        PUSH SI
        CALL str_len
        MOV AX, CX
        PUSH SI
        MOV SI, DI
        CALL str_len
        POP SI
        CMP AX, CX
        JB .no
        ADD SI, AX
        SUB SI, CX
        CALL str_cmpi
        JMP .out
.no:    MOV AX, 1
        CMP AX, 0               ; ZF = 0
.out:   POP SI
        POP CX
        POP AX
        RET

; skip_spaces: advance SI past blanks
skip_spaces:
        PUSH AX
.l:     MOV.B AX, [SI]
        CMP AX, ' '
        JNZ .d
        INC SI
        JMP .l
.d:     POP AX
        RET

; atoi: parse optional '-' and decimal digits at SI -> AX, SI advanced.
;       CF = 1 when no digit was found.
atoi:
        PUSH BX
        PUSH CX
        PUSH DX
        PUSH DI
        XOR BX, BX              ; value
        XOR CX, CX              ; CX = 1 if negative
        XOR DI, DI              ; digit count
        MOV.B AX, [SI]
        CMP AX, '-'
        JNZ .dig
        MOV CX, 1
        INC SI
.dig:   MOV.B AX, [SI]
        CMP AX, '0'
        JB .end
        CMP AX, '9'
        JA .end
        SUB AX, '0'
        MOV DX, BX              ; BX = BX*10 + digit
        SHL BX, 3
        SHL DX, 1
        ADD BX, DX
        ADD BX, AX
        INC DI
        INC SI
        JMP .dig
.end:   MOV AX, BX
        CMP CX, 0
        JZ .sign
        NEG AX
.sign:  CMP DI, 0
        JNZ .ok
        STC
        JMP .out
.ok:    CLC
.out:   POP DI
        POP DX
        POP CX
        POP BX
        RET

SECTION .data
hexdigits:  DB "0123456789ABCDEF"
SECTION .bss
numbuf:     RESB 12
SECTION .code
