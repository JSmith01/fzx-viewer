; Editable specimen text, shared across font changes.
draw_specimen:
    ld ix,(font_record)
    ld a,(ix+FONT_PITCH)
    sub 7                              ; tallest visible bitmap including leading
    ld hl,FONT_BUFFER
    cp (hl)
    jr nc,.height
    ld a,(hl)                          ; prefer the FZX baseline spacing if larger
.height:
    add a,2
    ld (sample_height),a

    xor a
    ld (sample_paint),a
    call sample_render
    ld a,EDIT_BOTTOM-EDIT_TOP
    ld hl,sample_height
    ld b,0
.lines:
    inc b
    sub (hl)
    jr nc,.lines
    ld a,(sample_line)
    inc a
    dec b
    sub b
    jr nc,.first
    xor a
.first:
    ld (sample_first),a
    ld a,1
    ld (sample_paint),a
    call sample_render
    call sample_row_y
    ld hl,sample_height
    add a,(hl)
    dec a
    ld d,a
    ld a,(sample_pen)
    cp GLYPH_RIGHT-2
    jr c,.cursor
    ld a,GLYPH_RIGHT-3
.cursor:
    ld e,a
    ld (sample_caret),de
    ld a,(focus)
    cp 1
    ret nz

; The underline is on the blank bottom scanline of the current text line.
toggle_sample_caret:
    ld de,(sample_caret)
    call pixel_address
    ld a,e
    and 7
    ld e,a
    ld bc,$e000
    inc e
    jr .count
.shift:
    srl b
    rr c
.count:
    dec e
    jr nz,.shift
    ld a,b
    xor (hl)
    ld (hl),a
    ld a,c
    or a
    ret z
    inc hl
    xor (hl)
    ld (hl),a
    ret

sample_input:
    cp KEY_RIGHT
    jr z,.glyphs
    cp KEY_LEFT
    jr z,.selector
    cp 27
    jr z,.selector
    cp $80                             ; Up and Down are inert in the editor.
    jp nc,input_wait
    cp 8
    jr z,.delete
    cp 10
    jr z,.add
    cp 32
    jp c,input_wait
    ld hl,sample_default
    bit 0,(hl)
    jr z,.add
    ld (hl),0
    ld hl,sample_length
    ld (hl),0                          ; the first typed character starts a new specimen
.add:
    ld hl,sample_length
    ld e,(hl)
    ld d,0
    ld c,a
    ld a,e
    cp SAMPLE_LIMIT
    jp nc,input_wait
    inc (hl)
    ld hl,sample_text
    add hl,de
    ld (hl),c
    jr .edited
.delete:
    ld hl,sample_length
    ld a,(hl)
    or a
    jp z,input_wait
    dec (hl)
.edited:
    xor a
    ld (sample_default),a
    call repaint_editor
    jp input_wait
.selector:
    xor a
    jp set_focus
.glyphs:
    ld a,2
    jp set_focus

reset_specimen:
    call restore_sample_text
    call repaint_editor
    jp input_wait

restore_sample_text:
    ld hl,initial_text
    ld de,sample_text
    ld bc,DEFAULT_LENGTH
    ldir
    ld a,DEFAULT_LENGTH
    ld (sample_length),a
    ld a,1
    ld (sample_default),a
    ret

repaint_editor:
    ld d,EDIT_TOP
    ld b,EDIT_BOTTOM-EDIT_TOP
    call clear_right
    jp draw_specimen

; First measure all line breaks, then draw the lines that fit in the viewport.
sample_render:
    ld a,(sample_length)
    ld (sample_left),a
    ld hl,sample_text
    ld (sample_ptr),hl
    xor a
    ld (sample_line),a
    ld a,GLYPH_LEFT
    ld (sample_pen),a
.next:
    ld hl,sample_left
    ld a,(hl)
    or a
    ret z
    dec (hl)
    ld hl,(sample_ptr)
    ld a,(hl)
    inc hl
    ld (sample_ptr),hl
    cp 10
    jr z,.new_row
    ld (glyph_code),a
    call sample_glyph
    ld a,(sample_pen)
    ld hl,glyph_kern
    sub (hl)
    cp GLYPH_LEFT
    jr nc,.position
    ld a,GLYPH_LEFT
.position:
    ld (pen_x),a
    ld hl,glyph_width
    add a,(hl)
    jr c,.wrap
    cp GLYPH_RIGHT+1
    jr c,.advance
.wrap:
    call .line_break
    ld a,GLYPH_LEFT
    ld (pen_x),a
    ld hl,glyph_width
    add a,(hl)
.advance:
    ld hl,FONT_BUFFER+1                ; tracking follows each proportional width
    add a,(hl)
    jr nc,.pen
    ld a,255
.pen:
    ld (sample_pen),a
    ld a,(sample_paint)
    or a
    jr z,.next
    call sample_row_y
    jr c,.next
    ld (row_y),a
    call paint_glyph
    jr .next
.new_row:
    call .line_break
    jr .next
.line_break:
    ld hl,sample_line
    inc (hl)
    ld a,GLYPH_LEFT
    ld (sample_pen),a
    ret

; A missing ASCII letter can use the other case of the same FZX font.
sample_glyph:
    ld a,(glyph_code)
    push af
    ld hl,FONT_BUFFER+2
    cp (hl)
    jr c,.check
    jr z,.check
    pop af
    jr .alternate
.check:
    call glyph_info
    pop bc                             ; B is the original character
    ret nz
    ld a,b
.alternate:
    ld b,a
    and $df
    sub 'A'
    cp 26
    jr nc,.original
    ld a,b
    xor $20
    ld hl,FONT_BUFFER+2
    cp (hl)
    jr c,.try
    jr z,.try
.original:
    ld a,b
.lookup:
    ld (glyph_code),a
    jp glyph_info
.try:
    push bc
    call .lookup
    pop bc
    ret nz
    jr .original

; Return carry for a line scrolled off the top, otherwise A = visible y.
sample_row_y:
    ld a,(sample_line)
    ld hl,sample_first
    sub (hl)
    ret c
    ld b,a
    inc b
    ld a,EDIT_TOP
    ld hl,sample_height
    jr .count
.step:
    add a,(hl)
.count:
    djnz .step
    or a
    ret

sample_caret:       dw 0
sample_default:     db 1
sample_height:      db 0
sample_first:       db 0
sample_paint:       db 0
sample_line:        db 0
sample_left:        db 0
sample_pen:         db 0
sample_ptr:         dw 0
sample_length:      db 0
sample_text:        ds SAMPLE_LIMIT,0
initial_text:       db "The quick brown fox jumps over the lazy dog. 1234567890"
DEFAULT_LENGTH      EQU $-initial_text
