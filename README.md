# NesBall

A simple Pong game for the Nintendo Entertainment System (NES), written in
6502 assembly (ca65/cc65).

## How to play

- **Up / Down** — move your paddle (left side)
- **A or Start** — serve the ball
- The computer controls the right paddle.
- When the ball leaves the screen, the other side scores, the ball returns
  to the center, and you press A/Start to serve again.
- Where the ball hits the paddle decides its angle (edges = steep, middle =
  shallow). Each of your returns speeds the ball up (max 4 px/frame).
- Scores are shown at the top. When someone reaches 10, both reset to 0.
- Your paddle is blue, the computer's is a red/green/blue bar.
- The ball (and the score digits) get a new random color every time the ball
  returns to the center, never the same as the previous one.
- Mega Man 2 "Dr. Wily Stage 1" loops in the background (melody on a pulse
  channel, bass line on the triangle channel).
- Sound effects: a falling "pue~" glide when you serve, and a "ding" every
  time a paddle hits the ball (yours or the computer's).

## Files

- `nesball.s`   — the entire program
- `nesball.cfg` — linker configuration for a mapper-0 NROM cartridge
- `build.bat`   — assemble and link `nesball.nes`
- `run.bat`     — build, then launch in the bundled Mesen emulator
- `music.inc`   — generated music data (included by `nesball.s`)
- `tools\mid2nes.py` — converts a MIDI file into `music.inc`
- `tools\mm2wily1.mid` — the MIDI the music comes from (a NES-style rip with
  separate square 1 / square 2 / triangle tracks)
- `tools\Mesen\Mesen.exe` — Mesen 2.1.1 emulator
- `tools\test.lua` — headless smoke test (see below)

## Building

Requires the cc65 toolchain (`ca65` and `ld65` on your `PATH`):

```
build.bat
```

or manually:

```
ca65 nesball.s -o nesball.o
ld65 -C nesball.cfg -o nesball.nes nesball.o
```

## Running

Run `run.bat`, or open `nesball.nes` in any NES emulator.
Mesen's default keys: arrow keys = D-pad, Z = B, X = A, Enter = Start.

## How it works

- Sprites: ball = sprite 0, player paddle = sprites 1-4, AI paddle = sprites
  5-8 (each paddle is four 8x8 tiles stacked), score digits = sprites 9-10.
  The dashed center line is a background tile.
- Colors: sprite palette 0 = ball + score (color 1 changes), palette 1 = the
  AI paddle (its 4 tiles have red, green and blue bands drawn into them),
  palette 2 = blue player paddle. A new ball color is picked in `reset_ball`
  and uploaded to `$3F11` by the NMI handler during vblank.
- Sound effects: pulse channel 1. `sfx_serve` starts a falling pitch glide
  that `update_sfx` steps each frame; `sfx_ding` plays a short high note.
  Both fade out with the APU's hardware envelope. Tune them with the
  `SERVE_*` and `DING_PERIOD` constants at the top of `nesball.s`.
- Music: two streams of (note, frames) pairs (`lead_song` on pulse channel 2,
  `bass_song` on the triangle channel), stepped once per frame by
  `update_music`. Note = MIDI note number, 0 = rest, `$FF` = loop. The data
  lives in `music.inc`, which is generated from a MIDI file (see below).
  The triangle channel sounds one octave lower than a pulse channel with
  the same timer value, which gives the bass.
- The NMI handler runs OAM DMA every frame and sets a flag; the main loop
  waits for that flag, then reads the pad and updates the game once per frame.
- The AI follows the ball only while it travels toward it, at 2 px/frame,
  so steep, fast returns can beat it.

## Changing the music

`music.inc` is generated, so don't edit it by hand. To use a different song
or section, edit the constants at the top of `tools\mid2nes.py`
(`LEAD_TRACK`, `BASS_TRACK`, `BEATS`) and run (Python 3):

```
python tools\mid2nes.py tools\mm2wily1.mid music.inc
build.bat
```

`BEATS` is how much of the song is kept before it loops (128 beats is about
44 seconds, 2.1 KB of ROM).

## Testing

```
tools\Mesen\Mesen.exe --testRunner --enableStdout nesball.nes tools\test.lua
```

runs the ROM headless, plays a few points with scripted input, and prints
the scores, each serve's ball color, the first music notes of both channels
(plus the loop point), the sound effects sent to the APU, and a
screenshot as hex (`PNGHEX:...`) so regressions are easy to spot.
