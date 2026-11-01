# FPGA Space Invaders — Verilog Reproduction (+ extensions)

Reproduction of: R. Parihar, A. Kumar, A. Mishra, *"Design and Implementation
of a FPGA based Game 'Space Invaders'"*, International Journal of Control
Theory and Applications, Vol. 9, No. 44, 2016 (Spartan-6, VGA output). The
paper itself uses VHDL/Xilinx ISE; this is a Verilog port of the same
architecture, plus several gameplay extensions built on top of it for the
lab project (see "Extensions beyond the paper" below) — it started as a
straight reproduction and grew from there on request.

## File map (`src/`)

| File               | Reproduces (paper section) / purpose                                   |
|---------------------|----------------------------------------------------------------|
| `vga_controller.v`  | §3.A.1 VGA controller — 640×480@60Hz timing, hsync/vsync/video_on/pixel_x/pixel_y. |
| `clk_divider.v`     | §3.B "Counter and Clock Division" — reproduces the divide/sig1/sig2/compare/counter snippet as a clean modulo-counter tick generator. |
| `graphics.v`        | §3.A (Game Logic, incl. Table 1 colour codes) + §3.B (Buttons) — ship position (`sigXValue`/`position_next`, ±5px steps), bullet flight/collision, and the paper's `restart_next`/`level_next`/`score_next` equations (generalised, see below). Also where every extension below lives: the static title screen and TITLE/PLAY/OVER/WON FSM, the Easy/Medium/Hard modes (rigid randomised formation, or fully independent aliens in Hard), alien return fire, and the lives / touch-the-bottom game-over / game-won system — none of which are in the paper. |
| `main.v`            | Top-level `main` module. Its original 8 ports still pin-for-pin match the paper's Fig. 5 RTL view / Table 2 (`clk, left, right, shoot, not_reset → rgb, hsync, vsync`) and reproduce the `fd_1` output register from Fig. 4. `score`/`level`/`lives`/`game_over`/`game_won` are trailing **extension** outputs, and `mode[1:0]` an extension input (0 EASY, 1 MEDIUM, 2 HARD), none of them in the paper. |
| `debounce.v`        | Not from the paper — added for real hardware bring-up. Cleans up mechanical switch bounce on push-button inputs (2-flop synchronizer + ~10ms settle counter). |
| `hex7seg.v`         | Not from the paper — plain 4-bit-to-7-segment decoder for the DE2-115's score/level display. |

`sim/tb_main.v` contains five testbenches (run each with `vsim work.<name>`):

- **`tb_main`**: the paper's §5 scenarios plus extensions, in EASY mode —
  reset, *title screen* (nothing moves until a key is pressed; the start
  press must not fire a stray bullet), shoot edge-detect, collision, score
  increment, all 21 aliens shot (each shot aimed from the formation's live
  `x_offset`, up to 3 re-aim rounds), level advance, then the **GAME WON**
  checks: shooting the last alien puts the FSM in WON (`game_won`=1), the
  won game is frozen (keys do nothing) and a reset returns to the title.
  Alien return fire is disabled so the scripted aiming stays deterministic.
- **`tb_touch`**: an alien reaching the ship's row is game over
  *immediately*, with all 3 lives still intact (no shooting, no alien fire).
- **`tb_lives`**: alien bullets vs the 3-life counter (stationary ship, fast
  alien fire): lives may only step 3→2→1→0, one per hit, and `game_over`
  latches with `lives == 0` (a jump straight to 0 is only allowed together
  with `game_over`, i.e. an alien reaching the ship's row first).
- **`tb_modes`**: EASY and MEDIUM instances side by side with identical random
  bits. Both wait on the title; a key press starts both and latches the mode;
  flipping the switches afterwards changes nothing; over 2000 move_ticks
  MEDIUM descends ≥2× and drifts sideways ≥2.5× as much as EASY.
- **`tb_hard`**: HARD mode. No alien on screen at the start; all 21 then
  enter one by one **on the top edge** (y = `BOX_Y0`); every alien stays
  inside the play rectangle on every clock; the aliens do **not** move as a
  group (the fraction of ticks where *all* live aliens step sideways at once
  must be ≤5%); they end up at ≥10 different heights; sweeping the ship while
  firing scores hits (independent aliens can be shot); and the first alien to
  reach the ship's row ends the game.

## Extensions beyond the paper

The paper's own scope is a single static row of aliens with no losing
condition ("The game continues as the star keeps appearing on the
screen") and no return fire. On top of that base, this reproduction adds:

- **A multi-row alien grid**: `ALIEN_ROWS` (3 by default) rows of
  `ALIEN_COLS` (7 by default) aliens, via a flat `defeated` bit-vector and
  `for`-loops instead of the paper's 3 hardcoded `defeated1/2/3` flags —
  now as `&defeated` instead of `defeated1 && defeated2 && defeated3`.
  Column count was brought down from an earlier 11-column version to 7 to
  leave screen margin for side-to-side sweeping without the formation
  running off the edges.
- **A redesigned alien sprite**: an original bug-eyed alien head (antennae,
  eye sockets, jaw fringe, wide feet) in place of the paper's plain star
  shape — still in the same 9×16 pixel box, defined in `star_row()` in
  `graphics.v`.
- **Ship movement speed**: fixed after the first hardware try-out — a
  single quick tap of a physical button was moving the ship much further
  than intended. `move_tick` alone (~100Hz by default) is too fast to step
  the ship on directly. `graphics.v` divides `move_tick` down again just
  for ship stepping, via `SHIP_MOVE_DIVIDER` (default 5, i.e. one step
  every 5 move_ticks, ~20Hz/100px per second). Raise it if the ship is
  still too twitchy, lower it for a snappier ship.
- **Static title screen + 4-state FSM**: `state` is `S_TITLE` → `S_PLAY` →
  `S_OVER` (lost) or `S_WON` (every alien shot). After reset or power-up the
  game sits on a title screen — "SPACE INVADERS" (one fixed colour per
  letter, no red), an under-line, a row of 9 aliens, "PRESS ANY KEY TO START", the
  selected mode (green EASY / yellow MEDIUM / red HARD), a decorative ship with
  a bullet, a striped border and a starfield. It is deliberately **static**:
  colourful but nothing moves, blinks or cycles (only the MODE line changes,
  when you flip the switches). Pressing **any** of KEY1/KEY2/KEY3 starts the
  game (KEY0 is reset, so it cannot start it); the shoot-edge detector is
  pre-loaded on that press so starting with KEY3 doesn't also fire. Reset
  from any state returns to the title.
- **Three modes** (`mode[1:0]`, = SW[1:0] on the DE2-115, read on the title
  screen and **latched** at the start press — flipping the switches mid-game
  does nothing; SW1 up = HARD, else SW0 up = MEDIUM, both down = EASY):
  - **EASY** — the original speed: a rigid formation that drifts and creeps
    down at random intervals (`EASY_*` parameters).
  - **MEDIUM** — what used to be called HARD: the same rigid formation, but
    roughly 3–4× faster drift/descent, ~3× the alien fire rate and faster
    alien bullets (`MED_*` parameters).
  - **HARD** — independent aliens (next bullet).
- **HARD mode: independent aliens**: there is **no formation**. Each alien
  is a `gen_alien[k]` generate-block instance with its *own* `x`/`y`
  registers, direction, two speed-class attributes, countdown timers, a
  16-bit LFSR (x¹⁶+x¹⁵+x¹³+x⁴+1, different seed per alien, free-running) and
  a two-state machine. **WAIT**: absent from the screen, counting a random
  spawn delay (staggered by row: `HARD_SPAWN_GAP`×row + 0..127 ticks); then it
  **appears on the top edge** of the play rectangle (`BOX_Y0`) at a random x
  inside its column slot, with a random direction and random speed classes.
  **ROAM**: two independent countdowns — sideways (a 1- or 2-px step in its
  own direction, reversing at a wall or at random 1 time in 64, class minimum
  `HARD_H_MIN0..2` + rand 0..7 ticks between steps) and descent (a 1- or
  2-px drop, class minimum `HARD_D_MIN0..2` + rand 0..15 ticks, clamped at
  the bottom). Each alien is clamped inside the play rectangle
  x ∈ [16, 586], y ∈ [52, 422] (`BOX_X0/X1/Y0/Y1` — almost the whole screen
  width; the bottom edge is the ship's row). No alien reads another alien's registers, so nothing is
  synchronised. Consequences worth knowing: aliens may overlap or pass
  through each other (nothing keeps them apart), a bullet kills the
  lowest-numbered alien under it, and fire uses HARD_FIRE_MIN (avg ~0.8 s
  between shots). Unshot, the first alien reaches the ship's row after
  ~36 s.
- **Randomised rigid-formation motion (EASY / MEDIUM)**: a free-running
  32-bit LFSR (taps 32,22,2,1, maximal-length, *not* reset so the moment of
  the key press seeds the game) supplies disjoint bit-slices for every
  decision; each "next event" waits a random number of `move_tick`s: descent
  `*_DESC_MIN` + rand then a random 1–3 px drop; sideways `*_HORIZ_MIN` +
  rand then 1 px, with a 1-in-256 chance per step of reversing (so the
  formation keeps going and reaches the screen edges: `MAX_SWEEP` = 144 px
  each way, i.e. the whole 640-px width); alien fire
  `*_FIRE_MIN` + rand then a random alien fires (a dead/absent pick is
  retried next tick). (An 8-bit LFSR was rejected: sampled once per 500,000
  clocks it would visit only a handful of states.)
- **Alien return fire — two independent shooters**: there are two shooters,
  A and B, each with its own fire countdown, its own bullet and its own
  random alien pick (A from `lfsr`, B from a second 32-bit LFSR `lfsr2` with a
  different maximal polynomial and seed), so two *different* aliens can have a
  bullet in the air at the same time (either may occasionally pick the same
  alien). Each shooter uses the mode's fire timing, so the total fire rate is
  twice the old single-shooter rate. A bullet leaves from the picked alien's
  *current* position; a hit from either costs one life.
- **Lives and the two ways to lose**: `lives` starts at 3 and shows 3 → 2 → 1;
  an alien-bullet hit costs one life and recentres the ship (aliens stay
  where they are), and the hit taken *at 1 life* is fatal — `lives` goes to
  0 (dead) and the FSM to `S_OVER`. Separately, **any live alien reaching the
  ship's row (the bottom of the screen) is game over immediately,
  whatever number of lives is left** (`lives` is forced to 0). Game over is
  sticky: the ship stops, both bullets stop and a static red "GAME OVER"
  is shown until reset.
- **Game won**: shooting every alien raises `level` and puts the FSM in
  `S_WON`: a static green "GAME WON" screen, the game frozen, until reset
  (there is no respawning of a new wave any more).
- **An on-screen HUD**: "SCORE nnn" / "LIVES n" in the top-right corner of
  the VGA picture itself, drawn with a small 5×7 block font (`font_row()`
  in `graphics.v`) rather than just the board's 7-segment displays.
- **A 7-segment score/level display** on the DE2-115 (`HEX0`/`HEX1` =
  `score` in hex, `HEX2` = `level`) — see the DE2-115 section below. (The
  on-screen HUD shows the same score in decimal instead of hex.)

Everything else the paper actually specifies is unchanged: the paper's
ship-movement equations, the single-bullet-at-a-time firing model, and the
`restart_next`/`level_next`/`score_next` scoring equations (just widened
to `TOTAL_ALIENS` aliens instead of 3).

## Colours and the red channel

On the lab board's monitor/cable the **red channel did not reach the screen**
(pure red came out black, yellow came out green, white came out cyan). Because
of that, nothing that must be seen is pure red any more: aliens are green or magenta (random per alien, mixed within every row),
alien bullets yellow, the player bullet white, "GAME OVER" magenta, "GAME WON"
green, MODE HARD magenta, the title border magenta/yellow. If your red channel
works, the colours are `ALIEN_COLOR_A` / `ALIEN_COLOR_B` / `BULLET_COLOR` / `ALIEN_BULLET_COLOR` and
a few `COLOR_*` literals in `graphics.v`. If red is missing on your setup too,
try another VGA cable/monitor first — the `VGA_R` pins in the .qsf match the
DE2-115 pin table.

## Look & sizes (game screen)

The game screen uses the same background as the title: black starfield plus the
4-px diagonal magenta/yellow border frame. Sprites are drawn at 2x (`SPR_SCALE`):
alien 32x18, ship 40x16, bullets 4x14 px. Aliens come in two colours
(`ALIEN_COLOR_A` / `ALIEN_COLOR_B`, chosen at random per alien by the `acol` register,
latched from the LFSRs at the start key press; same in all three modes). The testbench constants (`SHIP_COLS`=40, `STAR_COLS`=32,
aim offset 4) mirror these sizes.

## Other deviations from the paper (by necessity — it omits full code)

- Alien **column positions** and the **collision/scoring state machine**
  are original — the paper shows only the scoring *equations*, not how a
  bullet is spawned/tracked or how many aliens there really are.
- **Clock frequencies**: Table 2 states 50 MHz on `clk`, but §3.A.1's text
  says the 25.175 MHz pixel clock is "generated from 100 MHz" — the paper
  is internally inconsistent here. This reproduction takes the RTL pinout
  (Table 2, 50 MHz) as ground truth and derives the pixel tick with a ÷2
  enable from it.
- Movement uses a `move_tick` clock-enable (from `clk_divider`) rather than
  literally reusing the paper's `divide`/`sig1`/`sig2`/`compare` signal
  names, but is functionally the same idea.

## Simulating in ModelSim

```
vlib work
vlog src/vga_controller.v
vlog src/clk_divider.v
vlog src/graphics.v
vlog src/hex7seg.v
vlog src/debounce.v
vlog src/main.v
vlog sim/tb_main.v
vsim work.tb_main
add wave -r /*
run -all
```

Then separately (same compiled library):
```
vsim work.tb_touch
add wave -r /*
run -all
```
and likewise `work.tb_lives`, `work.tb_modes`, `work.tb_hard`.

Watch the `Transcript` window for `Test Case 1b/1c PASS` (title screen),
`Test Case 3/4`, `5`, `6`, `6b`, `6c PASS` (tb_main: shooting, level, GAME WON,
frozen, reset), `tb_touch PASS`, `tb_lives PASS`, the four `tb_modes PASS
(...)` lines and the seven `tb_hard PASS (...)` lines. Useful signals:
`state`, `diff`, `score`, `level`, `lives`, `game_over`, `game_won`,
`defeated` (21 bits, index = row*ALIEN_COLS + col), `hp_flat` (which HARD
aliens are on screen), `hx_flat`/`hy_flat` (HARD positions, 10 bits per
alien), `x_offset`, `bullet_x`, `bullet_y`, `alien_bullet_x`,
`alien_bullet_y`. The testbenches shorten the `move_tick` divider so they
finish in reasonable time, but the touch/lives/hard checks still need a good
while of simulated time — let `run -all` finish.

(No local Verilog simulator was available in this session to run these
testbenches directly, so everything was checked by lint (balanced
constructs / identifier checks), a numpy render of the title / WON / OVER
screens (glyph and sprite constants parsed straight out of `graphics.v`),
and a tick-level Python model of HARD mode that uses the real per-alien
16-bit LFSRs (advanced the right number of clocks per tick with a GF(2)
matrix jump) over many random start phases: bounds never violated, aliens
always spawn on the top edge, the aliens never all step in the same tick,
and the first unshot touch happens at ~36 s. **Do a first compile in
ModelSim and Quartus before relying on it**, and check Quartus timing at
50 MHz: the title/mux logic and the 21 per-alien comparators sit in front of
the `rgb` register. HARD mode costs roughly 21 x ~60 flip-flops for the
per-alien state.)

## Synthesizing in Xilinx ISE 14.7 (original paper's target)

Add `vga_controller.v`, `clk_divider.v`, `graphics.v`, and `main.v` (not
the testbench, and `debounce.v`/`hex7seg.v` aren't wired in unless you
insert them yourself — `main.v`'s original 8 ports stay exactly as the
paper's Fig. 5, with `score`/`level`/`lives`/`game_over`/`game_won` simply left
unconnected and `mode` tied to `2'b00`, i.e. EASY) to a new project targeting the Spartan-6 part you have (paper
doesn't name the exact part/package — set it to match your board), set
`main` as the top module, and constrain `clk`, `left`, `right`, `shoot`,
`not_reset`, `rgb[2:0]`, `hsync`, `vsync` to your board's `.ucf` pins
(P4/F6/N4 push buttons per Table 2, plus your VGA connector pins).

## Synthesizing on a Terasic DE2-115 (Cyclone IV E, EP4CE115F29C7) in Quartus

`main.v`'s original 8 ports stay pin-for-pin identical to the paper's Fig.
5 (1-bit-per-channel `rgb`, no `VGA_CLK`/`VGA_BLANK_N`/`VGA_SYNC_N`), but
the DE2-115's VGA port is driven through an ADV7123 video DAC that needs
an 8-bit bus per colour channel plus those extra control signals, its
`KEY[3:0]` push buttons are active-low, and its 7-seg displays need a hex
decoder. `board/de2115/` adapts between `main` and the board without
touching `main.v`'s core logic:

- `de2115_top.v` — board top-level. Instantiates `main` unchanged, expands
  `rgb`'s 3 bits to the 8-bit `VGA_R`/`VGA_G`/`VGA_B` buses, drives
  `VGA_CLK`/`VGA_BLANK_N`/`VGA_SYNC_N`, and decodes `main`'s `score`/`level`
  extension outputs onto `HEX0`/`HEX1`/`HEX2` via `hex7seg.v`. `KEY[0]` =
  reset (wired straight to `main`'s active-low `not_reset`; returns to
  the title screen), `KEY[1]`/`KEY[2]`/`KEY[3]` = right/left/shoot
  (inverted, since DE2-115 buttons read `0` when pressed) and also the
  "any key" that starts the game from the title. `SW[1:0]` (through
  the same `debounce` synchroniser) drive `main`'s `mode`: both down = EASY,
  SW0 up = MEDIUM, SW1 up = HARD (SW1 wins over SW0).
- `de2115_pins.qsf` — pin + I/O-standard assignments for `CLOCK_50`,
  `KEY[3:0]`, `SW[0]`/`SW[1]` (PIN_AB28 / PIN_AC28, from the DE2-115 pin table; same
  JP7 2.5 V default caveat as the HEX pins), all `VGA_*` signals, and
  `HEX0`/`HEX1`/`HEX2`. All verified
  against the official DE2-115 User Manual (Table 4-4 and the JP7 jumper
  table) plus several independently-published DE2-115 `.qsf` files —
  VGA_R/G/B are 8 bits wide on this board (unlike the 10-bit bus on the
  older DE2/DE2-70), the HEX displays are **active-low** (driving a
  segment pin to 0 turns it on — `hex7seg.v` already builds its output
  that way), and the HEX pins use IO standard "2.5 V", which assumes your
  board's JP7 jumper is at its factory-default position. If someone has
  moved JP7 to the 3.3V setting, change those HEX `IO_STANDARD` lines to
  "3.3-V LVTTL" to match.

In Quartus: add all `src/*.v` files (`graphics.v`, `main.v`,
`vga_controller.v`, `clk_divider.v`, `debounce.v`, `hex7seg.v`) plus
`board/de2115/de2115_top.v` to your project, set `de2115_top` as the
top-level entity, then import `de2115_pins.qsf`'s assignments
(Assignments → Import Assignments, or paste its contents into your
project's own `.qsf`). Compile and program as usual — `CLOCK_50` already
matches this reproduction's assumed 50 MHz, so no clock-divider changes
are needed.

`score` is shown in **hexadecimal** (00–FF) across `HEX1`:`HEX0`, not
decimal — simplest to build directly from the binary score register.
`level` (0–3) shows as a single hex digit on `HEX2`.

If the picture shows a faint vertical shimmer/ghosting once it's on
screen, try inverting the DAC clock in `de2115_top.v`
(`assign VGA_CLK = ~CLOCK_50;`) — a common tweak to give the ADV7123 a
cleaner sampling edge relative to when the pixel data changes.

## Ideas not implemented (in case you want to keep going)

- Showing `lives`/`game_won` on the board's `LEDR`/`LEDG` LEDs — skipped only
  because those pins weren't independently pin-verified.
- Decimal score on the 7-segment displays (they still show hex; the on-screen
  HUD shows decimal) — needs a binary-to-BCD stage (double-dabble).
- "Press any key to play again" on the game-over / game-won screens (reset
  is KEY0 for now), a high-score register, the mode shown in the HUD.
- Keeping HARD aliens from overlapping (e.g. a per-row lane or a simple
  push-apart rule), shields, a bonus UFO, several alien bullets at once, speed
  escalation, audio via the WM8731 codec, a 2-frame alien animation, pause.
