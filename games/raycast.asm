; RAYCAST.PEX - a Wolfenstein-3D style raycaster for PERRY-16.
;
;   RAYCAST [file.wad]          (default MAZE.WAD)
;
; This is the reference implementation of the game pipeline described in
; docs/DOOM_WOLF3D.md, at a scale that fits a 28 KB TPA:
;
;   * WAD loading   - opens a genuine PWAD container through INT 21h,
;                     walks the lump directory (seek + read) and loads
;                     PLAYPAL, MAP01, THINGS, MUSIC and TITLE lumps
;   * palette       - PLAYPAL is written to the VGA DAC (ports 3C8h/3C9h)
;   * renderer      - per-column grid DDA ray casting in 8.8 fixed point
;                     with sin/cos tables, a camera plane, a procedural
;                     brick texture and distance shading (a tiny COLORMAP),
;                     into a 160x100 back buffer
;   * presentation  - the back buffer is blitted 2x into VRAM with the
;                     INT 10h AH=41h service (Doom's "low detail" mode)
;   * audio         - AdLib detection and music from the MUSIC lump,
;                     written to the OPL2 at ports 388h/389h
;
; Keys: arrows (or W/A/S/D) move and turn, M toggles the map, Esc quits.
        ORG 0x3000
        ENTRY main
        STACK 1024
        PEXFLAGS 1
        %include "perry.inc"

VIEW_W      EQU 160
VIEW_H      EQU 100
HALF_H      EQU 50
PROJ        EQU 25600           ; wall height = PROJ / distance(8.8): 1 cell -> 100 px
TURN        EQU 5
MUSIC_MAX   EQU 512
MAP_X       EQU 266
MAP_Y       EQU 4
C_HUD_DARK  EQU 252
C_HUD_RED   EQU 253
C_HUD_YEL   EQU 254
C_HUD_WHITE EQU 255

SECTION .code
main:   MOV SI, PSP_CMDLINE
        CALL skip_spaces
        MOV.B AX, [SI]
        CMP AX, 0
        JZ .def
        MOV DI, wadname
        CALL copy_word
        JMP .open
.def:   MOV SI, s_defwad
        MOV DI, wadname
        CALL str_copy
.open:  CALL wad_open
        JC fatal_nowad
        MOV SI, l_map
        MOV DI, map
        MOV CX, 256
        CALL wad_read_lump
        JC fatal_lump
        MOV SI, l_things
        MOV DI, things
        MOV CX, 6
        CALL wad_read_lump
        JC fatal_lump
        MOV SI, l_title
        MOV DI, title
        MOV CX, 39
        CALL wad_read_lump
        MOV SI, l_music
        MOV DI, music
        MOV CX, MUSIC_MAX
        CALL wad_read_lump
        JNC .pal
        MOV AX, 0
        MOV [music+2], AX
.pal:   MOV SI, l_playpal
        MOV DI, fb                  ; PLAYPAL is staged in the back buffer
        MOV CX, 768
        CALL wad_read_lump
        JC fatal_lump
        CALL wad_close
        ; ---- video + audio
        MOV AX, 0x0013
        INT INT_VIDEO
        CALL load_palette
        CALL init_rows
        MOV AX, [things]
        MOV [px], AX
        MOV AX, [things+2]
        MOV [py], AX
        MOV AX, [things+4]
        AND AX, 0xFF
        MOV [pa], AX
        MOV AX, 1
        MOV [show_map], AX
        MOV [dirty], AX
        CALL adlib_init

main_loop:
        CALL music_update
        CALL poll_keys
        MOV AX, [dirty]
        CMP AX, 0
        JNZ .draw
        HLT                         ; nothing changed: sleep until the next tick
        JMP main_loop
.draw:  CALL render
        CALL present
        MOV AX, 0
        MOV [dirty], AX
        JMP main_loop

fatal_nowad:
        MOV SI, s_nowad
        JMP fatal
fatal_lump:
        CALL wad_close
        MOV SI, s_badwad
fatal:  CALL print_str
        MOV SI, wadname
        CALL print_str
        CALL print_nl
        MOV AX, (DOS_EXIT << 8) | 1
        INT INT_DOS

quit:   CALL adlib_silence
        MOV AX, 0x0003
        INT INT_VIDEO
        MOV AX, DOS_EXIT << 8
        INT INT_DOS

; ================================================================= WAD I/O
; wad_open: open `wadname` and read the 12-byte header. CF = 1 on failure.
wad_open:
        MOV DX, wadname
        MOV AX, DOS_OPEN << 8
        INT INT_DOS
        JC .r
        MOV [wadfh], AX
        MOV BX, AX
        MOV CX, 12
        MOV DX, wadhdr
        MOV AX, DOS_READ << 8
        INT INT_DOS
        JC .r
        CMP AX, 12
        JNZ .bad
        MOV.B AX, [wadhdr+1]        ; "IWAD" or "PWAD"
        CMP AX, 'W'
        JNZ .bad
        MOV.B AX, [wadhdr+2]
        CMP AX, 'A'
        JNZ .bad
        CLC
.r:     RET
.bad:   CALL wad_close
        STC
        RET

wad_close:
        PUSH AX
        PUSH BX
        MOV BX, [wadfh]
        MOV AX, DOS_CLOSE << 8
        INT INT_DOS
        POP BX
        POP AX
        RET

; wad_find: SI = lump name -> wadent = directory entry. CF = 1 if missing.
wad_find:
        MOV BX, [wadfh]             ; seek to infotableofs
        MOV DX, [wadhdr+8]
        MOV CX, [wadhdr+10]
        MOV AX, DOS_SEEK << 8
        INT INT_DOS
        JC .nf
        MOV AX, [wadhdr+4]          ; numlumps
        MOV [lumps_left], AX
.next:  MOV AX, [lumps_left]
        CMP AX, 0
        JZ .nf
        DEC AX
        MOV [lumps_left], AX
        MOV BX, [wadfh]
        MOV CX, 16
        MOV DX, wadent
        MOV AX, DOS_READ << 8
        INT INT_DOS
        CMP AX, 16
        JNZ .nf
        CALL name8_eq
        JNZ .next
        CLC
        RET
.nf:    STC
        RET

; name8_eq: compare ASCIIZ SI with the 8-byte lump name in wadent -> ZF
name8_eq:
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH SI
        PUSH DI
        MOV DI, wadent+8
        MOV CX, 8
.l:     MOV.B AX, [SI]
        MOV.B BX, [DI]
        CMP AX, BX
        JNZ .d
        CMP AX, 0
        JZ .d
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

; wad_read_lump: SI = name, DI = destination, CX = max bytes. CF = 1 if missing
wad_read_lump:
        PUSH CX
        PUSH DI
        CALL wad_find
        POP DI
        POP CX
        JC .r
        PUSH CX
        MOV BX, [wadfh]             ; seek to filepos
        MOV DX, [wadent]
        MOV CX, [wadent+2]
        MOV AX, DOS_SEEK << 8
        INT INT_DOS
        POP CX
        MOV AX, [wadent+4]          ; read min(size, max)
        CMP AX, CX
        JAE .n
        MOV CX, AX
.n:     MOV BX, [wadfh]
        MOV DX, DI
        MOV AX, DOS_READ << 8
        INT INT_DOS
        CLC
.r:     RET

; load_palette: PLAYPAL (8-bit RGB, staged in fb) -> VGA DAC (6-bit)
load_palette:
        MOV AX, 0
        OUT PORT_DAC_WINDEX, AX
        MOV SI, fb
        MOV CX, 768
.l:     MOV.B AX, [SI]
        SHR AX, 2
        OUT PORT_DAC_DATA, AX
        INC SI
        LOOP .l
        RET

; init_rows: ceiling / floor colour per screen row (lighter near the viewer)
init_rows:
        MOV SI, 0
.l:     CMP SI, HALF_H
        JAE .floor
        MOV AX, SI                  ; ceiling: 80 + y*15/49
        MOV BX, 15
        MUL AX, BX
        MOV BX, HALF_H-1
        DIV AX, BX
        ADD AX, 80
        JMP .st
.floor: MOV AX, VIEW_H-1            ; floor: 96 + (99-y)*15/49
        SUB AX, SI
        MOV BX, 15
        MUL AX, BX
        MOV BX, HALF_H-1
        DIV AX, BX
        ADD AX, 96
.st:    MOV.B [SI+row_color], AX
        INC SI
        CMP SI, VIEW_H
        JB .l
        RET

; ================================================================= renderer
render: MOV BX, [pa]                ; view direction and camera plane (FOV 66 deg)
        AND BX, 0xFF
        SHL BX, 1
        MOV AX, [BX+cos_tab]
        MOV [dirx], AX
        MOV AX, [BX+sin_tab]
        MOV [diry], AX
        MOV AX, [diry]              ; plane = perpendicular(dir) * 0.66
        MOV CX, -169
        IMUL AX, CX
        CALL shr8_32s
        MOV [planex], AX
        MOV AX, [dirx]
        MOV CX, 169
        IMUL AX, CX
        CALL shr8_32s
        MOV [planey], AX
        MOV AX, 0
        MOV [col], AX
.col:   CALL cast_column
        MOV AX, [col]
        INC AX
        MOV [col], AX
        CMP AX, VIEW_W
        JB .col
        RET

; cast_column: cast one ray for screen column [col] with a grid DDA
; (Wolfenstein 3D style: step from cell boundary to cell boundary;
; ray = direction + camera plane * cameraX, so distances come out
; perpendicular to the view and need no fisheye correction) and
; draw ceiling, a brick-textured wall slice and floor into fb.
cast_column:
        MOV SI, [col]               ; ray = dir + plane * cameraX
        SHL SI, 1
        MOV CX, [SI+cam_tab]
        MOV AX, [planex]
        IMUL AX, CX
        CALL shr8_32s
        ADD AX, [dirx]
        MOV [rdx], AX
        MOV AX, [planey]
        IMUL AX, CX
        CALL shr8_32s
        ADD AX, [diry]
        MOV [rdy], AX
        MOV AX, [px]
        SHR AX, 8
        MOV [mapx], AX
        MOV AX, [py]
        SHR AX, 8
        MOV [mapy], AX
        MOV AX, [rdx]
        MOV CX, [px]
        CALL axis_setup
        MOV [stepx], AX
        MOV [ddx], BX
        MOV [sdx], CX
        MOV AX, [rdy]
        MOV CX, [py]
        CALL axis_setup
        MOV [stepy], AX
        MOV [ddy], BX
        MOV [sdy], CX
        MOV SI, 64                  ; at most 64 cells per ray
.loop:  DEC SI
        JZ .outside
        MOV AX, [sdx]
        CMP AX, [sdy]
        JAE .sy
        MOV [dist], AX              ; distance where the ray enters the cell
        ADD AX, [ddx]
        JNC .nx
        MOV AX, 0xFFFF
.nx:    MOV [sdx], AX
        MOV AX, [mapx]
        ADD AX, [stepx]
        MOV [mapx], AX
        MOV AX, 0
        JMP .chk
.sy:    MOV [dist], AX
        ADD AX, [ddy]
        JNC .ny
        MOV AX, 0xFFFF
.ny:    MOV [sdy], AX
        MOV AX, [mapy]
        ADD AX, [stepy]
        MOV [mapy], AX
        MOV AX, 3                   ; y-facing walls are darker
.chk:   MOV [wside], AX
        MOV BX, [mapy]
        CMP BX, 16
        JAE .outside
        MOV AX, [mapx]
        CMP AX, 16
        JAE .outside
        SHL BX, 4
        ADD BX, AX
        MOV.B AX, [BX+map]
        CMP AX, 0
        JZ .loop
        JMP .hit
.outside:
        MOV AX, 1
.hit:   MOV [wtype], AX
        ; with a camera plane the DDA distance is already perpendicular
        MOV AX, [dist]
        CMP AX, 16
        JAE .pok
        MOV AX, 16
.pok:   MOV [perp], AX
        MOV BX, AX
        MOV AX, PROJ
        DIV AX, BX
        CMP AX, 2
        JAE .hok
        MOV AX, 2
.hok:   MOV [hfull], AX
        ; texture column: where along the wall the ray hit (0..15)
        MOV AX, [wside]
        CMP AX, 0
        JNZ .yside
        MOV BX, [rdy]
        MOV CX, [py]
        JMP .tex
.yside: MOV BX, [rdx]
        MOV CX, [px]
.tex:   MOV AX, [dist]
        IMUL AX, BX                 ; DX:AX = dist * dir (signed)
        SHR AX, 8
        SHL DX, 8
        OR AX, DX
        ADD AX, CX
        SHR AX, 4
        AND AX, 15
        MOV [tcol], AX
        ; colours: distance shading inside the wall family (COLORMAP)
        MOV AX, [perp]
        SHR AX, 7
        ADD AX, [wside]
        CMP AX, 12
        JBE .sok
        MOV AX, 12
.sok:   MOV BX, [wtype]
        SHL BX, 4
        ADD AX, BX
        MOV [wcolor], AX
        ADD AX, 3
        MOV [mcolor], AX            ; mortar
        MOV AX, [wcolor]            ; bricks: vertical joints at texel 0 / 8
        MOV BX, [tcol]
        CMP BX, 0
        JNZ .ca
        MOV AX, [mcolor]
.ca:    MOV [colA], AX
        MOV AX, [wcolor]
        CMP BX, 8
        JNZ .cb
        MOV AX, [mcolor]
.cb:    MOV [colB], AX
        ; vertical extent: unclipped top tf, texture step vstep (8.8)
        MOV AX, [hfull]
        SHR AX, 1
        MOV BX, HALF_H
        SUB BX, AX
        MOV [tf], BX
        MOV AX, 4096
        MOV CX, [hfull]
        DIV AX, CX
        MOV [vstep], AX
        MOV AX, [tf]
        CMP AX, 0
        JGE .tpos
        MOV AX, 0
.tpos:  MOV [wtop], AX
        SUB AX, [tf]
        MUL AX, [vstep]
        MOV [vpos], AX
        MOV AX, [tf]
        ADD AX, [hfull]
        CMP AX, VIEW_H
        JLE .bok
        MOV AX, VIEW_H
.bok:   MOV [wbot], AX
        ; draw the column
        MOV DI, fb
        ADD DI, [col]
        MOV SI, 0
.ceil:  CMP SI, [wtop]
        JAE .wall
        MOV.B AX, [SI+row_color]
        MOV.B [DI], AX
        ADD DI, VIEW_W
        INC SI
        JMP .ceil
.wall:  MOV DX, [vpos]
.wl:    CMP SI, [wbot]
        JAE .floor
        MOV AX, DX
        SHR AX, 8                   ; texel row 0..15
        TEST AX, 7
        JZ .mortar                  ; horizontal joints at rows 0 / 8
        TEST AX, 8
        JNZ .rowb
        MOV AX, [colA]
        JMP .put
.rowb:  MOV AX, [colB]
        JMP .put
.mortar:
        MOV AX, [mcolor]
.put:   MOV.B [DI], AX
        ADD DI, VIEW_W
        ADD DX, [vstep]
        INC SI
        JMP .wl
.floor: CMP SI, VIEW_H
        JAE .done
        MOV.B AX, [SI+row_color]
        MOV.B [DI], AX
        ADD DI, VIEW_W
        INC SI
        JMP .floor
.done:  RET

; axis_setup: AX = ray direction component, CX = position (8.8)
;   -> AX = step (+1/-1), BX = delta distance per cell, CX = distance to
;      the first cell boundary (all 8.8, saturating at 0xFFFF)
axis_setup:
        MOV BX, 1
        CMP AX, 0
        JGE .pos
        NEG AX
        MOV BX, -1
.pos:   PUSH BX
        CMP AX, 1
        JAE .div
        MOV BX, 0xFFFF
        JMP .frac
.div:   MOV BX, AX                  ; delta = 1 / |dir| = 65535 / |dir|
        MOV AX, 0xFFFF
        DIV AX, BX
        MOV BX, AX
.frac:  POP AX
        PUSH AX
        AND CX, 0xFF
        CMP AX, 0
        JL .neg
        NEG CX
        ADD CX, 256
.neg:   MOV AX, CX
        MUL AX, BX
        CALL shr8_32
        MOV CX, AX
        POP AX
        RET

; shr8_32s: AX = low 16 bits of the signed product DX:AX >> 8
shr8_32s:
        SHR AX, 8
        SHL DX, 8
        OR AX, DX
        RET

; shr8_32: AX = (DX:AX) >> 8, saturating at 0xFFFF
shr8_32:
        CMP DX, 0x100
        JAE .sat
        SHR AX, 8
        SHL DX, 8
        OR AX, DX
        RET
.sat:   MOV AX, 0xFFFF
        RET

; present: 2x blit of the back buffer to VRAM, then the HUD on top
present:
        MOV SI, fb
        MOV BX, VIEW_W
        MOV CX, VIEW_H
        MOV DI, 0
        MOV AX, 0x4100
        INT INT_VIDEO
        MOV AX, [show_map]
        CMP AX, 0
        JZ .nomap
        CALL draw_minimap
.nomap: MOV SI, title
        MOV CX, 4
        MOV DX, 4
        MOV BX, 0xFF00 | C_HUD_YEL
        MOV AX, 0x4200
        INT INT_VIDEO
        MOV SI, s_hud
        MOV CX, 4
        MOV DX, 189
        MOV BX, 0xFF00 | C_HUD_WHITE
        MOV AX, 0x4200
        INT INT_VIDEO
        RET

; fill_rect: CX = x, DX = y, SI = w, DI = h, BX = colour (INT 10h AH=43h)
fill_rect:
        PUSH AX
        MOV AX, 0x4300
        INT INT_VIDEO
        POP AX
        RET

draw_minimap:
        MOV CX, MAP_X-2
        MOV DX, MAP_Y-2
        MOV SI, 52
        MOV DI, 52
        MOV BX, C_HUD_DARK
        CALL fill_rect
        MOV AX, 0
        MOV [mcell], AX
.l:     MOV SI, [mcell]
        MOV.B BX, [SI+map]
        CMP BX, 0
        JZ .next
        SHL BX, 4                   ; brightest shade of the wall family
        MOV CX, SI                  ; x = MAP_X + (i & 15) * 3
        AND CX, 15
        MOV AX, CX
        SHL CX, 1
        ADD CX, AX
        ADD CX, MAP_X
        MOV DX, SI                  ; y = MAP_Y + (i >> 4) * 3
        SHR DX, 4
        MOV AX, DX
        SHL DX, 1
        ADD DX, AX
        ADD DX, MAP_Y
        MOV SI, 3
        MOV DI, 3
        CALL fill_rect
.next:  MOV AX, [mcell]
        INC AX
        MOV [mcell], AX
        CMP AX, 256
        JB .l
        MOV AX, [px]                ; player marker
        MOV BX, 3
        MUL AX, BX
        SHR AX, 8
        ADD AX, MAP_X-1
        MOV CX, AX
        MOV AX, [py]
        MOV BX, 3
        MUL AX, BX
        SHR AX, 8
        ADD AX, MAP_Y-1
        MOV DX, AX
        MOV SI, 3
        MOV DI, 3
        MOV BX, C_HUD_RED
        CALL fill_rect
        MOV BX, [pa]                ; view direction: a dot 4 px ahead
        AND BX, 0xFF
        SHL BX, 1
        MOV AX, [BX+cos_tab]
        SAR AX, 6
        ADD CX, AX
        INC CX
        MOV AX, [BX+sin_tab]
        SAR AX, 6
        ADD DX, AX
        INC DX
        MOV SI, 1
        MOV DI, 1
        MOV BX, C_HUD_YEL
        CALL fill_rect
        RET

; ================================================================= input
poll_keys:
.next:  MOV AX, 0x0100
        INT INT_KEYBOARD
        JZ .r
        MOV AX, 0
        INT INT_KEYBOARD
        CMP AX, KEY_ESC
        JZ quit
        CMP AX, KEY_LEFT
        JZ .left
        CMP AX, KEY_RIGHT
        JZ .right
        CMP AX, KEY_UP
        JZ .fwd
        CMP AX, KEY_DOWN
        JZ .back
        AND AX, 0xFF
        CALL to_upper
        CMP AX, 'A'
        JZ .left
        CMP AX, 'D'
        JZ .right
        CMP AX, 'W'
        JZ .fwd
        CMP AX, 'S'
        JZ .back
        CMP AX, 'M'
        JNZ .next
        MOV AX, [show_map]
        XOR AX, 1
        MOV [show_map], AX
        JMP .changed
.left:  MOV AX, [pa]
        SUB AX, TURN
        JMP .turn
.right: MOV AX, [pa]
        ADD AX, TURN
.turn:  AND AX, 0xFF
        MOV [pa], AX
        JMP .changed
.fwd:   MOV AX, 1
        CALL walk
        JMP .changed
.back:  MOV AX, -1
        CALL walk
.changed:
        MOV AX, 1
        MOV [dirty], AX
        JMP .next
.r:     RET

; walk: AX = +1 forward / -1 backward, 1/8 cell per key, with wall sliding
walk:   MOV BX, [pa]
        AND BX, 0xFF
        SHL BX, 1
        MOV CX, [BX+cos_tab]
        SAR CX, 3
        MOV DX, [BX+sin_tab]
        SAR DX, 3
        CMP AX, 0
        JGE .dir
        NEG CX
        NEG DX
.dir:   MOV [mvx], CX
        MOV [mvy], DX
        ; x axis (probe 3/16 cell ahead to keep away from walls)
        MOV AX, [px]
        ADD AX, CX
        MOV [newp], AX
        MOV BX, 48
        CMP CX, 0
        JGE .px
        NEG BX
.px:    ADD AX, BX
        MOV BX, [py]
        CALL map_at
        CMP AX, 0
        JNZ .xblock
        MOV AX, [newp]
        MOV [px], AX
        JMP .y
.xblock:
        CALL bump
.y:     MOV AX, [py]
        ADD AX, [mvy]
        MOV [newp], AX
        MOV BX, 48
        MOV CX, [mvy]
        CMP CX, 0
        JGE .py
        NEG BX
.py:    ADD AX, BX
        MOV BX, AX
        MOV AX, [px]
        CALL map_at
        CMP AX, 0
        JNZ .yblock
        MOV AX, [newp]
        MOV [py], AX
        RET
.yblock:
        CALL bump
        RET

; map_at: AX = x, BX = y (8.8) -> AX = map cell (1 outside the map)
map_at: CMP AX, 0x1000
        JAE .out
        CMP BX, 0x1000
        JAE .out
        AND BX, 0x0F00
        SHR BX, 4
        SHR AX, 8
        ADD BX, AX
        MOV.B AX, [BX+map]
        RET
.out:   MOV AX, 1
        RET

; ================================================================= AdLib
; opl_write: AX = register, BX = value (with the classic status-read delays)
opl_write:
        PUSH AX
        PUSH CX
        OUT PORT_ADLIB_IDX, AX
        MOV CX, 6
.d1:    IN AX, PORT_ADLIB_IDX
        LOOP .d1
        OUT PORT_ADLIB_DATA, BX
        MOV CX, 35
.d2:    IN AX, PORT_ADLIB_IDX
        LOOP .d2
        POP CX
        POP AX
        RET

; adlib_detect: the standard timer-based detection -> has_adlib
adlib_detect:
        MOV AX, 4
        MOV BX, 0x60
        CALL opl_write              ; mask both timers
        MOV BX, 0x80
        CALL opl_write              ; reset the IRQ flags
        IN AX, PORT_ADLIB_IDX
        AND AX, 0xE0
        MOV CX, AX
        MOV AX, 2
        MOV BX, 0xFF
        CALL opl_write              ; timer 1 count
        MOV AX, 4
        MOV BX, 0x21
        CALL opl_write              ; start timer 1
        MOV DX, 200
.wait:  IN AX, PORT_ADLIB_IDX
        DEC DX
        JNZ .wait
        AND AX, 0xE0
        PUSH AX
        MOV AX, 4
        MOV BX, 0x60
        CALL opl_write
        MOV BX, 0x80
        CALL opl_write
        POP AX
        MOV BX, 0
        CMP CX, 0
        JNZ .set
        CMP AX, 0xC0
        JNZ .set
        MOV BX, 1
.set:   MOV [has_adlib], BX
        RET

adlib_init:
        CALL adlib_detect
        MOV AX, [has_adlib]
        CMP AX, 0
        JZ .r
        MOV AX, 1                   ; clear registers 01h-F5h
        MOV BX, 0
.clr:   CALL opl_write
        INC AX
        CMP AX, 0xF6
        JB .clr
        MOV SI, opl_setup           ; instruments
.prog:  MOV.B AX, [SI]
        CMP AX, 0xFF
        JZ .done
        MOV.B BX, [SI+1]
        CALL opl_write
        ADD SI, 2
        JMP .prog
.done:  MOV AX, 0
        MOV [mpos], AX
        MOV AX, [BDA_TICKS]
        MOV [next_tick], AX
.r:     RET

adlib_silence:
        MOV AX, [has_adlib]
        CMP AX, 0
        JZ .r
        MOV AX, 0xB0
        MOV BX, 0
.l:     CALL opl_write
        INC AX
        CMP AX, 0xB9
        JB .l
.r:     RET

; music_update: advance the MUSIC lump on channel 0, release the bump sound
music_update:
        MOV AX, [has_adlib]
        CMP AX, 0
        JZ .r
        MOV AX, [bump_on]
        CMP AX, 0
        JZ .music
        MOV AX, [BDA_TICKS]
        SUB AX, [bump_off]
        JS .music
        MOV AX, 0
        MOV [bump_on], AX
        MOV AX, 0xB1
        MOV BX, 0x09
        CALL opl_write
.music: MOV AX, [BDA_TICKS]
        SUB AX, [next_tick]
        JS .r
        MOV AX, 0xB0                ; key off the previous note
        MOV BX, [last_bhi]
        CALL opl_write
        MOV SI, [mpos]
        MOV.B AX, [SI+music+2]
        CMP AX, 0
        JNZ .note
        MOV SI, 0                   ; end of score: loop
        MOV [mpos], SI
        MOV.B AX, [SI+music+2]
        CMP AX, 0
        JZ .r
.note:  ADD AX, [BDA_TICKS]
        MOV [next_tick], AX
        MOV.B BX, [SI+music]
        MOV.B CX, [SI+music+1]
        ADD SI, 4
        MOV [mpos], SI
        MOV AX, BX
        OR AX, CX
        JZ .r                       ; rest
        MOV AX, 0xA0
        CALL opl_write
        MOV BX, CX
        MOV [last_bhi], BX
        OR BX, 0x20                 ; key on
        MOV AX, 0xB0
        CALL opl_write
.r:     RET

; bump: short low "thud" on channel 1 when walking into a wall
bump:   PUSH AX
        PUSH BX
        MOV AX, [has_adlib]
        CMP AX, 0
        JZ .r
        MOV AX, [bump_on]
        CMP AX, 0
        JNZ .r
        MOV AX, 0xA1
        MOV BX, 0x58
        CALL opl_write
        MOV AX, 0xB1
        MOV BX, 0x29                ; key on, block 2
        CALL opl_write
        MOV AX, 1
        MOV [bump_on], AX
        MOV AX, [BDA_TICKS]
        ADD AX, 8
        MOV [bump_off], AX
.r:     POP BX
        POP AX
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
        %include "trig.inc"

SECTION .data
s_defwad:   DB "MAZE.WAD", 0
s_nowad:    DB "RAYCAST: cannot open WAD file ", 0
s_badwad:   DB "RAYCAST: missing lumps or not a WAD file: ", 0
s_hud:      DB "Arrows/WASD move  M map  Esc quit", 0
l_playpal:  DB "PLAYPAL", 0
l_map:      DB "MAP01", 0
l_things:   DB "THINGS", 0
l_music:    DB "MUSIC", 0
l_title:    DB "TITLE", 0
; OPL2 instrument setup: register, value pairs (0xFF = end)
opl_setup:
        DB 0x01, 0x20               ; enable waveform select
        DB 0x20, 0x21, 0x23, 0x21   ; ch0 mult 1, sustained
        DB 0x40, 0x1A, 0x43, 0x06   ; levels
        DB 0x60, 0xF5, 0x63, 0xF3   ; attack / decay
        DB 0x80, 0x37, 0x83, 0x26   ; sustain / release
        DB 0xE3, 0x01               ; carrier half-sine
        DB 0xC0, 0x0C               ; feedback 6, FM
        DB 0x21, 0x00, 0x24, 0x00   ; ch1 "thud"
        DB 0x41, 0x00, 0x44, 0x00
        DB 0x61, 0xF8, 0x64, 0xF6
        DB 0x81, 0x0F, 0x84, 0x0A
        DB 0xC1, 0x0E
        DB 0xFF

SECTION .bss
wadname:    RESB 16
wadfh:      RESW 1
wadhdr:     RESB 12
wadent:     RESB 16
lumps_left: RESW 1
things:     RESW 3
title:      RESB 40
map:        RESB 256
music:      RESB MUSIC_MAX
row_color:  RESB VIEW_H
px:         RESW 1
py:         RESW 1
pa:         RESW 1
dirty:      RESW 1
show_map:   RESW 1
col:        RESW 1
dirx:       RESW 1
diry:       RESW 1
planex:     RESW 1
planey:     RESW 1
rdx:        RESW 1
rdy:        RESW 1
wtype:      RESW 1
wside:      RESW 1
perp:       RESW 1
height:     RESW 1
wcolor:     RESW 1
mcolor:     RESW 1
colA:       RESW 1
colB:       RESW 1
tcol:       RESW 1
hfull:      RESW 1
tf:         RESW 1
vstep:      RESW 1
vpos:       RESW 1
dist:       RESW 1
mapx:       RESW 1
mapy:       RESW 1
stepx:      RESW 1
stepy:      RESW 1
ddx:        RESW 1
ddy:        RESW 1
sdx:        RESW 1
sdy:        RESW 1
wtop:       RESW 1
wbot:       RESW 1
mcell:      RESW 1
mvx:        RESW 1
mvy:        RESW 1
newp:       RESW 1
has_adlib:  RESW 1
mpos:       RESW 1
next_tick:  RESW 1
last_bhi:   RESW 1
bump_on:    RESW 1
bump_off:   RESW 1
fb:         RESB VIEW_W * VIEW_H
