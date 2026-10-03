; selftest.asm - bare-metal PERRY-16 instruction test.
; Runs on both the C++ emulator (perry16 --raw) and the SystemVerilog core
; (rtl/tb_perry16.sv). Prints "PASS" or "FAIL xx" on debug port 0xE9 and
; powers off through port 0xF4 with exit code 0 / 1.
; Does not rely on any BIOS service.
        ORG 0x1000
PORT_DEBUG  EQU 0x00E9
PORT_POWER  EQU 0x00F4

start:  MOV SP, 0x0F00
; --- 1 ADD / flags
        MOV BX, 1
        MOV AX, 0xFFFF
        ADD AX, 1
        JNZ fail
        JNC fail
        CMP AX, 0
        JNZ fail
; --- 2 SUB borrow / signed compare
        MOV BX, 2
        MOV AX, 5
        SUB AX, 7
        JNC fail                ; borrow -> CF
        JNS fail
        CMP AX, -2
        JNZ fail
        MOV CX, -3
        CMP CX, 2
        JGE fail                ; -3 < 2 signed
        JBE fail                ; but 0xFFFD > 2 unsigned
; --- 3 MUL: 32-bit product into DX:AX
        MOV BX, 3
        MOV AX, 300
        MOV CX, 1000
        MUL AX, CX              ; 300000 = 0x000493E0
        CMP AX, 0x93E0
        JNZ fail
        CMP DX, 0x0004
        JNZ fail
; --- 4 DIV / remainder, IDIV negative
        MOV BX, 4
        MOV AX, 1000
        MOV CX, 7
        DIV AX, CX
        CMP AX, 142
        JNZ fail
        CMP DX, 6
        JNZ fail
        MOV AX, -100
        MOV CX, 7
        IDIV AX, CX
        CMP AX, -14
        JNZ fail
        CMP DX, -2
        JNZ fail
; --- 5 shifts and rotates
        MOV BX, 5
        MOV AX, 0x8001
        SHL AX, 1
        JNC fail
        CMP AX, 2
        JNZ fail
        MOV AX, 0x8000
        SAR AX, 3
        CMP AX, 0xF000
        JNZ fail
        MOV AX, 0x8000
        SHR AX, 15
        CMP AX, 1
        JNZ fail
        MOV AX, 0x8001
        ROL AX, 4
        CMP AX, 0x0018
        JNZ fail
        MOV CX, 4
        ROR AX, CX
        CMP AX, 0x8001
        JNZ fail
; --- 6 memory addressing modes, words and bytes
        MOV BX, 6
        MOV SI, buf
        MOV AX, 0x1234
        MOV [SI], AX
        MOV AX, 0x5678
        MOV [SI+2], AX
        MOV DX, [buf+2]
        CMP DX, 0x5678
        JNZ fail
        MOV.B DX, [SI+1]        ; byte load zero-extends
        CMP DX, 0x12
        JNZ fail
        MOV AX, 0xABCD
        MOV.B [buf+4], AX       ; byte store writes the low byte only
        MOV AX, [buf+4]
        CMP AX, 0x00CD
        JNZ fail
        MOV CX, 0x0101
        ADD [SI], CX            ; read-modify-write on memory
        MOV AX, [buf]
        CMP AX, 0x1335
        JNZ fail
        MOV AX, 0x35
        CMP.B AX, [SI]
        JNZ fail
; --- 7 stack, CALL/RET, PUSHA/POPA
        MOV BX, 7
        MOV AX, 11
        MOV CX, 22
        PUSH AX
        PUSH CX
        POP AX
        POP CX
        CMP AX, 22
        JNZ fail
        CMP CX, 11
        JNZ fail
        MOV DI, 0x7777
        PUSHA
        MOV DI, 0
        MOV AX, 0
        POPA
        CMP DI, 0x7777
        JNZ fail
        CMP AX, 22
        JNZ fail
        CALL double_ax
        CMP AX, 44
        JNZ fail
        MOV DX, double_ax
        CALL DX
        CMP AX, 88
        JNZ fail
        PUSH 0x4242
        POP AX
        CMP AX, 0x4242
        JNZ fail
; --- 8 LOOP and JCXZ
        MOV BX, 8
        MOV CX, 10
        MOV AX, 0
.l8:    ADD AX, CX
        LOOP .l8
        CMP AX, 55
        JNZ fail
        MOV CX, 0
        JCXZ .ok8
        JMP fail
.ok8:
; --- 9 string ops
        MOV BX, 9
        MOV DI, buf
        MOV AX, 0x2A2A
        MOV CX, 4
        REP STOSW
        MOV SI, msg_pass
        MOV DI, buf
        MOV CX, 5
        REP MOVSB
        MOV SI, buf
        LODSB
        CMP AX, 'P'
        JNZ fail
        MOV AX, [buf+5]
        CMP AX, 0x2A2A
        JNZ fail
; --- 10 XCHG, LEA, MOVSX, NOT, NEG, INC/DEC
        MOV BX, 10
        MOV AX, 1
        MOV CX, 2
        XCHG AX, CX
        CMP AX, 2
        JNZ fail
        MOV SI, 0x100
        LEA DI, [SI+0x23]
        CMP DI, 0x123
        JNZ fail
        MOV AX, 0x0080
        MOVSX AX, AX
        CMP AX, 0xFF80
        JNZ fail
        NOT AX
        CMP AX, 0x007F
        JNZ fail
        NEG AX
        CMP AX, -127
        JNZ fail
        STC
        INC AX
        JNC fail                ; INC preserves CF
        MOV DX, 1
        DEC DX
        JNZ fail
; --- 11 ADC/SBB 32-bit arithmetic
        MOV BX, 11
        MOV AX, 0xFFFF          ; 0x0001FFFF + 0x00000001 = 0x00020000
        MOV DX, 0x0001
        ADD AX, 1
        ADC DX, 0
        CMP AX, 0
        JNZ fail
        CMP DX, 2
        JNZ fail
        SUB AX, 1
        SBB DX, 0
        CMP DX, 1
        JNZ fail
; --- 12 software interrupt through the IVT
        MOV BX, 12
        MOV AX, int80
        MOV [0x80*4], AX
        MOV AX, 0
        INT 0x80
        CMP AX, 0x5150
        JNZ fail
; --- 13 divide-by-zero exception -> vector 0
        MOV BX, 13
        MOV AX, div_handler
        MOV [0], AX
        MOV AX, 10
        MOV CX, 0
        MOV SI, 0
        DIV AX, CX
        CMP SI, 1
        JNZ fail
; --- 14 TEST / logic flags / JA
        MOV BX, 14
        MOV AX, 0x00F0
        TEST AX, 0x000F
        JNZ fail
        OR AX, 0x0F00
        AND AX, 0x0FF0
        XOR AX, 0x0F00
        CMP AX, 0x00F0
        JNZ fail
        MOV AX, 0x9000
        CMP AX, 0x1000
        JBE fail
        JA .ok14
        JMP fail
.ok14:
; --- 15 indirect jump
        MOV BX, 15
        MOV DX, .ok15
        JMP DX
        JMP fail
.ok15:
; --- all passed
        MOV SI, msg_pass
        CALL puts
        MOV AX, 0
        OUT PORT_POWER, AX
        HLT

fail:   MOV SI, msg_fail
        CALL puts
        MOV AX, BX
        CALL puthex8
        MOV AX, 10
        OUT PORT_DEBUG, AX
        MOV AX, 1
        OUT PORT_POWER, AX
        HLT

double_ax:
        ADD AX, AX
        RET

int80:  MOV AX, 0x5150
        IRET

div_handler:
        MOV SI, 1
        IRET

; puts: SI = ASCIIZ string -> debug port
puts:   PUSH AX
.next:  MOV.B AX, [SI]
        CMP AX, 0
        JZ .done
        OUT PORT_DEBUG, AX
        INC SI
        JMP .next
.done:  POP AX
        RET

; puthex8: AX low byte as two hex digits
puthex8:
        PUSH AX
        PUSH CX
        MOV CX, AX
        SHR AX, 4
        AND AX, 0x0F
        MOV.B AX, [AX+hexdig]
        OUT PORT_DEBUG, AX
        MOV AX, CX
        AND AX, 0x0F
        MOV.B AX, [AX+hexdig]
        OUT PORT_DEBUG, AX
        POP CX
        POP AX
        RET

hexdig:   DB "0123456789ABCDEF"
msg_pass: DB "PASS", 10, 0
msg_fail: DB "FAIL ", 0
buf:      DW 0, 0, 0, 0, 0, 0
