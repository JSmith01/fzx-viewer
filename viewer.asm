    DEVICE ZXSPECTRUM128
    ORG $8000

FONT_BUFFER     EQU $c000
DIRECTORY       EQU $d700
INPUT_BUFFER    EQU $d800
STACK_BOTTOM    EQU $f400
DOS_CALL        EQU $3d13
SCREEN_BYTES    EQU $1b00

    ASSERT INPUT_BUFFER+SCREEN_BYTES <= STACK_BOTTOM

MENU_TOP        EQU 1
MENU_ROWS       EQU 23
HINT_ROW        EQU MENU_TOP+MENU_ROWS-1
EDIT_TOP        EQU 8
EDIT_BOTTOM     EQU 64
GLYPH_HEAD      EQU EDIT_BOTTOM/8
GLYPH_TOP       EQU EDIT_BOTTOM+8
GLYPH_BOTTOM    EQU 192
PANE_WIDTH      EQU 22
PANE_X          EQU 80
GLYPH_LEFT      EQU 84
GLYPH_RIGHT     EQU 252
SAMPLE_LIMIT    EQU 192

KEY_HELP        EQU $80
KEY_RESET       EQU $81
KEY_LEFT        EQU '5'+$80
KEY_RIGHT       EQU '8'+$80

NODE_PARENT     EQU 0
NODE_NAME       EQU 2
NODE_DATA       EQU 4
NODE_COUNT      EQU 6
NODE_SELECTED   EQU 7

FONT_SLOT       EQU 0
FONT_SECTOR     EQU 1
FONT_TRACK      EQU 2
FONT_SECTORS    EQU 3
FONT_SKIP       EQU 4
FONT_PITCH      EQU 5
FONT_ROWS       EQU 6
FONT_GLYPHS     EQU 7
FONT_RANGES     EQU 8

entry:
    push ix
    push iy
    ld (basic_stack),sp
    ld sp,$fffe
    ld iy,$5c3a
    ld a,1
    out ($fe),a

    ld hl,catalog_root
    ld (current_dir),hl
    ld hl,DIRECTORY
    ld de,0
    ld b,1
    call read_sectors
    jp nz,disk_error
    ld hl,catalog_default
    call load_font
    call restore_sample_text

    call clear_screen
    call draw_selector
    call draw_font
    call draw_focus

input_wait:
    call next_key
    call note_first_input
    cp KEY_HELP
    jp z,show_help
    cp KEY_RESET
    jp z,reset_specimen
    cp 13
    jp z,cycle_focus
    ld hl,focus
    bit 0,(hl)
    jp nz,sample_input
    and $7f                             ; Outside the editor, digit aliases still work.
    bit 1,(hl)
    jp nz,glyph_input

selector_input:
    ld ix,(current_dir)
    cp 'a'
    jr z,.back
    cp '5'
    jr z,.back
    cp 'd'
    jr z,.open
    cp '8'
    jr z,.open
    cp ' '
    jr z,.open
    cp 'w'
    jr z,.up
    cp '7'
    jr z,.up
    cp 's'
    jr z,.down
    cp '6'
    jr nz,input_wait
.down:
    ld a,(ix+NODE_SELECTED)
    inc a
    cp (ix+NODE_COUNT)
    jr nc,input_wait
    jr .select
.up:
    ld a,(ix+NODE_SELECTED)
    sub 1
    jr c,input_wait
.select:
    push af
    ld a,(ix+NODE_SELECTED)
    ld c,$78
    ld b,' '
    call draw_menu_cursor
    pop af
    ld (ix+NODE_SELECTED),a
    call scroll_selector
    call mark_selection
    jr refresh_selection
.back:
    ld l,(ix+NODE_PARENT)
    ld h,(ix+NODE_PARENT+1)
    ld a,h
    or l
    jp z,input_wait
    jr .directory
.open:
    call selected_node
    push hl
    pop ix
    ld a,(ix+NODE_COUNT)
    or a
    jp z,input_wait
.directory:
    ld (current_dir),hl
    call clear_selector
    call draw_selector
refresh_selection:
    call update_font
    jp input_wait

update_font:
    ld ix,(current_dir)
    call selected_node
    push hl
    pop ix
    ld a,(ix+NODE_COUNT)
    or a
    ret nz
    ld de,(current_font)
    or a
    sbc hl,de
    ret z
    push ix
    pop hl
    call load_font
    ld d,0
    ld b,GLYPH_BOTTOM
    call clear_right
    jp draw_font

; IX = active directory. Return its selected child in HL.
selected_node:
    ld a,(ix+NODE_SELECTED)
    call node_at
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ret

draw_selector:
    ld ix,(current_dir)
    ld l,(ix+NODE_PARENT)
    ld h,(ix+NODE_PARENT+1)
    ld a,h
    or l
    ld de,$0001
    jr nz,.breadcrumb
    ld l,(ix+NODE_NAME)
    ld h,(ix+NODE_NAME+1)
    call print_text
    jr .entries
.breadcrumb:
    push ix
    pop hl
    call print_path
.entries:
    ld ix,(current_dir)
    ld a,(ix+NODE_SELECTED)
    sub MENU_ROWS-1
    jr nc,.window
    xor a
.window:
    ld (menu_first),a
    ld d,MENU_TOP
.list:
    ld ix,(current_dir)
    cp (ix+NODE_COUNT)
    jr nc,.complete
    push af
    push de
    call draw_menu_item
    pop de
    pop af
    inc a
    inc d
    ld e,a
    ld a,d
    cp MENU_TOP+MENU_ROWS
    ld a,e
    jr c,.list
.complete:
    call mark_selection
    ld a,(ix+NODE_PARENT)
    or (ix+NODE_PARENT+1)
    ret nz
    ld a,(ix+NODE_COUNT)
    cp MENU_ROWS
    jr c,draw_help_hint
    ld a,(root_touched)
    or a
    ret nz

draw_help_hint:
    ld d,HINT_ROW
    call clear_menu_row
    ld a,HINT_ROW
    ld bc,$0a60                         ; bright green paper, black ink
    ld e,0
    call color_span
    ld hl,help_hint
    ld de,HINT_ROW*256+1
    jp print_text

; The first control event happens at the root. Give an occupied hint row
; back to the list before handling the key, including cursor movement.
note_first_input:
    ld hl,root_touched
    bit 0,(hl)
    ret nz
    inc (hl)
    push af
    ld ix,(current_dir)
    ld a,(ix+NODE_COUNT)
    cp MENU_ROWS
    call nc,reveal_root_bottom
    pop af
    ret

reveal_root_bottom:
    ld d,HINT_ROW
    call clear_menu_row
    ld a,HINT_ROW
    ld bc,$0a78
    ld e,0
    call color_span
    ld a,(menu_first)
    add a,MENU_ROWS-1
    ld d,HINT_ROW
    call draw_menu_item
    jr mark_selection

mark_selection:
    ld ix,(current_dir)
    ld a,(ix+NODE_SELECTED)
    ld c,$68
    ld b,'>'
; A = index, B = cursor character, C = attribute. Preserve IX.
draw_menu_cursor:
    ld hl,menu_first
    sub (hl)
    add a,MENU_TOP
    push af
    push bc
    ld b,10
    ld e,0
    call color_span
    pop bc
    pop af
    ld d,a
    ld e,0
    ld a,b
    jp print_char

; A = item index, D = text row, IX = active directory.
draw_menu_item:
    push de
    call node_at
    ld e,(hl)
    inc hl
    ld d,(hl)
    push de
    pop ix
    ld l,(ix+NODE_NAME)
    ld h,(ix+NODE_NAME+1)
    pop de
    ld e,2
    ld b,17
    jp print_limited

; The old cursor has been erased. Move the sidebar bitmap by one text
; row only when the new selection leaves the window.
scroll_selector:
    ld hl,menu_first
    sub (hl)
    jr c,.up
    cp MENU_ROWS
    ret c
    inc (hl)
    ld de,((MENU_TOP+1)*8)*256+MENU_TOP*8
    ld bc,((MENU_ROWS-1)*8)*256
    call scroll_pixels
    ld d,HINT_ROW
    jr .reveal
.up:
    dec (hl)
    ld de,((MENU_TOP+MENU_ROWS-1)*8-1)*256+(MENU_TOP+MENU_ROWS)*8-1
    ld bc,((MENU_ROWS-1)*8)*256
    call scroll_pixels
    ld d,MENU_TOP
.reveal:
    call clear_menu_row
    ld ix,(current_dir)
    ld a,(ix+NODE_SELECTED)
    jp draw_menu_item

; D is the text row. Preserve DE so the caller can print into it.
clear_menu_row:
    push de
    ld a,d
    add a,a
    add a,a
    add a,a
    ld d,a
    ld e,0
    push de
    ld bc,$080a
    call clear_rect
    pop de
    ld b,8
    call draw_divider
    pop de
    ret

; A = child index, IX = active directory. HL points to its pointer.
node_at:
    ld l,(ix+NODE_DATA)
    ld h,(ix+NODE_DATA+1)
    ld e,a
    ld d,0
    sla e
    rl d
    add hl,de
    ret

load_font:
    ld (current_font),hl
    push hl
    pop ix
    ld l,(ix+NODE_DATA)
    ld h,(ix+NODE_DATA+1)
    ld (font_record),hl
    push hl
    pop ix

    ; Resolve the stream's sectors relative to the pack's TR-DOS catalog entry.
    ld h,HIGH DIRECTORY
    ld a,(ix+FONT_SLOT)
    add a,14
    ld l,a
    ld a,(hl)
    add a,(ix+FONT_SECTOR)
    ld e,a
    and 15
    ld b,a
    ld a,e
    ld e,b
    rrca
    rrca
    rrca
    rrca
    and 1
    inc hl
    add a,(hl)
    add a,(ix+FONT_TRACK)
    ld d,a
    ld b,(ix+FONT_SECTORS)
    ld hl,INPUT_BUFFER
    call read_sectors
    jp nz,disk_error
    ld ix,(font_record)
    ld h,HIGH INPUT_BUFFER
    ld l,(ix+FONT_SKIP)
    ld de,FONT_BUFFER
    call dzx0_standard
    ex de,hl                            ; DE was the end of the decompressed file.
    ld de,FONT_BUFFER
    or a
    sbc hl,de
    ld (font_size),hl
    xor a
    ld (first_row),a
    ld ix,(font_record)
    ld c,(ix+FONT_PITCH)
    ld a,GLYPH_BOTTOM-GLYPH_TOP
    ld b,0
.rows:
    inc b
    sub c
    jr nc,.rows
    dec b
    ld hl,visible_rows
    ld (hl),b
    add a,c                             ; pixels left below the last full row
    ld b,a
    ld a,GLYPH_BOTTOM-GLYPH_TOP
    sub b
    sub c
    ld (glyph_scroll_lines),a
    ret

draw_font:
    ld hl,(current_font)
    ld de,$0015
    call print_path
    call draw_specimen
    call draw_glyph_heading

    ld a,GLYPH_TOP
    ld (row_y),a
    xor a
    ld (glyph_row_index),a
.row:
    ld a,(glyph_row_index)
    call draw_indexed_row
    ret nc
    ld hl,glyph_row_index
    inc (hl)
    ld a,(visible_rows)
    cp (hl)
    ret z
    ld hl,row_y
    ld a,(ix+FONT_PITCH)
    add a,(hl)
    ld (hl),a
    jr .row

; Print the node's path, relative to the z88dk fonts directory.
print_path:
    push hl
    pop ix
    ld l,(ix+NODE_PARENT)
    ld h,(ix+NODE_PARENT+1)
    ld a,h
    or l
    ret z
    push ix
    call print_path
    pop ix
    ld l,(ix+NODE_NAME)
    ld h,(ix+NODE_NAME+1)
    jp print_text

draw_glyph_heading:
    ld hl,height_text
    ld d,GLYPH_HEAD
    ld e,21
    call print_text
    ld a,(FONT_BUFFER)
    call print_number
    ld hl,glyphs_text
    call print_text
    ld ix,(font_record)
    ld a,(ix+FONT_GLYPHS)
    call print_number
    ld hl,row_text
    call print_text
    ld a,e
    ld (glyph_counter_column),a
    call print_glyph_counter
    ld a,'/'
    call print_char
    inc e
    ld a,(ix+FONT_ROWS)
    call print_decimal
    ld hl,size_text
    call print_text
    jp print_font_size

print_glyph_counter:
    ld d,GLYPH_HEAD
    ld a,(glyph_counter_column)
    ld e,a
    ld a,(first_row)
    inc a
    jp print_decimal

; A = index, row_y = vertical origin. Carry on an existing row.
draw_indexed_row:
    ld ix,(font_record)
    cp (ix+FONT_ROWS)
    ret nc
    ld h,0
    ld l,a
    add hl,hl
    ld de,FONT_RANGES
    add hl,de
    ld de,(font_record)
    add hl,de
    call draw_glyph_row
    scf
    ret

draw_glyph_row:
    ld a,(hl)
    ld (glyph_code),a
    inc hl
    ld a,(hl)
    ld (row_last),a
    ld a,GLYPH_LEFT
    ld (pen_x),a
.glyph:
    call glyph_info
    jr z,.advance
    call paint_glyph
    ld a,(row_y)
    add a,(ix+FONT_PITCH)
    sub 6
    ld d,a
    ld a,(pen_x)
    ld e,a
    ld a,(glyph_code)
    call print_hex
    ld a,(glyph_width)
    cp 7
    jr nc,.spacing
    ld a,7
.spacing:
    add a,2
    ld hl,pen_x
    add a,(hl)
    ld (hl),a
.advance:
    ld a,(row_last)
    ld hl,glyph_code
    cp (hl)
    ret z
    inc (hl)
    jr .glyph

glyph_input:
    cp 'w'
    jr z,.up
    cp '7'
    jr z,.up
    cp 'a'
    jr z,.up
    cp '5'
    jr z,.up
    cp 's'
    jr z,.down
    cp '6'
    jr z,.down
    cp 'd'
    jr z,.down
    cp '8'
    jp nz,input_wait
.down:
    ld hl,first_row
    ld a,(hl)
    inc a
    ld ix,(font_record)
    cp (ix+FONT_ROWS)
    jp nc,input_wait
    ld (hl),a
    ld a,(glyph_scroll_lines)
    or a
    jr z,.bottom
    ld b,a
    ld c,PANE_X
    ld a,GLYPH_TOP
    ld e,a
    add a,(ix+FONT_PITCH)
    ld d,a
    call scroll_pixels
.bottom:
    ld a,(glyph_scroll_lines)
    add a,GLYPH_TOP
    ld d,a
    ld a,(visible_rows)
    dec a
    ld hl,first_row
    add a,(hl)
    jr .reveal
.up:
    ld hl,first_row
    ld a,(hl)
    sub 1
    jp c,input_wait
    ld (hl),a
    ld ix,(font_record)
    ld a,(glyph_scroll_lines)
    or a
    jr z,.top
    ld b,a
    ld c,PANE_X
    add a,GLYPH_TOP-1
    ld d,a
    add a,(ix+FONT_PITCH)
    ld e,a
    call scroll_pixels
.top:
    ld d,GLYPH_TOP
    ld a,(first_row)
.reveal:
    push af
    ld a,d
    ld (row_y),a
    ld b,(ix+FONT_PITCH)
    call clear_right
    pop af
    call draw_indexed_row
    call print_glyph_counter
    jp input_wait

; Look up glyph_code in the raw FZX table. Return Z if it contains no ink.
; Keep its metrics even for zero-length bitmaps, including space.
glyph_info:
    ld hl,FONT_BUFFER+2
    ld a,(glyph_code)
    cp (hl)
    jr c,.in_range
    jr z,.in_range
    ld a,'?'
.in_range:
    sub 32
    ld c,a
    ld b,0
    inc hl
    add hl,bc
    add hl,bc
    add hl,bc
    push hl
    inc hl
    ld a,(hl)
    and $c0
    rlca
    rlca
    ld (glyph_kern),a
    inc hl
    ld a,(hl)
    and 15
    inc a
    ld (glyph_width),a
    ld a,(hl)
    rrca
    rrca
    rrca
    rrca
    and 15
    ld (glyph_shift),a
    inc hl
    call bitmap_address
    ex (sp),hl
    call bitmap_address
    ld (glyph_start),hl
    pop de
    ld (glyph_end),de
    ex de,hl
    or a
    sbc hl,de
    ret z
    ld b,h
    ld c,l
    ex de,hl
    xor a
.scan:
    or (hl)
    ret nz
    cpi
    jp pe,.scan
    xor a
    ret

; FZX uses per-entry relative offsets, with two kerning bits at the top.
bitmap_address:
    ld c,(hl)
    inc hl
    ld a,(hl)
    and $3f
    ld b,a
    dec hl
    add hl,bc
    ret

paint_glyph:
    ld hl,(glyph_start)
    ld de,(glyph_end)
    or a
    sbc hl,de
    ret z
    ld a,(row_y)
    ld hl,glyph_shift
    add a,(hl)
    ld (paint_y),a
    ld hl,(glyph_start)
.row:
    ld b,(hl)
    inc hl
    ld c,0
    ld a,(glyph_width)
    cp 9
    jr c,.narrow
    ld c,(hl)
    inc hl
.narrow:
    push hl
    ld a,(paint_y)
    ld d,a
    ld a,(pen_x)
    ld e,a
    call paint_span
    pop hl
    ld de,(glyph_end)
    ld a,h
    cp d
    jr nz,.next
    ld a,l
    cp e
    ret z
.next:
    ld a,(paint_y)
    inc a
    ld (paint_y),a
    jr .row

; OR the 16 MSB-first pixels in BC at (E,D) on the Spectrum bitmap.
paint_span:
    call pixel_address
    ld a,e
    and 7
    ld e,a
    xor a
    inc e
    jr .count
.rotate:
    srl b
    rr c
    rra
.count:
    dec e
    jr nz,.rotate
    ld d,a
    ld a,b
    or (hl)
    ld (hl),a
    ld a,c
    or a
    jr z,.third
    inc hl
    or (hl)
    ld (hl),a
    dec hl
.third:
    ld a,d
    or a
    ret z
    inc hl
    inc hl
    or (hl)
    ld (hl),a
    ret

pixel_address:
    ld a,d
    and $c0
    rrca
    rrca
    rrca
    or $40
    ld h,a
    ld a,d
    and 7
    or h
    ld h,a
    ld a,d
    and $38
    rlca
    rlca
    ld l,a
    ld a,e
    rrca
    rrca
    rrca
    and $1f
    or l
    ld l,a
    ret

print_hex:
    push af
    push de
    and $f0
    rrca
    rrca
    rrca
    rrca
    call hex_digit
    pop de
    ld a,e
    add a,4
    ld e,a
    pop af
    and 15
hex_digit:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld c,a
    ld b,0
    add hl,bc
    ld bc,hex_digits
    add hl,bc
    ld a,5
.row:
    push af
    push hl
    push de
    ld b,(hl)
    ld c,0
    call paint_span
    pop de
    pop hl
    inc hl
    inc d
    pop af
    dec a
    jr nz,.row
    ret
clear_screen:
    call clear_bitmap
    ld a,$78                           ; bright white paper, black ink
    call fill_attributes
    ld d,MENU_TOP*8
    ld b,MENU_ROWS*8

; Draw B pixels of the separator beginning at y=D.
draw_divider:
    ld e,PANE_X-1
.line:
    call pixel_address
    set 0,(hl)
    inc d
    djnz .line
    ret

clear_bitmap:
    ld hl,$4000
    ld de,$4001
    ld bc,$17ff
    ld (hl),0
    ldir
    ret

; Fill the entire attribute map with A.
fill_attributes:
    ld hl,$5800
    ld de,$5801
    ld bc,$02ff
    ld (hl),a
    ldir
    ret

cycle_focus:
    ld a,(focus)
    inc a
    cp 3
    jr c,set_focus
    xor a

; Change focus to A and redraw only the headings and editor caret.
set_focus:
    push af
    ld a,(focus)
    cp 1
    call z,toggle_sample_caret
    pop af
    ld (focus),a
    cp 1
    call z,toggle_sample_caret
    call draw_focus
    jp input_wait

; Highlight the labels for the three focus areas.
draw_focus:
    ld a,(focus)
    or a
    ld c,$68
    jr nz,.selector
    ld c,$4f
.selector:
    ld a,0
    ld b,10
    ld e,0
    call color_span
    ld a,(focus)
    cp 1
    ld c,$68
    jr nz,.editor
    ld c,$4f
.editor:
    ld a,0
    ld b,PANE_WIDTH
    ld e,10
    call color_span
    ld a,(focus)
    cp 2
    ld c,$68
    jr nz,.glyphs
    ld c,$4f
.glyphs:
    ld a,GLYPH_HEAD
    ld b,PANE_WIDTH
    ld e,10
    jp color_span

; Move B visible scanlines from y=D to y=E in the pane starting at x=C.
; For a downward move, D and E are the last scanlines of the rectangles.
; Attributes stay in place because each scrolling region has uniform paper.
scroll_pixels:
.line:
    push bc
    push de
    ld a,e
    push af
    ld e,c
    call pixel_address
    ex (sp),hl
    ld d,h
    call pixel_address
    ex de,hl
    pop hl
    ld a,c
    or a
    jr z,.left
    DUP PANE_WIDTH-10
        ldi
    EDUP
.left:
    DUP 10
        ldi
    EDUP
    pop de
    pop bc
    ld a,d
    cp e
    jr c,.reverse
    inc d
    inc e
    djnz .line
    ret
.reverse:
    dec d
    dec e
    djnz .line
    ret

; Clear B pixel rows of the right pane beginning at y=D.
clear_right:
    ld e,PANE_X
    ld c,PANE_WIDTH
clear_rect:
.line:
    push bc
    call pixel_address
    ld b,c
    xor a
.byte:
    ld (hl),a
    inc hl
    djnz .byte
    inc d
    pop bc
    djnz .line
    ret

clear_selector:
    ld de,0
    ld bc,(MENU_TOP+MENU_ROWS)*8*256+10
    call clear_rect
    ld a,MENU_TOP
.row:
    push af
    ld bc,$0a78
    ld e,0
    call color_span
    pop af
    inc a
    cp MENU_TOP+MENU_ROWS
    jr c,.row
    ld d,MENU_TOP*8
    ld b,MENU_ROWS*8
    jp draw_divider

; A = screen row, E = attribute column, B = count, C = attribute.
color_span:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld d,0
    add hl,de
    ld de,$5800
    add hl,de
.fill:
    ld (hl),c
    inc hl
    djnz .fill
    ret

; Print a zero-terminated string. D = screen row, E = 4-pixel text column.
print_text:
    ld b,64
print_limited:
    ld a,(hl)
    or a
    ret z
    push bc
    call print_char
    pop bc
    inc hl
    inc e
    djnz print_limited
    ret

print_char:
    push hl
    push de
    sub 32
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    ld bc,ui_font
    add hl,bc
    push hl
    ld a,d
    add a,a
    add a,a
    add a,a
    ld d,a
    ld a,e
    add a,a
    add a,a
    ld e,a
    call pixel_address
    ld c,$f0
    bit 2,e
    jr z,.aligned
    ld c,$0f
.aligned:
    pop de
    ld b,8
.row:
    ld a,(de)
    xor (hl)
    and c
    xor (hl)
    ld (hl),a
    inc de
    inc h
    djnz .row
    pop de
    pop hl
    ret

; Print an unsigned byte without leading zeroes.
print_number:
    cp 100
    jr nc,print_decimal
    cp 10
    jr nc,print_decimal.tens
    jr print_decimal.ones

; Print an unsigned byte as three decimal digits, preserving DE as the cursor.
print_decimal:
    ld c,100
    call .place
.tens:
    ld c,10
    call .place
.ones:
    add a,'0'
    call print_char
    inc e
    ret
.place:
    ld b,'0'-1
.divide:
    inc b
    sub c
    jr nc,.divide
    add a,c
    push af
    ld a,b
    call print_char
    inc e
    pop af
    ret

; Print the original FZX file size in decimal at DE.
print_font_size:
    ld hl,(font_size)
    ld bc,10000
    call .compare
    jr nc,.ten_thousands
    ld bc,1000
    call .compare
    jr nc,.thousands
    ld bc,100
    call .compare
    jr nc,.hundreds
    ld a,l
    jp print_number
.ten_thousands:
    call .place
.thousands:
    ld bc,1000
    call .place
.hundreds:
    ld bc,100
    call .place
    ld bc,10
    call .place
    ld a,l
    add a,'0'
    jp print_char
.compare:
    or a
    sbc hl,bc
    push af
    add hl,bc
    pop af
    ret
.place:
    ld a,'0'-1
    or a
.divide:
    inc a
    sbc hl,bc
    jr nc,.divide
    add hl,bc
    call print_char
    inc e
    ret

show_help:
    ; The compressed input buffer is scratch space until the next font load.
    ld hl,$4000
    ld de,INPUT_BUFFER
    ld bc,SCREEN_BYTES
    ldir
    call clear_bitmap
    ld a,$4f                           ; bright blue paper, white ink
    call fill_attributes
    ld hl,help_return
    ld de,$0100+64-(help_return_end-help_return)
    call print_text
    ld hl,help_lines
    ld d,1
.line:
    ld e,3
    call print_text
    inc hl
    inc d
    ld a,(hl)
    or a
    jr nz,.line
    ld hl,help_url
    ld de,$1600                         ; the 64-character URL fills row 22
    call print_text
    call help_wait_release              ; release H and any opening modifiers
help_wait_press:
    halt
    xor a
    in a,($fe)                          ; select all eight keyboard rows
    and $1f
    cp $1f
    jr z,help_wait_press
    ld hl,INPUT_BUFFER
    ld de,$4000
    ld bc,SCREEN_BYTES
    ldir
    call help_wait_release              ; consume the key that closed Help
    xor a
    ld (last_key),a
    jp input_wait

help_wait_release:
    halt
    xor a
    in a,($fe)
    and $1f
    cp $1f
    jr nz,help_wait_release
    ret

; TR-DOS C=5 returns a nonzero disk error in C.
read_sectors:
    push iy
    ld c,5
    call DOS_CALL
    pop iy
    ei
    ld a,c
    or a
    ret

disk_error:
    call clear_screen
    ld hl,drive_message
    ld de,$0a01
    call print_text
    ld hl,drive_continue
    ld de,$0c01
    call print_text
.wait:
    call next_key
    cp 13
    jr nz,.wait
    ld a,7
    out ($fe),a
    ld sp,(basic_stack)
    pop iy
    pop ix
    ld bc,0
    ret

; Get a new key after a display frame, with repeat after an initial delay.
next_key:
    halt
    call scan_keys
    ld hl,last_key
    cp (hl)
    jr nz,.changed
    or a
    jr z,next_key
    cp KEY_HELP
    jr z,next_key
    cp KEY_RESET
    jr z,next_key
    cp 13
    jr z,next_key
    cp 27
    jr z,next_key
    ld hl,repeat_ticks
    dec (hl)
    jr nz,next_key
    ld (hl),4
    ret
.changed:
    ld (hl),a
    ld hl,repeat_ticks
    ld (hl),18
    or a
    jr z,next_key
    ret

scan_keys:
    ld hl,normal_keys
    ld bc,$7ffe
    in a,(c)
    bit 1,a
    jr nz,.start
    ld hl,symbol_keys
.start:
    ld b,$fe
.row:
    in a,(c)
    cpl
    and 31
    ld d,a
    ld e,5
.key:
    srl d
    jr nc,.advance
    ld a,(hl)
    or a
    jr nz,.shift
.advance:
    inc hl
    dec e
    jr nz,.key
    rlc b
    jr c,.row
    xor a
    ret
.shift:
    ld b,$fe
    in d,(c)
    bit 0,d
    jr nz,.command
    cp '5'
    jr c,.caps
    cp '9'
    jr nc,.caps
    or $80
    ret
.caps:
    cp ' '
    jr z,.escape
    cp '0'
    jr z,.delete
    ld hl,focus
    bit 0,(hl)
    jr z,.command
    cp 13
    jr z,.newline
    cp 'a'
    ret c
    cp 'z'+1
    ret nc
    sub 32
    ret
.command:
    ld hl,focus
    bit 0,(hl)
    ret nz
    cp 'h'
    jr z,.help
    cp 'r'
    ret nz
    ld a,KEY_RESET
    ret
.help:
    ld a,KEY_HELP
    ret
.newline:
    ld a,10
    ret
.escape:
    ld a,27
    ret
.delete:
    ld a,8
    ld hl,focus
    bit 0,(hl)
    ret nz
    ld a,'0'
    ret

normal_keys:
    db 0,"zxcvasdfgqwert1234509876poiuy",13,"lkjh ",0,"mnb"
symbol_keys:
    db 0,":",0,"?/","~|",92,"{}"
    db 0,0,0,"<>","!@#$%","_)(",39,"&",34,";",0,"][",13,"=+-^ ",0,".,*"

height_text:       db "LH ",0
glyphs_text:       db "  GLYPHS ",0
row_text:          db "  ROW ",0
size_text:         db "  SZ ",0
help_hint:         db "H for help",0
help_return:       db "any key to return"
help_return_end:   db 0
help_lines:
    db "FZX FONT VIEWER HELP",0
    db " ",0
    db "Enter                  Next pane",0
    db "H                      Help",0
    db "R                      Restore the default text",0
    db " ",0
    db "Selector",0
    db "Up/Down or W/S         Move selection",0
    db "Right or D             Open folder",0
    db "Left or A              Parent folder",0
    db " ",0
    db "Editor",0
    db "Type                   Replace the default or append",0
    db "Caps Shift+0           Erase last character",0
    db "Caps Shift+Enter       New line",0
    db "Left / Right           Selector / glyph browser",0
    db " ",0
    db "Glyphs                 Up/Down or W/S to scroll",0
    db " ",0
    INCLUDE "z88dk-version.inc"
    db 0
help_url:
    db "https://github.com/z88dk/z88dk/tree/master/libsrc/font/fzx/fonts",0
drive_message:     db "Disk read error",0
drive_continue:    db "Check the disk, then press Enter.",0
hex_digits:
    db $e0,$a0,$a0,$a0,$e0, $40,$c0,$40,$40,$e0
    db $e0,$20,$e0,$80,$e0, $e0,$20,$e0,$20,$e0
    db $a0,$a0,$e0,$20,$20, $e0,$80,$e0,$20,$e0
    db $e0,$80,$e0,$a0,$e0, $e0,$20,$20,$20,$20
    db $e0,$a0,$e0,$a0,$e0, $e0,$a0,$e0,$20,$e0
    db $e0,$a0,$e0,$a0,$a0, $c0,$a0,$c0,$a0,$c0
    db $e0,$80,$80,$80,$e0, $c0,$a0,$a0,$a0,$c0
    db $e0,$80,$e0,$80,$e0, $e0,$80,$e0,$80,$80

basic_stack:    dw 0
current_dir:    dw 0
current_font:   dw 0
font_record:    dw 0
font_size:      dw 0
menu_first:     db 0
root_touched:   db 0
focus:          db 0
first_row:      db 0
glyph_row_index: db 0
row_last:       db 0
visible_rows:   db 0
glyph_scroll_lines: db 0
glyph_counter_column: db 0
last_key:       db 0
repeat_ticks:   db 0
pen_x:          db 0
row_y:          db 0
paint_y:        db 0
glyph_code:     db 0
glyph_start:    dw 0
glyph_end:      dw 0
glyph_width:    db 0
glyph_shift:    db 0
glyph_kern:     db 0

    INCLUDE "specimen.asm"
    INCLUDE "dzx0_standard.asm"
ui_font:
    INCBIN "ui-font.bin"
    INCLUDE "catalog.inc"

    ASSERT $ <= FONT_BUFFER
    SAVEBIN "viewer.bin",entry,$-entry
