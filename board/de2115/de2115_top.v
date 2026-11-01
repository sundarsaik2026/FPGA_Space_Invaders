//------------------------------------------------------------------------------
// de2115_top.v
//
// Board top-level for the Terasic DE2-115 (Cyclone IV E, EP4CE115F29C7).
// `main` (src/main.v) is instantiated UNCHANGED -- this file only adapts
// its pinout to what this board's hardware actually needs:
//
//   * DE2-115's VGA port is driven through an ADV7123 triple video DAC,
//     which needs an 8-bit bus per colour channel (not `main`'s 1-bit-
//     per-channel `rgb`), plus VGA_CLK / VGA_BLANK_N / VGA_SYNC_N pins
//     that `main` doesn't produce (its Fig.5-accurate ports stop at
//     rgb/hsync/vsync).
//   * KEY[3:0] on this board are active-LOW push buttons. KEY[0] = reset
//     (back to the title screen); KEY[1]/KEY[2]/KEY[3] = right/left/shoot,
//     and any of those three also starts the game from the title screen.
//   * SW[1:0] select the mode on the title screen -- `main`'s `mode`
//     extension input:  SW[1] up = HARD (independent aliens);
//     else SW[0] up = MEDIUM; both down = EASY.
//   * `main`'s score/level extension outputs (not in the paper) are
//     decoded onto the onboard HEX0/HEX1 (score, in hex) and HEX2 (level)
//     7-segment displays via src/hex7seg.v.
//
// KEY[3:0] are also debounced here (src/debounce.v) -- raw mechanical
// switch bounce would otherwise make the ship jump multiple steps or
// fire multiple bullets from a single press.
//
// Set this module (not `main`) as the Quartus top-level entity, and use
// de2115_pins.qsf for the pin/IO-standard assignments.
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module de2115_top (
    input  wire        CLOCK_50,   // 50 MHz onboard oscillator
    input  wire [3:0]  KEY,        // active-low push buttons
    input  wire [1:0]  SW,         // mode, read on the title screen: SW1 up = HARD; else SW0 up = MEDIUM; both down = EASY

    output wire [7:0]  VGA_R,
    output wire [7:0]  VGA_G,
    output wire [7:0]  VGA_B,
    output wire        VGA_CLK,
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire        VGA_BLANK_N,
    output wire        VGA_SYNC_N,

    output wire [6:0]  HEX0,       // score, low hex digit
    output wire [6:0]  HEX1,       // score, high hex digit
    output wire [6:0]  HEX2        // level
);

    // Debounce all four KEYs before using them (~10 ms settle time each,
    // see src/debounce.v). key_d[] carries the same active-low, idle-high
    // convention as the raw KEY[] pins.
    wire [3:0] key_d;

    debounce U_DEB0 (.clk(CLOCK_50), .in(KEY[0]), .out(key_d[0]));
    debounce U_DEB1 (.clk(CLOCK_50), .in(KEY[1]), .out(key_d[1]));
    debounce U_DEB2 (.clk(CLOCK_50), .in(KEY[2]), .out(key_d[2]));
    debounce U_DEB3 (.clk(CLOCK_50), .in(KEY[3]), .out(key_d[3]));

    // KEY[0] = reset (matches `main`'s active-low not_reset directly),
    // KEY[1] = right, KEY[2] = left, KEY[3] = shoot (inverted: these
    // buttons read '0' when pressed, `main` expects '1' when pressed).
    wire right = ~key_d[1];
    wire left  = ~key_d[2];
    wire shoot = ~key_d[3];

    // SW[1:0] pick the mode: SW[1] up = HARD (it wins over SW[0]), else
    // SW[0] up = MEDIUM, both down = EASY. A slide switch doesn't bounce, so
    // no debounce counter is needed -- but it is asynchronous to CLOCK_50, so
    // it still goes through a 2-flop synchroniser (avoids metastability).
    reg [1:0] sw_s0 = 2'b00, sw_d = 2'b00;
    always @(posedge CLOCK_50) begin
        sw_s0 <= SW;
        sw_d  <= sw_s0;
    end
    wire [1:0] mode = {sw_d[1], sw_d[0] & ~sw_d[1]};   // 00 EASY, 01 MEDIUM, 10 HARD

    wire [2:0] rgb;
    wire       hsync, vsync;
    wire [7:0] score_s;
    wire [1:0] level_s;
    wire [1:0] lives_s;      // not currently displayed on this board -- see README for a LEDR idea
    wire       game_over_s;  // not currently displayed on this board -- the on-screen "GAME OVER" text already shows it
    wire       game_won_s;   // likewise for the on-screen "GAME WON" text

    main U_MAIN (
        .clk       (CLOCK_50),
        .left      (left),
        .right     (right),
        .shoot     (shoot),
        .not_reset (key_d[0]),
        .mode      (mode),
        .rgb       (rgb),
        .hsync     (hsync),
        .vsync     (vsync),
        .score     (score_s),
        .level     (level_s),
        .lives     (lives_s),
        .game_over (game_over_s),
        .game_won  (game_won_s)
    );

    // Expand each 1-bit colour channel (rgb[2]=R, rgb[1]=G, rgb[0]=B,
    // per the paper's Table 1) to the DE2-115's 8-bit-per-channel VGA
    // bus -- full-on/full-off, since the design only ever needs 8
    // colours, matching the paper.
    assign VGA_R = {8{rgb[2]}};
    assign VGA_G = {8{rgb[1]}};
    assign VGA_B = {8{rgb[0]}};

    assign VGA_HS = hsync;
    assign VGA_VS = vsync;

    // graphics.v already forces rgb to 3'b000 (black) whenever video_on
    // is low (blanking), so it's safe to hold BLANK_N high permanently
    // and let that black pixel data do the actual blanking.
    assign VGA_BLANK_N = 1'b1;
    assign VGA_SYNC_N  = 1'b0;   // sync-on-green unused; HS/VS carry sync

    // The ADV7123 DAC samples R/G/B on VGA_CLK's rising edge. All of
    // main's outputs are already registered on CLOCK_50 (vga_controller
    // uses a /2 enable, not a separate clock domain), so driving the
    // DAC straight from CLOCK_50 keeps data and DAC clock in the same
    // domain. If the picture shows a faint vertical shimmer/ghosting,
    // try inverting this (VGA_CLK = ~CLOCK_50) to move the DAC's sample
    // edge away from the data-transition edge.
    assign VGA_CLK = CLOCK_50;

    // Score/level display -- not from the paper. score is shown in hex
    // (00-FF) across HEX1:HEX0, level as a single hex digit on HEX2. The
    // DE2-115's HEX displays are active-low (0 lights a segment); hex7seg
    // already builds its output in that polarity, so these wire straight
    // across with no inversion.
    hex7seg U_HEX0 (.hex(score_s[3:0]), .seg(HEX0));
    hex7seg U_HEX1 (.hex(score_s[7:4]), .seg(HEX1));
    hex7seg U_HEX2 (.hex({2'b00, level_s}), .seg(HEX2));

endmodule
