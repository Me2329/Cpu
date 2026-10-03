; HELLO.PEX - minimal PERRY-DOS program: prints a greeting, its command
; line arguments and some numbers, then returns to the shell.
        ORG 0x3000
        ENTRY main
        STACK 512
        %include "perry.inc"

SECTION .code
main:   MOV SI, msg_hello
        CALL print_str
        ; command line (INT 21h AH=62h -> BX = pointer)
        MOV AX, DOS_CMDLINE << 8
        INT INT_DOS
        MOV SI, msg_args
        CALL print_str
        MOV SI, BX
        CALL print_str
        CALL print_nl
        ; arithmetic demo: 1234 * 56 = 69104 (needs 32 bits: DX:AX)
        MOV SI, msg_mul
        CALL print_str
        MOV AX, 1234
        MOV CX, 56
        MUL AX, CX
        MOV CX, 0
        CALL print_dec32_w
        CALL print_nl
        MOV SI, msg_neg
        CALL print_str
        MOV AX, -42
        CALL print_sdec
        CALL print_nl
        ; exit code 7 so the shell test can check it
        MOV AX, (DOS_EXIT << 8) | 7
        INT INT_DOS

        %include "lib/stdio.inc"

SECTION .data
msg_hello:  DB "Hello from a .PEX program running on PERRY-16!", 13, 10, 0
msg_args:   DB "Arguments: ", 0
msg_mul:    DB "1234 * 56 = ", 0
msg_neg:    DB "Signed: ", 0
