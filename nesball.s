; NesBall - a simple Pong game for the Nintendo Entertainment System (NES)
; Written in 6502 assembly for ca65 (part of the cc65 toolchain).
;
;   Left paddle  : you   (D-pad Up / Down)
;   Right paddle : computer
;   A or Start   : serve the ball
;   Ball leaves the screen -> that side scores, ball returns to the center
;   and waits for the next serve. First to 10 wraps both scores to 0.
;
; Build:
;   ca65 nesball.s -o nesball.o
;   ld65 -C nesball.cfg -o nesball.nes nesball.o

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
OAMADDR   = $2003
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007
OAMDMA    = $4014
JOYPAD1   = $4016

; ---- game constants -------------------------------------------------
TOP_Y     = 16        ; top of the play field
BOTTOM_Y  = 224       ; bottom of the play field
PADDLE_H  = 32        ; paddle height (4 sprites of 8 px)
PLAYER_X  = 16        ; left paddle X
AI_X      = 232       ; right paddle X
PADDLE_MAX = BOTTOM_Y - PADDLE_H     ; lowest allowed paddle top (192)
BALL_MAX_Y = BOTTOM_Y - 8            ; lowest allowed ball top   (216)
PLAYER_SPEED = 3
AI_SPEED     = 2
MAX_SPEED_X  = 4

; ---- zero page variables --------------------------------------------
frame     = $00       ; set to 1 by the NMI every frame
joy       = $01       ; controller state this frame
joy_prev  = $02       ; controller state last frame
pressed   = $03       ; buttons newly pressed this frame
rng       = $04       ; free running counter (serve randomness)
state     = $05       ; 0 = waiting to serve, 1 = ball in play
ball_x    = $06
ball_y    = $07
dirx      = $08       ; 0 = ball moves right, 1 = left
diry      = $09       ; 0 = ball moves down,  1 = up
spdx      = $0A
spdy      = $0B
pad1_y    = $0C       ; player paddle top
ai_y      = $0D       ; computer paddle top
score_p   = $0E
score_a   = $0F
tmp       = $10
tmp2      = $11
ball_ci   = $12       ; index of the current ball color
ball_color = $13      ; NES palette value of the ball color
pal_dirty = $14       ; 1 = NMI must upload ball_color to the palette
mus_ptr   = $19       ; 4 bytes: read pointers of the lead and bass streams
mus_t0    = $1D       ; frames left for the current lead note
mus_t1    = $1E       ; frames left for the current bass note
sfx_timer = $17       ; frames left in the serve pitch slide (0 = none)
sfx_pitch = $18       ; current pulse 1 timer (low byte) during the slide

; sound effect tuning
SERVE_START = $50     ; serve "pue~": starts high ($50 ~ 1.4 kHz) ...
SERVE_STEP  = 8       ; ... and falls by this much each frame
SERVE_LEN   = 20      ; ... for this many frames
DING_PERIOD = $54     ; hit "ding": ~1.3 kHz

AI_TILE0  = 14        ; first of the 4 RGB paddle tiles in CHR

; APU registers
SQ1_VOL   = $4000
SQ1_SWEEP = $4001
SQ1_LO    = $4002
SQ1_HI    = $4003
SQ2_VOL   = $4004
SQ2_SWEEP = $4005
SQ2_LO    = $4006
SQ2_HI    = $4007
TRI_CTRL  = $4008
TRI_LO    = $400A
TRI_HI    = $400B
APU_CTRL  = $4015

; ------------------------------------------------------------------
; iNES header
; ------------------------------------------------------------------
.segment "HEADER"
    .byte 'N', 'E', 'S', $1A   ; magic
    .byte 2                    ; 2 x 16 KB PRG ROM
    .byte 1                    ; 1 x 8 KB CHR ROM
    .byte $00, $00             ; mapper 0 (NROM), horizontal mirroring
    .byte 0, 0, 0, 0, 0, 0, 0, 0

; ------------------------------------------------------------------
; CHR ROM (pattern table 0 is used for both background and sprites)
;   tile 0      blank
;   tile 1      ball
;   tile 2      paddle block
;   tile 3      dashed center line (gray)
;   tiles 4-13  digits 0-9
; ------------------------------------------------------------------
.macro glyph r0, r1, r2, r3, r4, r5, r6
    .byte r0, r1, r2, r3, r4, r5, r6, 0   ; low bit plane
    .byte 0, 0, 0, 0, 0, 0, 0, 0          ; high bit plane
.endmacro

.segment "CHARS"
    .res 16, 0                                          ; tile 0: blank
    .byte $3C, $7E, $FF, $FF, $FF, $FF, $7E, $3C        ; tile 1: ball
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF        ; tile 2: paddle
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0                        ; tile 3: center line
    .byte $18, $18, $18, $18, 0, 0, 0, 0                ;   (color 2 = gray)

    glyph $70, $88, $88, $88, $88, $88, $70             ; 0
    glyph $20, $60, $20, $20, $20, $20, $70             ; 1
    glyph $70, $88, $08, $10, $20, $40, $F8             ; 2
    glyph $70, $88, $08, $30, $08, $88, $70             ; 3
    glyph $10, $30, $50, $90, $F8, $10, $10             ; 4
    glyph $F8, $80, $F0, $08, $08, $88, $70             ; 5
    glyph $70, $80, $80, $F0, $88, $88, $70             ; 6
    glyph $F8, $08, $10, $20, $40, $40, $40             ; 7
    glyph $70, $88, $88, $70, $88, $88, $70             ; 8
    glyph $70, $88, $88, $78, $08, $08, $70             ; 9

    ; tiles 14-17: the computer paddle, a red / green / blue gradient bar.
    ; Colors come from sprite palette 1: color 1 = red, 2 = green, 3 = blue
    ; (low plane bit = color 1, high plane bit = color 2, both = color 3).
    .byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF        ; 14: red
    .byte $00, $00, $00, $00, $00, $00, $00, $00
    .byte $FF, $FF, $FF, $00, $00, $00, $00, $00        ; 15: red -> green
    .byte $00, $00, $00, $FF, $FF, $FF, $FF, $FF
    .byte $00, $00, $00, $00, $00, $00, $FF, $FF        ; 16: green -> blue
    .byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF
    .byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF        ; 17: blue
    .byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF

    .res 8192 - 18 * 16, 0

; ------------------------------------------------------------------
; Code
; ------------------------------------------------------------------
.segment "CODE"

reset:
    sei                     ; disable IRQs
    cld                     ; binary mode
    ldx #$40
    stx $4017               ; disable APU frame IRQ
    ldx #$FF
    txs                     ; set up stack
    inx
    stx PPUCTRL             ; disable NMI
    stx PPUMASK             ; disable rendering
    stx $4010               ; disable DMC IRQs
    bit PPUSTATUS           ; clear vblank flag

@wait1:                     ; wait for the first vblank
    bit PPUSTATUS
    bpl @wait1

    ; clear all RAM
    lda #$00
    ldx #$00
@clr:
    sta $0000, x
    sta $0100, x
    sta $0200, x
    sta $0300, x
    sta $0400, x
    sta $0500, x
    sta $0600, x
    sta $0700, x
    inx
    bne @clr

    ; hide all 64 hardware sprites
    ldx #$00
    lda #$FF
@hide:
    sta $0200, x
    inx
    inx
    inx
    inx
    bne @hide

@wait2:                     ; second vblank: PPU is now ready
    bit PPUSTATUS
    bpl @wait2

    ; ---- nametable 0: tile 0 everywhere, dashed line in column 16 ----
    lda #$20
    sta PPUADDR
    lda #$00
    sta PPUADDR
    ldy #30                 ; 30 rows
@row:
    ldx #0
@col:
    lda #0
    cpx #16
    bne @put
    lda #3                  ; center line tile
@put:
    sta PPUDATA
    inx
    cpx #32
    bne @col
    dey
    bne @row
    ldx #64                 ; attribute table (all palette 0)
    lda #0
@attr:
    sta PPUDATA
    dex
    bne @attr

    ; ---- palettes ----
    lda #$3F
    sta PPUADDR
    lda #$00
    sta PPUADDR
    ldx #$00
@pal:
    lda palette, x
    sta PPUDATA
    inx
    cpx #$20
    bne @pal

    ; ---- static sprite data: paddles ----
    ldx #0
@paddles:
    lda #2                  ; solid tile for the player paddle (sprites 1-4)
    sta $0205, x
    txa
    lsr a
    lsr a
    clc
    adc #AI_TILE0           ; RGB gradient tiles for the AI paddle (sprites 5-8)
    sta $0215, x
    lda #2                  ; player paddle: sprite palette 2 (blue)
    sta $0206, x
    lda #1                  ; AI paddle: sprite palette 1 (red/green/blue)
    sta $0216, x
    lda #PLAYER_X
    sta $0207, x
    lda #AI_X
    sta $0217, x
    inx
    inx
    inx
    inx
    cpx #16
    bne @paddles

    lda #1                  ; ball tile (sprite 0)
    sta $0201

    lda #24                 ; score digit sprites 9 and 10
    sta $0224
    sta $0228
    lda #96
    sta $0227
    lda #152
    sta $022B

    ; ---- initial game state ----
    lda #104
    sta pad1_y
    sta ai_y
    lda #0
    sta dirx                ; first serve goes toward the computer
    sta score_p
    sta score_a
    jsr reset_ball
    jsr update_sprites

    lda #$00                ; reset scroll
    sta PPUSCROLL
    sta PPUSCROLL
    lda #%10000000          ; enable NMI
    sta PPUCTRL
    lda #%00011110          ; show background + sprites
    sta PPUMASK

    ; ---- music: pulse channel 2 plays the song ----
    lda #$08
    sta SQ2_SWEEP           ; sweep units off
    sta SQ1_SWEEP
    lda #%00000111
    sta APU_CTRL            ; pulse 1 (sound effects), pulse 2 + triangle (music)
    jsr music_restart_lead
    jsr music_restart_bass
    lda #1
    sta mus_t0              ; both streams fetch their first note next frame
    sta mus_t1

; ------------------------------------------------------------------
; Main loop: one iteration per frame
; ------------------------------------------------------------------
main:
@wait:
    lda frame
    beq @wait
    lda #0
    sta frame

    inc rng
    jsr update_music
    jsr update_sfx
    jsr read_pad
    jsr update_player

    lda state
    bne @playing

    ; --- waiting to serve ---
    lda pressed
    and #%00001001          ; A or Start
    beq @draw
    lda #1
    sta state
    lda rng
    and #1
    sta diry                ; random vertical direction
    lda rng
    lsr a
    and #1
    clc
    adc #1
    sta spdy                ; random vertical speed 1 or 2
    jsr sfx_serve
    jmp @draw

@playing:
    jsr update_ai
    jsr update_ball

@draw:
    jsr update_sprites
    jmp main

; ------------------------------------------------------------------
; Read controller 1.  joy bits: 0=A 1=B 2=Select 3=Start 4=Up 5=Down
; 6=Left 7=Right.  'pressed' holds buttons that went down this frame.
; ------------------------------------------------------------------
read_pad:
    lda #$01
    sta JOYPAD1
    lda #$00
    sta JOYPAD1
    sta joy
    ldx #$08
@bit:
    lda JOYPAD1
    lsr a                   ; button bit -> carry
    ror joy                 ; carry -> joy bit 7
    dex
    bne @bit

    lda joy_prev
    eor #$FF
    and joy
    sta pressed
    lda joy
    sta joy_prev
    rts

; ------------------------------------------------------------------
; Player paddle: Up / Down on the D-pad
; ------------------------------------------------------------------
update_player:
    lda joy
    and #%00010000          ; Up
    beq @not_up
    lda pad1_y
    sec
    sbc #PLAYER_SPEED
    bcc @clamp_top
    cmp #TOP_Y
    bcs @store_up
@clamp_top:
    lda #TOP_Y
@store_up:
    sta pad1_y
@not_up:
    lda joy
    and #%00100000          ; Down
    beq @not_down
    lda pad1_y
    clc
    adc #PLAYER_SPEED
    cmp #PADDLE_MAX + 1
    bcc @store_down
    lda #PADDLE_MAX
@store_down:
    sta pad1_y
@not_down:
    rts

; ------------------------------------------------------------------
; Computer paddle: follow the ball while it travels toward the AI.
; It is slower than the fastest ball, so it can be beaten.
; ------------------------------------------------------------------
update_ai:
    lda dirx
    bne @done               ; ball moving away: stay put
    lda ai_y
    clc
    adc #PADDLE_H / 2
    sta tmp                 ; paddle center
    lda ball_y
    clc
    adc #4
    sta tmp2                ; ball center

    lda tmp
    sec
    sbc #4
    cmp tmp2
    bcs @up                 ; paddle center - 4 >= ball center
    lda tmp
    clc
    adc #4
    cmp tmp2
    bcc @down               ; paddle center + 4 <  ball center
@done:
    rts
@up:
    lda ai_y
    sec
    sbc #AI_SPEED
    cmp #TOP_Y
    bcs @store_up
    lda #TOP_Y
@store_up:
    sta ai_y
    rts
@down:
    lda ai_y
    clc
    adc #AI_SPEED
    cmp #PADDLE_MAX + 1
    bcc @store_down
    lda #PADDLE_MAX
@store_down:
    sta ai_y
    rts

; ------------------------------------------------------------------
; Ball movement, paddle bounces and scoring
; ------------------------------------------------------------------
update_ball:
    lda dirx
    bne @left
    jsr move_right
    jmp @check
@left:
    jsr move_left
@check:
    bcs @out                ; carry set = ball left the screen
    jmp move_y

@out:
    lda dirx
    bne @ai_scores
    inc score_p             ; ball exited on the right: player scores
    jmp @scored
@ai_scores:
    inc score_a
@scored:
    lda score_p
    cmp #10
    beq @new_match
    lda score_a
    cmp #10
    bne @go
@new_match:
    lda #0
    sta score_p
    sta score_a
@go:
    jmp reset_ball          ; back to waiting for a serve

; Move ball right. Carry set on return = off screen.
move_right:
    lda ball_x
    clc
    adc spdx
    bcs @out
    sta ball_x
    cmp #AI_X - 7           ; ball overlaps AI paddle column?
    bcc @ok
    cmp #AI_X + 8
    bcs @ok                 ; already past the paddle
    lda ai_y
    jsr overlap
    bcs @ok                 ; missed
    lda #AI_X - 8           ; bounce
    sta ball_x
    lda #1
    sta dirx
    jsr set_angle
    jsr sfx_ding
@ok:
    clc
    rts
@out:
    rts                     ; carry already set

; Move ball left. Carry set on return = off screen.
move_left:
    lda ball_x
    sec
    sbc spdx
    bcc @out
    sta ball_x
    cmp #PLAYER_X - 7       ; ball overlaps player paddle column?
    bcc @ok                 ; already past the paddle
    cmp #PLAYER_X + 8
    bcs @ok
    lda pad1_y
    jsr overlap
    bcs @ok                 ; missed
    lda #PLAYER_X + 8       ; bounce
    sta ball_x
    lda #0
    sta dirx
    jsr set_angle
    jsr sfx_ding
    lda spdx                ; each player hit speeds the ball up
    cmp #MAX_SPEED_X
    bcs @ok
    inc spdx
@ok:
    clc
    rts
@out:
    sec
    rts

; Vertical movement with bouncing off the top and bottom walls.
move_y:
    lda diry
    bne @up
    lda ball_y
    clc
    adc spdy
    cmp #BALL_MAX_Y
    bcc @store_down
    lda #BALL_MAX_Y
    ldx #1
    stx diry
@store_down:
    sta ball_y
    rts
@up:
    lda ball_y
    sec
    sbc spdy
    bcc @clamp
    cmp #TOP_Y
    bcs @store_up
@clamp:
    lda #TOP_Y
    ldx #0
    stx diry
@store_up:
    sta ball_y
    rts

; Does the ball overlap a paddle whose top Y is in A?
; Returns carry clear and A = (ball_y + 8 - paddle_y) in 1..39 if so,
; carry set otherwise.
overlap:
    sta tmp
    lda ball_y
    clc
    adc #8
    sec
    sbc tmp
    beq @no
    cmp #PADDLE_H + 8
    bcs @no
    clc
    rts
@no:
    sec
    rts

; Choose the bounce angle from where the ball hit the paddle (A = 1..39).
; The paddle is split into 5 zones of 8 px: top zones send the ball up
; steeply, the middle keeps its vertical direction gently, bottom zones
; send it down.
set_angle:
    lsr a
    lsr a
    lsr a
    tax
    lda spdy_tab, x
    sta spdy
    lda diry_tab, x
    bmi @keep
    sta diry
@keep:
    rts

spdy_tab: .byte 3, 1, 1, 1, 3
diry_tab: .byte 1, 1, $FF, 0, 0     ; $FF = keep current direction

; Put the ball in the center and wait for a serve.
reset_ball:
    lda #0
    sta state
    lda #124
    sta ball_x
    lda #116
    sta ball_y
    lda #2
    sta spdx
    lda #1
    sta spdy

    ; pick a new random ball color, different from the previous one
    lda rng
    lsr a
    lsr a
    and #7
    cmp ball_ci
    bne @color_ok
    clc
    adc #1
    and #7
@color_ok:
    sta ball_ci
    tax
    lda ball_colors, x
    sta ball_color
    lda #1
    sta pal_dirty           ; NMI uploads it during vblank
    rts

ball_colors:
    .byte $16, $27, $28, $2A, $2C, $24, $25, $30   ; red orange yellow green
                                                   ; cyan magenta pink white

; Copy game state into the OAM buffer at $0200.
update_sprites:
    lda ball_y
    sta $0200
    lda ball_x
    sta $0203

    lda pad1_y
    ldx #0
@pl:
    sta $0204, x
    clc
    adc #8
    inx
    inx
    inx
    inx
    cpx #16
    bne @pl

    lda ai_y
    ldx #0
@ai:
    sta $0214, x
    clc
    adc #8
    inx
    inx
    inx
    inx
    cpx #16
    bne @ai

    lda score_p
    clc
    adc #4                  ; digit tiles start at tile 4
    sta $0225
    lda score_a
    clc
    adc #4
    sta $0229
    rts

palette:
    .byte $0F, $30, $10, $00   ; background: black, white, gray
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $30, $10, $00
    .byte $0F, $16, $10, $00   ; sprite palette 0: ball + score (color changes)
    .byte $0F, $16, $1A, $12   ; sprite palette 1: AI paddle red/green/blue
    .byte $0F, $12, $12, $12   ; sprite palette 2: player paddle blue
    .byte $0F, $30, $10, $00

; ------------------------------------------------------------------
; Sound effects on pulse channel 1 (the music uses channel 2).
; Volume fades out through the APU's hardware envelope, so only the
; serve's pitch slide needs per-frame work.
; ------------------------------------------------------------------

; Serve "pue~": a falling pitch glide.
sfx_serve:
    lda #%10000100          ; duty 50%, envelope decay (rate 4)
    sta SQ1_VOL
    lda #SERVE_START
    sta sfx_pitch
    sta SQ1_LO
    lda #$08                ; timer high = 0, length counter = long
    sta SQ1_HI              ; (this write also restarts the envelope)
    lda #SERVE_LEN
    sta sfx_timer
    rts

; Hit "ding": a bright high note that rings out and fades.
sfx_ding:
    lda #%01000100          ; duty 25%, envelope decay (rate 4)
    sta SQ1_VOL
    lda #DING_PERIOD
    sta SQ1_LO
    lda #$08
    sta SQ1_HI
    lda #0
    sta sfx_timer           ; cancel any serve slide
    rts

update_sfx:
    lda sfx_timer
    beq @done
    dec sfx_timer
    lda sfx_pitch
    clc
    adc #SERVE_STEP
    sta sfx_pitch
    sta SQ1_LO              ; low byte only, so the note isn't retriggered
@done:
    rts

; ------------------------------------------------------------------
; Music: Mega Man 2 "Dr. Wily Stage 1" (converted from MIDI by
; tools/mid2nes.py into music.inc).
;   lead  -> pulse channel 2
;   bass  -> triangle channel (sounds one octave below the written note)
; Both streams are lists of (note, frames) pairs: note = MIDI note number,
; 0 = rest, $FF = end of song (loop). update_music runs once per frame.
; ------------------------------------------------------------------
.include "music.inc"        ; LOW_NOTE, period_lo/hi, lead_song, bass_song

; Read the next byte of music stream X (X = 0 lead, 2 bass) into A.
fetch:
    lda (mus_ptr, x)
    inc mus_ptr, x
    bne @done
    inc mus_ptr + 1, x
@done:
    rts

; Point both music streams at the start of their songs.
music_restart_lead:
    lda #<lead_song
    sta mus_ptr
    lda #>lead_song
    sta mus_ptr + 1
    rts

music_restart_bass:
    lda #<bass_song
    sta mus_ptr + 2
    lda #>bass_song
    sta mus_ptr + 3
    rts

update_music:
    ; ---- lead: pulse channel 2 ----
    dec mus_t0
    bne @bass               ; note still playing
    ldx #0
    jsr fetch
    cmp #$FF
    bne @lead_got
    jsr music_restart_lead  ; end of song: start over
    jsr fetch
@lead_got:
    sta tmp                 ; note (0 = rest)
    jsr fetch
    sta mus_t0              ; length in frames
    lda tmp
    beq @lead_rest
    sec
    sbc #LOW_NOTE
    tay
    lda period_lo, y
    sta SQ2_LO
    lda period_hi, y
    ora #$F8
    sta SQ2_HI
    lda #$B8                ; duty 50%, halt length counter, volume 8
    sta SQ2_VOL
    jmp @bass
@lead_rest:
    lda #$B0                ; volume 0
    sta SQ2_VOL

    ; ---- bass: triangle channel ----
@bass:
    dec mus_t1
    bne @done
    ldx #2
    jsr fetch
    cmp #$FF
    bne @bass_got
    jsr music_restart_bass
    jsr fetch
@bass_got:
    sta tmp
    jsr fetch
    sta mus_t1
    lda tmp
    beq @bass_rest
    sec
    sbc #LOW_NOTE
    tay
    lda period_lo, y        ; same timer value as a pulse note, but the
    sta TRI_LO              ; triangle sounds one octave lower
    lda period_hi, y
    ora #$F8
    sta TRI_HI
    lda #$FF                ; linear counter on: note sounds
    sta TRI_CTRL
    rts
@bass_rest:
    lda #$80                ; linear counter 0: silent
    sta TRI_CTRL
@done:
    rts

; ------------------------------------------------------------------
; Interrupt handlers and vectors
; ------------------------------------------------------------------
nmi_handler:
    pha
    lda #$00
    sta OAMADDR
    lda #$02
    sta OAMDMA              ; copy sprites from $0200

    lda pal_dirty           ; new ball color? write it to sprite palette 0
    beq @no_pal
    lda #$3F
    sta PPUADDR
    lda #$11
    sta PPUADDR
    lda ball_color
    sta PPUDATA
    lda #0
    sta pal_dirty
    lda #%10000000          ; PPUADDR writes clobber the scroll position and
    sta PPUCTRL             ; nametable select: restore both
    lda #0
    sta PPUSCROLL
    sta PPUSCROLL
@no_pal:
    lda #1
    sta frame
    pla
    rti

irq_handler:
    rti

.segment "ROMV"
    .word nmi_handler
    .word reset
    .word irq_handler
