# FPGA Space Invaders on the DE2-115 (Verilog)

A playable Space Invaders game written in Verilog for the Terasic DE2-115 board
(Cyclone IV E, EP4CE115F29C7), shown on a VGA monitor at 640 x 480.

It reproduces *"Design and Implementation of a FPGA based Game 'Space Invaders'"*
(R. Parihar, A. Kumar, A. Mishra, International Journal of Control Theory and
Applications, Vol. 9, No. 44, 2016) and extends it. The paper uses VHDL on a
Spartan-6; this project is a Verilog port of the same architecture for the DE2-115.

Course project: Digital Design with FPGA, M.Tech VLSI Design, VIT.
Team: **[FILL: names and registration numbers]** | Guide: **[FILL: name]**

## Features

- Pure-hardware game: no processor and no frame buffer. The colour of every pixel
  is computed combinationally while the VGA beam scans the screen.
- 640 x 480 @ about 59.5 Hz VGA, 25 MHz pixel rate derived from the 50 MHz board clock.
- Game state machine: title, play, game over, game won.
- 21 aliens (3 rows x 7 columns), random green or magenta colour per alien.
- Three difficulty modes chosen with the switches:
  - **EASY**: rigid formation, slow random drift and descent.
  - **MEDIUM**: same formation, about 3-4 times faster, faster alien bullets.
  - **HARD**: no formation; each alien roams independently with its own speed.
- Aliens fire back (two shooters). 3 lives; an alien reaching the ship's row is game over.
- Title screen with starfield, striped frame and 5 x 7 pixel font; on-screen score and lives.
- Score and level on the seven-segment displays.

## Controls

| Board control | Function |
| --- | --- |
| KEY0 | Reset, back to the title screen from any state |
| KEY1 | Move ship right |
| KEY2 | Move ship left |
| KEY3 | Shoot |
| KEY1 / KEY2 / KEY3 on the title screen | Start the game |
| SW[1:0] | Mode, read on the title screen: 00 = EASY, 01 = MEDIUM, 1x = HARD |
| HEX1:HEX0 | Score (hex) |
| HEX2 | Level |

## Repository layout

```
src/                 main.v, graphics.v, vga_controller.v, clk_divider.v, debounce.v, hex7seg.v
board/de2115/        de2115_top.v (Quartus top level), de2115_pins.qsf (pin assignments)
sim/                 tb_main.v (five ModelSim testbenches)
docs/                DESIGN_NOTES.md and PDF reports
```

## Module overview

| Module | Role |
| --- | --- |
| de2115_top | Board wrapper: debounces KEY[3:0], synchronises SW[1:0], widens the 3-bit colour to 8 bits per channel, drives the VGA pins and HEX displays |
| main | Connects vga_controller, clk_divider and graphics; holds the output colour register |
| vga_controller | 800 x 525 pixel counters, hsync, vsync, video_on, pixel_x, pixel_y |
| clk_divider | Divides 50 MHz by 500,000 to give the 100 Hz game tick |
| graphics | Game FSM, ship, bullets, aliens, collisions, score, lives, text and the per-pixel colour mux |
| debounce | Counter-based push-button debouncer (about 10 ms) |
| hex7seg | 4-bit to seven-segment decoder |

## Build and run (Quartus)

1. Create a Quartus project for device **EP4CE115F29C7**.
2. Add all files in `src/` and `board/de2115/de2115_top.v`.
3. Set **de2115_top** as the top-level entity.
4. Import `board/de2115/de2115_pins.qsf` (Assignments > Import Assignments).
5. Compile, then program the `.sof` file with the Programmer.
6. Connect a VGA monitor, set SW[1:0], and press KEY1, KEY2 or KEY3 to start.

## Simulation (ModelSim)

```
vlib work
vlog src/vga_controller.v src/clk_divider.v src/graphics.v src/hex7seg.v src/debounce.v src/main.v
vlog sim/tb_main.v
vsim work.tb_main        # also: tb_touch, tb_lives, tb_modes, tb_hard
add wave -r /*
run -all
```

| Testbench | Checks |
| --- | --- |
| tb_main | EASY gameplay: title, ship, shooting, collision, score, all aliens shot gives GAME WON, reset |
| tb_touch | An alien reaching the ship's row ends the game immediately |
| tb_lives | Alien bullets take lives 3 > 2 > 1 > 0 |
| tb_modes | EASY vs MEDIUM speed ratio, mode latched at start |
| tb_hard | HARD aliens spawn on the top edge, stay in bounds, move independently |

## Key parameters

| Item | Value |
| --- | --- |
| System clock | 50 MHz |
| Pixel rate | 25 MHz |
| Game tick | 100 Hz (`MOVE_DIVISOR` = 500000) |
| Ship step | every 5 ticks (`SHIP_MOVE_DIVIDER`) |
| Aliens | 21, 32 x 18 px |
| Ship / bullet | 40 x 16 px / 4 x 14 px |
| Lives | 3 |

## Results

Resource usage and timing from the Quartus Compilation Report:
**[FILL: logic elements, registers, pins, Fmax]**

Photos and waveforms: **[FILL: add images under docs/ and link them here]**

## Documentation

- `docs/DESIGN_NOTES.md`: detailed design notes and deviations from the paper
- `docs/Detailed_Report.pdf`: full explanation of how the program works
- `docs/Modules_Summary.pdf`: one-page module and signal summary
- `docs/Game_Flow.pdf`: game flow in detail
- `docs/Hard_Mode_Explained.pdf`: HARD mode alien logic
- `docs/Bullet_Alien_Hit_Logic.pdf`: bullet, alien and hit logic
- `docs/DE2-115_Manual.pdf`: board setup notes

## Reference

R. Parihar, A. Kumar and A. Mishra, "Design and Implementation of a FPGA based Game
'Space Invaders'", International Journal of Control Theory and Applications,
Vol. 9, No. 44, 2016.
