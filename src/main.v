//------------------------------------------------------------------------------
// main.v
//
// Top-level module. The original 8 ports still match the paper's Figure 5
// RTL view / Table 2 pin description exactly:
//
//   clk, left, right, shoot, not_reset  -->  rgb, hsync, vsync
//
// score/level/lives/game_over/game_won are trailing EXTENSION outputs and
// `mode` an extension input, none of them in the paper's own port list --
// they drive the DE2-115's 7-segment score display and read its mode
// switches (board/de2115/de2115_top.v). Leave the outputs unconnected and tie
// `mode` low (EASY) if you only want the paper-faithful pinout (e.g.
// targeting the original Xilinx ISE flow).
//
// Internally wires up Graphics and VGA the way Figure 4 (Data Path
// Architecture) shows: VGA drives pixel_x/pixel_y/video_on into Graphics,
// Graphics' colour output is registered through a D flip-flop ("fd_1" in
// Figure 4) before being presented on rgb, and a free-running clock divider
// throttles ship/bullet movement (Section 3.B).
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module main #(
    // Exposed so a testbench can shrink the movement-tick period for
    // fast simulation; synthesis keeps the default (~100 Hz at 50 MHz).
    parameter integer MOVE_DIVISOR      = 500000,
    // Alien-formation extension (not in the paper -- see graphics.v):
    // row/column count and sweep range. The per-mode timing constants
    // (descent / sideways drift / alien fire rates and bullet speed, and
    // the HARD-mode per-alien speed classes) are graphics.v's own
    // parameters and keep their defaults here.
    parameter integer ALIEN_ROWS        = 3,
    parameter integer MAX_SWEEP         = 144,
    parameter integer ALIEN_FIRE_ENABLE = 1,
    parameter integer SHIP_MOVE_DIVIDER = 5
) (
    input  wire        clk,        // 50 MHz board clock (Table 2)
    input  wire        left,       // board button P4
    input  wire        right,      // board button F6
    input  wire        shoot,      // board button N4
    input  wire        not_reset,  // reverse-logic reset ('0' = reset)
    input  wire [1:0]  mode,       // extension input: 0 = EASY, 1 = MEDIUM, 2/3 = HARD (read on the title screen); tie low for paper-faithful use
    output reg  [2:0]  rgb,
    output wire        hsync,
    output wire        vsync,
    output wire [7:0]  score,      // extension output, see header comment
    output wire [1:0]  level,      // extension output, see header comment
    output wire [1:0]  lives,      // extension output, see header comment
    output wire        game_over,  // extension output, see header comment
    output wire        game_won    // extension output, see header comment
);

    wire        video_on_s;
    wire [9:0]  pixel_x_s, pixel_y_s;
    wire        move_tick_s;
    wire [2:0]  graphics_rgb_s;
    wire        destruction_s;    // debug only, left unrouted at the top level

    vga_controller U_VGA (
        .clk       (clk),
        .not_reset (not_reset),
        .hsync     (hsync),
        .vsync     (vsync),
        .video_on  (video_on_s),
        .p_tick    (),               // unused here
        .pixel_x   (pixel_x_s),
        .pixel_y   (pixel_y_s)
    );

    clk_divider #(
        .DIVISOR (MOVE_DIVISOR)
    ) U_CLKDIV (
        .clk       (clk),
        .not_reset (not_reset),
        .tick      (move_tick_s)
    );

    graphics #(
        .ALIEN_ROWS        (ALIEN_ROWS),
        .MAX_SWEEP         (MAX_SWEEP),
        .ALIEN_FIRE_ENABLE (ALIEN_FIRE_ENABLE),
        .SHIP_MOVE_DIVIDER (SHIP_MOVE_DIVIDER)
    ) U_GRAPHICS (
        .clk           (clk),
        .not_reset     (not_reset),
        .video_on      (video_on_s),
        .px_x          (pixel_x_s),
        .px_y          (pixel_y_s),
        .move_tick     (move_tick_s),
        .nes_left      (left),
        .nes_right     (right),
        .shoot         (shoot),
        .mode          (mode),
        .rgb           (graphics_rgb_s),
        .score         (score),
        .level         (level),
        .lives         (lives),
        .destruction_o (destruction_s),
        .game_over_o   (game_over),
        .game_won_o    (game_won)
    );

    // fd_1: single-cycle output register on the colour path (Figure 4)
    always @(posedge clk) begin
        rgb <= graphics_rgb_s;
    end

endmodule
