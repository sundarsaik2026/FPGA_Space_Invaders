//------------------------------------------------------------------------------
// graphics.v
//
// Reproduces Section 3.A "Game Logic" (Graphics + scoring) and Section 3.B
// "Game Control" (buttons/movement) of the paper, extended (beyond the
// paper) with:
//   * a redesigned alien sprite (an original bug-eyed alien head),
//   * ALIEN_ROWS rows of ALIEN_COLS aliens (21 by default),
//   * aliens firing back down at the ship at random intervals,
//   * a 3-life system for alien-BULLET hits: lives count 3 -> 2 -> 1 and
//     the next hit (lives would reach 0) is game over,
//   * an ALIEN REACHING THE SHIP'S ROW (the bottom of the play area) is
//     game over immediately, whatever number of lives is left,
//   * a GAME-WON screen once every alien has been shot,
//   * a static TITLE screen ("press any key to start") and a 4-state game
//     FSM: TITLE -> PLAY -> (OVER | WON); reset returns to TITLE,
//   * three difficulty modes, selected with the 2-bit `mode` input (SW[1:0]
//     on the DE2-115) while the title screen is showing and latched when the
//     game starts:
//         EASY   (mode 0): rigid formation, original speed;
//         MEDIUM (mode 1): rigid formation, ~3-4x EASY's drift/descent/fire
//                          rate and faster alien bullets;
//         HARD   (mode 2): NO formation -- every alien is an independent
//                          agent with its own x/y registers and its own
//                          state machine and random-number generator
//                          (see "HARD MODE" below).
//   * the paper's `restart_next` / `level_next` / `score_next` equations,
//     generalised from its 3 explicit flags to an ALIEN_ROWS*ALIEN_COLS
//     `defeated` vector; clearing every alien raises `level` and ends the
//     game with the WON screen.
// None of the multi-row grid, moving aliens, alien return fire, lives,
// title/won/over screens or difficulty modes exist in the paper -- it
// explicitly has no losing condition at all ("The game continues as the
// star keeps appearing on the screen"). The ship movement,
// single-bullet-at-a-time firing model, and scoring equations are still
// the paper's own.
//
// RANDOMISED FORMATION MOTION (EASY / MEDIUM)
//   Every "next event" delay is drawn at random from a free-running 32-bit
//   LFSR each time the previous event happens:
//     * descent  : wait *_DESC_MIN + rand ticks, then drop 1, 2 or 3 px;
//     * sideways : wait *_HORIZ_MIN + rand ticks, then step 1 px, with a
//                  1-in-256 chance at each step of reversing instead (so it
//                  keeps going and really uses the whole screen width);
//     * firing   : wait *_FIRE_MIN + rand ticks, then a random alien fires
//                  (if that one is already dead, retry on the next tick).
//   The LFSR is NOT reset, so the moment the player presses a key decides
//   the sequence and no two games play the same.
//
// HARD MODE: INDEPENDENT ALIENS
//   Each alien k is a generate-block instance (gen_alien[k]) holding ITS OWN
//   x and y registers, direction, "speed class" attributes, countdown
//   timers, a 16-bit LFSR (different seed per alien) and a 2-state machine:
//     WAIT : not yet on screen; counts a random spawn delay (staggered by
//            row), then appears ON THE TOP EDGE of the play rectangle at a
//            random x inside its own column slot, with random attributes;
//     ROAM : drifts sideways (own speed class, own 1- or 2-px steps, own
//            random reversals) and descends (own speed class, own 1- or
//            2-px steps) completely independently of every other alien.
//   All aliens are clamped inside the play rectangle
//       x in [BOX_X0, BOX_X1-16]   y in [BOX_Y0, BOX_Y1-9]
//   (the bottom edge BOX_Y1 is the ship's row). No alien's motion depends on
//   any other alien's, so there is no rigid group movement; an alien that
//   gets down to the ship's row ends the game.
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module graphics #(
    parameter integer ALIEN_ROWS          = 3,     // number of alien rows (paper's code only ever had 1)
    parameter integer MAX_SWEEP           = 144,   // max px the formation drifts from centre, each direction (144 = it can reach the frame on both sides)
    parameter integer SHIP_MOVE_DIVIDER   = 5,     // move_ticks between each ship step (see the ship-movement block below)
    parameter integer ALIEN_FIRE_ENABLE   = 1,     // 0 = aliens never shoot (used by tb_main to stay deterministic)

    // ---- EASY mode timing: tuned to the original (pre-randomisation) speed
    // wait before next descent step = EASY_DESC_MIN  + (0..63)  -> avg ~50 ticks, avg 2 px per step
    // wait before next sideways step = EASY_HORIZ_MIN + (0..31)  -> avg ~40 ticks, 1 px per step
    // wait before next alien shot    = EASY_FIRE_MIN  + (0..255) -> avg ~300 ticks (~3 s)
    parameter integer EASY_DESC_MIN       = 18,
    parameter integer EASY_HORIZ_MIN      = 23,
    parameter integer EASY_FIRE_MIN       = 171,
    parameter integer EASY_ABULLET_SPEED  = 4,     // px per move_tick, alien bullets

    // ---- MEDIUM mode timing (rigid formation): roughly 3-4x EASY
    // wait before next descent step = MED_DESC_MIN  + (0..15) -> avg ~16 ticks, avg 2 px per step
    // wait before next sideways step = MED_HORIZ_MIN + (0..7)  -> avg ~9 ticks,  1 px per step
    // wait before next alien shot    = MED_FIRE_MIN  + (0..63) -> avg ~92 ticks (~0.9 s)
    parameter integer MED_DESC_MIN        = 8,
    parameter integer MED_HORIZ_MIN       = 5,
    parameter integer MED_FIRE_MIN        = 60,
    parameter integer MED_ABULLET_SPEED   = 6,

    // ---- HARD mode (independent aliens)
    // alien fire: HARD_FIRE_MIN + (0..63) -> avg ~77 ticks
    parameter integer HARD_FIRE_MIN       = 45,
    parameter integer HARD_ABULLET_SPEED  = 6,
    // Each alien draws a sideways "speed class" and a descent "speed class"
    // (0, 1 or 2) when it spawns; the class sets the minimum wait between
    // its steps (the actual wait is the class value + a fresh random 0..7
    // for sideways, 0..15 for descent), so aliens differ in speed:
    //   sideways step (1 or 2 px): ~23 / ~16 / ~11 px per second
    //   descent step  (1 or 2 px): ~10 / ~8 / ~6 px per second
    parameter integer HARD_H_MIN0         = 3,
    parameter integer HARD_H_MIN1         = 6,
    parameter integer HARD_H_MIN2         = 10,
    parameter integer HARD_D_MIN0         = 6,
    parameter integer HARD_D_MIN1         = 10,
    parameter integer HARD_D_MIN2         = 15,
    parameter integer HARD_SPAWN_GAP      = 100    // extra spawn delay per alien row, in move_ticks
) (
    input  wire        clk,
    input  wire        not_reset,      // '0' = reset
    input  wire        video_on,
    input  wire [9:0]  px_x,
    input  wire [9:0]  px_y,
    input  wire        move_tick,      // slow tick from clk_divider
    input  wire        nes_left,       // board button P4
    input  wire        nes_right,      // board button F6
    input  wire        shoot,          // board button N4
    input  wire [1:0]  mode,           // 0 = EASY, 1 = MEDIUM, 2 (or 3) = HARD (sampled while the title screen is up)
    output reg  [2:0]  rgb,
    output wire [7:0]  score,          // debug/observation + 7-seg display
    output wire [1:0]  level,          // debug/observation + 7-seg display
    output wire [1:0]  lives,          // debug/observation only
    output wire        destruction_o,  // debug/observation only
    output wire        game_over_o,    // debug/observation only
    output wire        game_won_o      // debug/observation only
);

    //----------------------------------------------------------------
    // 3-bit colour codes (Table 1 of the paper, plus the other three
    // single-bit-per-channel mixes used by the title screen)
    //----------------------------------------------------------------
    localparam [2:0] COLOR_BLACK   = 3'b000;
    localparam [2:0] COLOR_BLUE    = 3'b001;
    localparam [2:0] COLOR_GREEN   = 3'b010;
    localparam [2:0] COLOR_CYAN    = 3'b011;
    localparam [2:0] COLOR_RED     = 3'b100;
    localparam [2:0] COLOR_MAGENTA = 3'b101;
    localparam [2:0] COLOR_YELLOW  = 3'b110;
    localparam [2:0] COLOR_WHITE   = 3'b111;

    //----------------------------------------------------------------
    // Game FSM: TITLE -> PLAY -> OVER (lost) or WON (every alien shot).
    // Reset returns to TITLE.
    //----------------------------------------------------------------
    localparam [1:0] S_TITLE = 2'd0;
    localparam [1:0] S_PLAY  = 2'd1;
    localparam [1:0] S_OVER  = 2'd2;
    localparam [1:0] S_WON   = 2'd3;

    //----------------------------------------------------------------
    // Sprite geometry
    //----------------------------------------------------------------
    localparam STAR_ROWS = 9,  STAR_COLS = 16;   // alien sprite box (name kept for the case-statement lookup below)
    localparam SHIP_ROWS = 8,  SHIP_COLS = 20;     // ship sprite bitmap size

    // On screen every sprite pixel is drawn SPR_SCALE x SPR_SCALE screen pixels,
    // so the in-game sizes are:  alien 32 x 18, ship 40 x 16, bullets 4 x 14.
    localparam SPR_SCALE = 2;
    localparam ALIEN_W   = STAR_COLS * SPR_SCALE;   // 32
    localparam ALIEN_H   = STAR_ROWS * SPR_SCALE;   // 18
    localparam SHIP_W    = SHIP_COLS * SPR_SCALE;   // 40
    localparam SHIP_H    = SHIP_ROWS * SPR_SCALE;   // 16

    localparam SCREEN_WIDTH  = 640;
    localparam SCREEN_HEIGHT = 480;

    localparam SHIP_Y      = 440;
    localparam SHIP_X_INIT = (SCREEN_WIDTH / 2) - (SHIP_W / 2);
    // The frame (border) is drawn 8..11 px in from every edge, so the playfield
    // is x 12..627, y 12..467. The ship stays 4 px inside it; alien bullets are
    // removed just before they reach the bottom frame (FLOOR_Y).
    localparam SHIP_X_MIN  = 16;
    localparam SHIP_X_MAX  = 624 - SHIP_W;
    localparam FLOOR_Y     = 468;
    localparam SHIP_STEP   = 5;   // matches the paper's "+5 / -5" step

    // Rigid formation (EASY / MEDIUM): ALIEN_COLS columns x ALIEN_ROWS rows,
    // evenly spaced, centred on the screen; its live position is the
    // x_offset / descent_offset registers below. (HARD mode ignores the
    // formation completely -- see the play rectangle further down.)
    localparam ALIEN_COLS    = 7;
    localparam ALIEN_Y0      = 60;
    localparam ALIEN_SPACING = 48;
    localparam ALIEN_X0      = (SCREEN_WIDTH - ((ALIEN_COLS - 1) * ALIEN_SPACING + ALIEN_W)) / 2;
    localparam ROW_SPACING   = 26;                      // vertical gap between alien rows
    localparam TOTAL_ALIENS  = ALIEN_COLS * ALIEN_ROWS;

    localparam BULLET_W = 4;
    localparam BULLET_H = 14;
    // NOTE: no pure red is used for anything that must be seen. On the lab board's
    // monitor/cable the red channel did not reach the screen (red parts came out
    // black, yellow came out green, white came out cyan), so every in-game colour
    // contains green and/or blue. Change these constants if your red channel works.
    localparam [2:0] ALIEN_COLOR_A      = COLOR_GREEN;   // aliens, colour set A (random per alien)
    localparam [2:0] ALIEN_COLOR_B      = COLOR_MAGENTA; // aliens, colour set B (random per alien)
    localparam [2:0] BULLET_COLOR       = COLOR_WHITE;   // player bullet
    localparam [2:0] ALIEN_BULLET_COLOR = COLOR_YELLOW;  // alien bullets
    localparam BULLET_SPEED = 4;   // px per move_tick, PLAYER bullet (alien bullets: EASY_/HARD_ABULLET_SPEED)

    // HARD-mode play rectangle. Aliens spawn on its top edge and never leave
    // it; its bottom edge is the ship's row, so an alien that gets all the
    // way down touches the ship's row -> game over. Each column owns a
    // SLOT_W-wide slot to spawn in (so spawns do not stack on each other).
    localparam SLOT_W    = 86;
    localparam BOX_X0    = 16;
    localparam BOX_X1    = BOX_X0 + ALIEN_COLS * SLOT_W;   // 618, exclusive right edge
    localparam BOX_Y0    = 52;                             // top edge (below the HUD)
    localparam BOX_Y1    = SHIP_Y;                         // bottom edge = the ship's row
    localparam X_MAX     = BOX_X1 - ALIEN_W;             // largest legal alien x
    localparam Y_MAX     = BOX_Y1 - ALIEN_H;             // largest legal alien y
    localparam SPAWN_PAD = 12;                             // spawn x = slot start + PAD + rand(0..31)

    //----------------------------------------------------------------
    // Alien sprite (9 rows x 16 cols) -- an original bug-eyed alien head:
    // antennae on top, two eye sockets, a jaw fringe, wide feet at the
    // bottom. Redrawn/original, not a reproduction of any existing game's
    // character art (and not the paper's plain star either).
    //----------------------------------------------------------------
    function [STAR_COLS-1:0] star_row;
        input [3:0] r;
        begin
            case (r)
                4'd0: star_row = 16'b0000001001000000;
                4'd1: star_row = 16'b0000011001100000;
                4'd2: star_row = 16'b0000111111100000;
                4'd3: star_row = 16'b0011111111111100;
                4'd4: star_row = 16'b0111100000011110;
                4'd5: star_row = 16'b0111100000011110;
                4'd6: star_row = 16'b0011111111111100;
                4'd7: star_row = 16'b0110011001100110;
                4'd8: star_row = 16'b1100000000000011;
                default: star_row = 16'b0;
            endcase
        end
    endfunction

    //----------------------------------------------------------------
    // Spaceship sprite (8 rows x 20 cols) -- simple triangular ship
    //----------------------------------------------------------------
    function [SHIP_COLS-1:0] ship_row;
        input [2:0] r;
        begin
            case (r)
                3'd0: ship_row = 20'b00000000011000000000;
                3'd1: ship_row = 20'b00000000111100000000;
                3'd2: ship_row = 20'b00000001111110000000;
                3'd3: ship_row = 20'b00000001111110000000;
                3'd4: ship_row = 20'b00000011111111000000;
                3'd5: ship_row = 20'b00000011111111000000;
                3'd6: ship_row = 20'b00111111111111111100;
                3'd7: ship_row = 20'b00111111111111111100;
                default: ship_row = 20'b0;
            endcase
        end
    endfunction

    //----------------------------------------------------------------
    // Game state
    //----------------------------------------------------------------
    reg [1:0] state = S_TITLE;         // the game FSM
    wire      game_over = (state == S_OVER);
    wire      game_won  = (state == S_WON);
    wire [1:0] mode_n   = mode[1] ? 2'd2 : {1'b0, mode[0]};   // 3 is treated as HARD
    reg [1:0] diff      = 2'd0;        // difficulty in force this game (latched from mode at start): 0 EASY, 1 MEDIUM, 2 HARD
    wire      indep     = diff[1];     // HARD: every alien moves independently
    wire      med       = diff[0];     // MEDIUM flag for the rigid-formation timing functions
    wire      any_key   = nes_left | nes_right | shoot;

    reg [9:0] ship_x = SHIP_X_INIT;

    reg [TOTAL_ALIENS-1:0] defeated = {TOTAL_ALIENS{1'b0}};  // one bit per alien
    reg restart_next = 1'b0;

    reg [7:0] score_reg = 8'd0;
    reg [1:0] level_reg = 2'd0;
    reg [1:0] lives_reg = 2'd3;      // 3 lives to start; 0 = dead
    reg       destruction = 1'b0;
    reg       flip_counter = 1'b0;   // stands in for the paper's counter(0)

    reg nes_a = 1'b0, nes_b = 1'b0;  // shoot edge-detect shift register
    reg bullet_active = 1'b0;
    reg [9:0] bullet_x = 10'd0;
    reg [9:0] bullet_y = 10'd0;

    // Alien return fire (not in the paper).
    reg        alien_bullet_active = 1'b0;
    reg [9:0]  alien_bullet_x      = 10'd0;
    reg [9:0]  alien_bullet_y      = 10'd0;
    reg [15:0] alien_fire_counter  = 16'd0;   // counts DOWN to 0, then an alien tries to fire
    // Second, completely independent shooter: its own bullet, its own fire
    // countdown and its own random alien pick (from its own LFSR, lfsr2), so
    // two different aliens can have a bullet in the air at the same time.
    reg        alien_bullet_b_active = 1'b0;
    reg [9:0]  alien_bullet_b_x      = 10'd0;
    reg [9:0]  alien_bullet_b_y      = 10'd0;
    reg [15:0] alien_fire_counter_b  = 16'd0;
    wire [9:0] abullet_speed = diff[1] ? HARD_ABULLET_SPEED : (diff[0] ? MED_ABULLET_SPEED : EASY_ABULLET_SPEED);

    // Formation motion state (not in the paper). Both counters count DOWN
    // to 0; reaching 0 is "time for the next step", and the counter is then
    // reloaded with a fresh random wait.
    reg [9:0]  descent_offset  = 10'd0;
    reg [15:0] descend_counter = 16'd0;
    reg [8:0]  x_offset        = MAX_SWEEP[8:0];  // starts centred (0 .. 2*MAX_SWEEP, so 9 bits)
    reg        move_dir_right  = 1'b1;
    reg [15:0] horiz_counter   = 16'd0;

    // Lives / game-over (not in the paper).
    reg        life_lost_pending = 1'b0;   // 1-cycle pulse telling the ship-movement block to recentre

    assign score         = score_reg;
    assign level         = level_reg;
    assign lives         = lives_reg;
    assign destruction_o = destruction;
    assign game_over_o   = game_over;
    assign game_won_o    = game_won;

    //----------------------------------------------------------------
    // Free-running 32-bit LFSR (taps 32,22,2,1 -- maximal length, period
    // 2^32-1): advances every clock and is the one source of randomness
    // for the whole design. Deliberately NOT reset: it keeps running
    // through reset and the title screen, so the instant the player presses
    // a key decides where in the sequence the game begins. (An 8-bit LFSR
    // would be a poor choice here: sampled once per move_tick -- exactly
    // 500,000 clocks apart -- it would only ever visit a handful of its 255
    // states, i.e. a short, repeating, patterned "random" sequence.)
    // Independent driver, no conflicts with the blocks below.
    //----------------------------------------------------------------
    reg [31:0] lfsr = 32'hACE12468;   // any non-zero value
    wire       lfsr_fb = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];

    always @(posedge clk) begin
        lfsr <= {lfsr[30:0], lfsr_fb};
    end

    // Second 32-bit LFSR for shooter B: a DIFFERENT maximal polynomial
    // (x^32 + x^30 + x^26 + x^25 + 1, period 2^32-1) and seed, so its bits
    // are not just a delayed copy of lfsr's. Same rules: free-running, never reset.
    reg [31:0] lfsr2 = 32'h5EED1234;

    // Per-alien colour bit (0 = ALIEN_COLOR_A, 1 = ALIEN_COLOR_B), drawn at
    // random once per game: sampled from the two free-running LFSRs while on
    // the title screen, so it freezes at the start key press. Each alien keeps
    // its colour for the whole game (all modes), so colours are mixed within
    // every row instead of one colour per row.
    reg [TOTAL_ALIENS-1:0] acol = {TOTAL_ALIENS{1'b0}};
    wire       lfsr2_fb = lfsr2[31] ^ lfsr2[29] ^ lfsr2[25] ^ lfsr2[24];
    always @(posedge clk) begin
        lfsr2 <= {lfsr2[30:0], lfsr2_fb};
    end

    //----------------------------------------------------------------
    // Random-delay / random-step helpers (combinational, read lfsr).
    // Each one uses its own, non-overlapping slice of the LFSR so the
    // different events don't share the same random bits.
    //   desc_delay  : r[5:0]  (easy) / r[3:0]  (medium)
    //   desc_step   : r[7:6]
    //   horiz_delay : r[12:8] (easy) / r[10:8] (medium)
    //   horiz flip  : r[15:13] == 0      (used inline below)
    //   fire_delay  : r[23:16](easy) / r[21:16](medium, hard)
    //   fire pick   : r[31:24] % TOTAL_ALIENS (used inline below)
    //----------------------------------------------------------------
    function [15:0] desc_delay;
        input        hd;
        input [31:0] r;
        begin
            if (hd) desc_delay = MED_DESC_MIN + r[3:0];
            else    desc_delay = EASY_DESC_MIN + r[5:0];
        end
    endfunction

    function [3:0] desc_step;      // 1, 2, 3 or 2 px (average 2)
        input [1:0] r;
        begin
            case (r)
                2'd0:    desc_step = 4'd1;
                2'd1:    desc_step = 4'd2;
                2'd2:    desc_step = 4'd3;
                default: desc_step = 4'd2;
            endcase
        end
    endfunction

    function [15:0] horiz_delay;
        input        hd;
        input [31:0] r;
        begin
            if (hd) horiz_delay = MED_HORIZ_MIN + r[10:8];
            else    horiz_delay = EASY_HORIZ_MIN + r[12:8];
        end
    endfunction

    function [15:0] fire_delay;
        input [1:0]  m;                    // 0 EASY, 1 MEDIUM, 2 HARD
        input [31:0] r;
        begin
            if (m[1])      fire_delay = HARD_FIRE_MIN + r[21:16];
            else if (m[0]) fire_delay = MED_FIRE_MIN  + r[21:16];
            else           fire_delay = EASY_FIRE_MIN + r[23:16];
        end
    endfunction

    // HARD mode: minimum wait for each speed class (0..2; 3 behaves as 1)
    function [9:0] h_min;
        input [1:0] c;
        begin
            case (c)
                2'd0:    h_min = HARD_H_MIN0;
                2'd2:    h_min = HARD_H_MIN2;
                default: h_min = HARD_H_MIN1;
            endcase
        end
    endfunction

    function [9:0] d_min;
        input [1:0] c;
        begin
            case (c)
                2'd0:    d_min = HARD_D_MIN0;
                2'd2:    d_min = HARD_D_MIN2;
                default: d_min = HARD_D_MIN1;
            endcase
        end
    endfunction

    //----------------------------------------------------------------
    // Alien positions as seen by the rest of the design. One 10-bit x and y
    // per alien, packed into flat vectors (slice k = bits [10*k +: 10]):
    //   hx/hy/hp : HARD-mode independent registers (driven by gen_alien[k])
    //   apx/apy  : the position actually used for drawing, collision, alien
    //              fire and the touch check -- the alien's own registers in
    //              HARD, the rigid formation position in EASY / MEDIUM
    //   present  : alien is on screen (always 1 outside HARD; in HARD an
    //              alien is absent until it has spawned)
    //   alive    : present and not shot
    //----------------------------------------------------------------
    wire [10*TOTAL_ALIENS-1:0] hx_flat, hy_flat, apx_flat, apy_flat;
    wire [TOTAL_ALIENS-1:0]    hp_flat;
    wire [TOTAL_ALIENS-1:0]    present = indep ? hp_flat : {TOTAL_ALIENS{1'b1}};
    wire [TOTAL_ALIENS-1:0]    alive   = present & ~defeated;
    // y at which the player's bullet gives up (the top of the alien area)
    wire [9:0] top_y = indep ? BOX_Y0 : (ALIEN_Y0 + descent_offset);

    //----------------------------------------------------------------
    // HARD MODE: one independent agent per alien.
    //
    // Everything declared inside gen_alien[k] belongs to alien k alone:
    // its position (x, y), direction, speed classes, countdown timers, its
    // own 16-bit LFSR `rnd` (x^16+x^15+x^13+x^4+1, maximal; a different
    // non-zero seed per alien; free-running and never reset, like the
    // global LFSR) and its state `pres` (0 = WAIT, 1 = ROAM). Nothing here
    // reads another alien's registers, so the aliens cannot move as a
    // block. They only read the shared clock/tick/FSM and their own bit of
    // `defeated`.
    //
    // WAIT : in TITLE (and reset) the spawn timer is loaded with
    //        HARD_SPAWN_GAP*row + rand(0..127) and the alien is absent.
    //        Once the game is running (PLAY, HARD) it counts down once per
    //        move_tick; at 0 the alien appears at y = BOX_Y0 (the top edge)
    //        at a random x inside its column slot with random speed classes
    //        and a random direction.
    // ROAM : every move_tick, two independent countdowns run:
    //        sideways -- at 0 take a 1- or 2-px step in its direction
    //          (reverse instead at a wall, or 1 time in 8 at random), then
    //          reload (class minimum + rand(0..7));
    //        descent -- at 0 drop 1 or 2 px (clamped at Y_MAX), then reload
    //          (class minimum + rand(0..15)).
    //        A shot alien stops (and is no longer drawn). The two timers
    //        use disjoint bit-slices of the alien's `rnd`.
    //----------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < TOTAL_ALIENS; g = g + 1) begin : gen_alien
            localparam integer COL = g % ALIEN_COLS;
            localparam integer ROW = g / ALIEN_COLS;
            localparam [15:0]  SEED = 16'hACE1 ^ (g * 16'h9E37);

            reg [15:0] rnd  = SEED;
            wire       rfb  = rnd[15] ^ rnd[14] ^ rnd[12] ^ rnd[3];
            reg        pres = 1'b0;
            reg [9:0]  x    = 10'd0;
            reg [9:0]  y    = 10'd0;
            reg        dirr = 1'b1;               // 1 = moving right
            reg [1:0]  hcls = 2'd1;               // sideways speed class
            reg [1:0]  dcls = 2'd1;               // descent speed class
            reg [9:0]  hcnt = 10'd0;              // sideways countdown
            reg [9:0]  dcnt = 10'd0;              // descent countdown
            reg [9:0]  scnt = 10'd0;              // spawn countdown (WAIT)

            wire [1:0] hstep = rnd[3]  ? 2'd2 : 2'd1;   // this alien's next sideways step size
            wire [1:0] dstep = rnd[12] ? 2'd2 : 2'd1;   // this alien's next drop size
            wire [9:0] x_fwd = x + hstep;
            wire [9:0] y_fwd = y + dstep;

            always @(posedge clk) begin
                rnd <= {rnd[14:0], rfb};

                if (!not_reset || state == S_TITLE) begin
                    pres <= 1'b0;
                    scnt <= HARD_SPAWN_GAP * ROW + rnd[6:0];
                end else if (indep && move_tick && state == S_PLAY) begin
                    if (!pres) begin
                        //---------------- WAIT -> spawn on the top edge
                        if (scnt == 10'd0) begin
                            pres <= 1'b1;
                            x    <= BOX_X0 + COL * SLOT_W + SPAWN_PAD + rnd[4:0];
                            y    <= BOX_Y0;
                            dirr <= rnd[10];
                            hcls <= rnd[6:5];
                            dcls <= rnd[9:8];
                            hcnt <= {6'd0, rnd[3:0]};
                            dcnt <= {6'd0, rnd[15:12]};
                        end else begin
                            scnt <= scnt - 10'd1;
                        end
                    end else if (!defeated[g]) begin
                        //---------------- ROAM: sideways
                        if (hcnt == 10'd0) begin
                            hcnt <= h_min(hcls) + rnd[2:0];
                            if (dirr) begin
                                if (x_fwd > X_MAX)        dirr <= 1'b0;      // right wall: bounce
                                else if ((rnd[6:4] == 3'd0) && (rnd[9:7] == 3'd0)) dirr <= 1'b0;   // random reversal (1 in 64)
                                else                       x <= x_fwd;
                            end else begin
                                if (x < BOX_X0 + hstep)    dirr <= 1'b1;      // left wall: bounce
                                else if ((rnd[6:4] == 3'd0) && (rnd[9:7] == 3'd0)) dirr <= 1'b1;   // random reversal (1 in 64)
                                else                       x <= x - hstep;
                            end
                        end else begin
                            hcnt <= hcnt - 10'd1;
                        end
                        //---------------- ROAM: descent
                        if (dcnt == 10'd0) begin
                            dcnt <= d_min(dcls) + rnd[11:8];
                            y    <= (y_fwd > Y_MAX) ? Y_MAX : y_fwd;
                        end else begin
                            dcnt <= dcnt - 10'd1;
                        end
                    end
                end
            end

            assign hx_flat[10*g +: 10] = x;
            assign hy_flat[10*g +: 10] = y;
            assign hp_flat[g]          = pres;
            assign apx_flat[10*g +: 10] = indep ? x : (ALIEN_X0 + COL * ALIEN_SPACING + x_offset - MAX_SWEEP);
            assign apy_flat[10*g +: 10] = indep ? y : (ALIEN_Y0 + ROW * ROW_SPACING + descent_offset);
        end
    endgenerate

    //----------------------------------------------------------------
    // Ship movement: sigXValue / position_next reproduction (Section 3.B).
    // Only moves while the game is in PLAY, and is recentred the cycle
    // after a life is lost (life_lost_pending, set by the block below --
    // kept in a separate always block only so both can safely drive ship_x
    // without a multi-driver conflict).
    //
    // move_tick alone (~100Hz by default) is too fast to step on directly:
    // even a quick tap of a physical button easily spans 10-20+ move_ticks,
    // so the ship would fly much further than intended from a single
    // press. ship_move_counter divides move_tick down again, so the ship
    // only actually steps once every SHIP_MOVE_DIVIDER move_ticks.
    //----------------------------------------------------------------
    reg [15:0] ship_move_counter = 16'd0;

    always @(posedge clk) begin
        if (!not_reset) begin
            ship_x            <= SHIP_X_INIT;
            ship_move_counter <= 16'd0;
        end else if (life_lost_pending) begin
            ship_x            <= SHIP_X_INIT;
            ship_move_counter <= 16'd0;
        end else if ((state == S_PLAY) && move_tick) begin
            if (ship_move_counter == SHIP_MOVE_DIVIDER - 1) begin
                ship_move_counter <= 16'd0;
                if (nes_right && (ship_x + SHIP_STEP <= SHIP_X_MAX))
                    ship_x <= ship_x + SHIP_STEP;
                else if (nes_left && (ship_x >= SHIP_X_MIN + SHIP_STEP))
                    ship_x <= ship_x - SHIP_STEP;
            end else begin
                ship_move_counter <= ship_move_counter + 16'd1;
            end
        end
    end

    //----------------------------------------------------------------
    // Everything else: the game FSM itself (title wait, play, game over /
    // won), shoot edge detect + player bullet flight/collision, the rigid
    // formation's randomised descent/sideways drift (EASY / MEDIUM only --
    // HARD aliens move in gen_alien above), alien return fire, the paper's
    // restart_next/level_next/score_next logic (generalised to
    // TOTAL_ALIENS aliens), and the lives / game-over / game-won latches.
    //----------------------------------------------------------------
    reg hit;
    reg life_lost;
    reg touch;             // an alien has reached the ship's row
    integer k;
    integer fire_idx;
    integer fire_idx_b;
    integer cx, cy;

    always @(posedge clk) begin
        if (!not_reset) begin
            state                <= S_TITLE;
            diff                 <= 2'd0;
            nes_a                <= 1'b0;
            nes_b                <= 1'b0;
            bullet_active        <= 1'b0;
            bullet_x             <= 10'd0;
            bullet_y             <= 10'd0;
            defeated             <= {TOTAL_ALIENS{1'b0}};
            destruction          <= 1'b0;
            flip_counter         <= 1'b0;
            score_reg            <= 8'd0;
            level_reg            <= 2'd0;
            lives_reg            <= 2'd3;
            restart_next         <= 1'b0;
            descent_offset       <= 10'd0;
            descend_counter      <= 16'd50;
            x_offset             <= MAX_SWEEP[8:0];
            move_dir_right       <= 1'b1;
            horiz_counter        <= 16'd40;
            alien_bullet_active  <= 1'b0;
            alien_bullet_x       <= 10'd0;
            alien_bullet_y       <= 10'd0;
            alien_fire_counter   <= 16'd300;
            alien_bullet_b_active <= 1'b0;
            alien_bullet_b_x     <= 10'd0;
            alien_bullet_b_y     <= 10'd0;
            alien_fire_counter_b <= 16'd150;
            life_lost_pending    <= 1'b0;
        end else if (state == S_TITLE) begin
            //--------------------------------------------------------
            // TITLE: nothing about the game itself moves. Keep sampling the
            // mode switches (what they read at the instant a key is pressed
            // is what gets latched into `diff`), keep the three random
            // countdowns pre-loaded from the live mode, and wait for ANY of
            // the three game keys. On the start press, nes_a/nes_b are
            // preset to 1 so that if the key that started the game is the
            // shoot key it is NOT also seen as a fresh rising edge (i.e. no
            // free bullet).
            //--------------------------------------------------------
            diff               <= mode_n;
            acol               <= lfsr2[TOTAL_ALIENS-1:0] ^ lfsr[31 -: TOTAL_ALIENS];
            descend_counter    <= desc_delay(mode_n[0], lfsr);
            horiz_counter      <= horiz_delay(mode_n[0], lfsr);
            alien_fire_counter <= fire_delay(mode_n, lfsr);
            alien_fire_counter_b <= fire_delay(mode_n, lfsr2);
            if (any_key) begin
                state <= S_PLAY;
                nes_a <= 1'b1;
                nes_b <= 1'b1;
            end
        end else if (state != S_PLAY) begin
            // OVER or WON: freeze the whole game in place. The "GAME OVER" /
            // "GAME WON" text drawn in the pixel-colour mux below is static,
            // so there is nothing left to update here. Only reset (KEY[0])
            // leaves these states -- back to the title screen.
        end else begin
            hit               = 1'b0;   // blocking: resolved combinationally within this edge
            life_lost         = 1'b0;
            life_lost_pending <= 1'b0;  // default: 1-cycle pulse, only set below if a life is actually lost

            nes_b <= nes_a;
            nes_a <= shoot;

            //--------------------------------------------------------
            // Player bullet: launch on the rising edge of `shoot`
            // ("when nes_a and nes_b signal gets high the shoot signal
            // becomes 1"), then fly upward, checking every live alien's
            // CURRENT (moving) box every tick while in flight.
            //--------------------------------------------------------
            if (nes_a && !nes_b && !bullet_active) begin
                bullet_active <= 1'b1;
                bullet_x <= ship_x + (SHIP_W / 2) - (BULLET_W / 2);
                bullet_y <= SHIP_Y - 1;
            end else if (move_tick && bullet_active) begin
                for (k = 0; k < TOTAL_ALIENS; k = k + 1) begin
                    cx = apx_flat[10*k +: 10];
                    cy = apy_flat[10*k +: 10];
                    if (!hit && alive[k] &&
                        (bullet_x + BULLET_W >= cx) &&
                        (bullet_x <= cx + ALIEN_W) &&
                        (bullet_y >= cy) &&
                        (bullet_y <= cy + ALIEN_H + BULLET_H)) begin
                        defeated[k] <= 1'b1;
                        hit = 1'b1;
                    end
                end

                if (hit)
                    bullet_active <= 1'b0;                          // consumed by a hit
                else if (bullet_y <= top_y)
                    bullet_active <= 1'b0;                          // flew past every alien, missed
                else
                    bullet_y <= bullet_y - BULLET_SPEED[9:0];       // keep travelling up
            end

            destruction <= hit;

            // score_next <= score+2 when destruction='1' else score;
            if (hit)
                score_reg <= score_reg + 8'd2;

            //--------------------------------------------------------
            // Rigid-formation descent (EASY / MEDIUM, RANDOM): when the
            // countdown reaches 0, drop the whole formation by a random
            // 1-3 px and reload the countdown with a fresh random wait.
            //--------------------------------------------------------
            if (move_tick && !indep) begin
                if (descend_counter == 16'd0) begin
                    descend_counter <= desc_delay(med, lfsr);
                    descent_offset  <= descent_offset + desc_step(lfsr[7:6]);
                end else begin
                    descend_counter <= descend_counter - 16'd1;
                end
            end

            //--------------------------------------------------------
            // Rigid-formation sideways drift (EASY / MEDIUM, RANDOM): when
            // the countdown reaches 0, move 1 px in the current direction
            // -- unless this is a direction reversal (forced at
            // +-MAX_SWEEP, and also chosen at random 1 time in 8) -- then
            // reload with a fresh random wait.
            //--------------------------------------------------------
            if (move_tick && !indep) begin
                if (horiz_counter == 16'd0) begin
                    horiz_counter <= horiz_delay(med, lfsr);
                    if (move_dir_right) begin
                        if (x_offset >= (2 * MAX_SWEEP))
                            move_dir_right <= 1'b0;                  // hit the right limit: bounce
                        else if ((lfsr[15:13] == 3'd0) && (lfsr[20:16] == 5'd0))
                            move_dir_right <= 1'b0;                  // random reversal (1 in 256)
                        else
                            x_offset <= x_offset + 9'd1;
                    end else begin
                        if (x_offset == 9'd0)
                            move_dir_right <= 1'b1;                  // hit the left limit: bounce
                        else if ((lfsr[15:13] == 3'd0) && (lfsr[20:16] == 5'd0))
                            move_dir_right <= 1'b1;                  // random reversal (1 in 256)
                        else
                            x_offset <= x_offset - 9'd1;
                    end
                end else begin
                    horiz_counter <= horiz_counter - 16'd1;
                end
            end

            //--------------------------------------------------------
            // Alien return fire: when the countdown reaches 0, a random
            // alien tries to fire. If a bullet is already in the air, the
            // attempt is dropped and a fresh random wait starts; if the
            // alien picked is not alive (already shot, or in HARD mode not
            // spawned yet), the countdown is set to 0 so a new alien is
            // picked on the very next tick (so the shot rate doesn't
            // collapse as the aliens thin out). The bullet leaves from the
            // picked alien's CURRENT position.
            //--------------------------------------------------------
            if (move_tick && (ALIEN_FIRE_ENABLE != 0)) begin
                if (alien_fire_counter == 16'd0) begin
                    alien_fire_counter <= fire_delay(diff, lfsr);
                    if (!alien_bullet_active) begin
                        fire_idx = lfsr[31:24] % TOTAL_ALIENS;
                        if (!alive[fire_idx]) begin
                            alien_fire_counter <= 16'd0;   // dead / absent pick: try again next tick
                        end else begin
                            alien_bullet_active <= 1'b1;
                            alien_bullet_x <= apx_flat[10*fire_idx +: 10] + (ALIEN_W / 2) - (BULLET_W / 2);
                            alien_bullet_y <= apy_flat[10*fire_idx +: 10] + ALIEN_H;
                        end
                    end
                end else begin
                    alien_fire_counter <= alien_fire_counter - 16'd1;
                end
            end

            //--------------------------------------------------------
            // Second shooter (B): exactly the same rule as above, but with its
            // own countdown, its own bullet and its own random pick (from lfsr2),
            // so it neither waits for nor depends on shooter A. Both may even pick
            // the same alien; otherwise two different aliens fire at once.
            //--------------------------------------------------------
            if (move_tick && (ALIEN_FIRE_ENABLE != 0)) begin
                if (alien_fire_counter_b == 16'd0) begin
                    alien_fire_counter_b <= fire_delay(diff, lfsr2);
                    if (!alien_bullet_b_active) begin
                        fire_idx_b = lfsr2[31:24] % TOTAL_ALIENS;
                        if (!alive[fire_idx_b]) begin
                            alien_fire_counter_b <= 16'd0;   // dead / absent pick: try again next tick
                        end else begin
                            alien_bullet_b_active <= 1'b1;
                            alien_bullet_b_x <= apx_flat[10*fire_idx_b +: 10] + (ALIEN_W / 2) - (BULLET_W / 2);
                            alien_bullet_b_y <= apy_flat[10*fire_idx_b +: 10] + ALIEN_H;
                        end
                    end
                end else begin
                    alien_fire_counter_b <= alien_fire_counter_b - 16'd1;
                end
            end

            //--------------------------------------------------------
            // Alien bullet flight + collision with the ship.
            //--------------------------------------------------------
            if (alien_bullet_active && move_tick) begin
                if ((alien_bullet_x + BULLET_W >= ship_x) && (alien_bullet_x <= ship_x + SHIP_W) &&
                    (alien_bullet_y + BULLET_H >= SHIP_Y) && (alien_bullet_y <= SHIP_Y + SHIP_H)) begin
                    alien_bullet_active <= 1'b0;
                    life_lost = 1'b1;
                end else if (alien_bullet_y + BULLET_H >= FLOOR_Y) begin
                    alien_bullet_active <= 1'b0;   // missed: gone just before the bottom frame
                end else begin
                    alien_bullet_y <= alien_bullet_y + abullet_speed;
                end
            end

            // Shooter B's bullet: same flight + ship collision (one life lost per
            // hit; if both bullets hit on the same tick that costs one life).
            if (alien_bullet_b_active && move_tick) begin
                if ((alien_bullet_b_x + BULLET_W >= ship_x) && (alien_bullet_b_x <= ship_x + SHIP_W) &&
                    (alien_bullet_b_y + BULLET_H >= SHIP_Y) && (alien_bullet_b_y <= SHIP_Y + SHIP_H)) begin
                    alien_bullet_b_active <= 1'b0;
                    life_lost = 1'b1;
                end else if (alien_bullet_b_y + BULLET_H >= FLOOR_Y) begin
                    alien_bullet_b_active <= 1'b0;
                end else begin
                    alien_bullet_b_y <= alien_bullet_b_y + abullet_speed;
                end
            end

            // restart_next <= '1' when all TOTAL_ALIENS defeated else '0';
            // (paper: defeated1='1' and defeated2='1' and defeated3='1')
            restart_next <= &defeated;
            flip_counter <= ~flip_counter;

            // level_next <= level+1 when counter(0)='0' and all defeated
            // else level. Clearing every alien now ENDS the game: the FSM
            // goes to WON (the "GAME WON" screen) instead of respawning.
            if (!flip_counter && &defeated) begin
                level_reg <= level_reg + 2'd1;
                state     <= S_WON;
            end

            // An alien bullet hit the ship: costs a life. Lives count
            // 3 -> 2 -> 1; a hit while on the last life (lives == 1) means
            // lives would reach 0 = dead, so the FSM goes to OVER and lives
            // is pinned at 0. Otherwise the ship recentres and any bullets
            // in flight clear; aliens are left exactly where they were.
            if (life_lost) begin
                if (lives_reg <= 2'd1) begin
                    lives_reg <= 2'd0;
                    state     <= S_OVER;
                end else begin
                    lives_reg           <= lives_reg - 2'd1;
                    life_lost_pending   <= 1'b1;
                    bullet_active       <= 1'b0;
                    alien_bullet_active <= 1'b0;
                    alien_bullet_b_active <= 1'b0;
                end
            end

            // ANY live alien that has come down to the ship's row (the
            // bottom of the play area) is game over immediately, however
            // many lives are left. Placed LAST so it wins over everything
            // above that lands on the same cycle.
            touch = 1'b0;
            for (k = 0; k < TOTAL_ALIENS; k = k + 1) begin
                cy = apy_flat[10*k +: 10];
                if (alive[k] && (cy + ALIEN_H >= SHIP_Y))
                    touch = 1'b1;
            end
            if (touch) begin
                lives_reg <= 2'd0;
                state     <= S_OVER;
            end
        end
    end

    //----------------------------------------------------------------
    // On-screen text: a small 5x7 block font (digits 0-9 plus the
    // letters needed for the HUD, the "GAME OVER" message and the title
    // screen), scaled up into solid blocks. Not in the paper, which has no
    // on-screen text at all -- score/level there are debug-only VHDL
    // signals with no readout.
    //----------------------------------------------------------------
    localparam FONT_W = 5;
    localparam FONT_H = 7;

    localparam [4:0] CH_0  = 5'd0;
    localparam [4:0] CH_1  = 5'd1;
    localparam [4:0] CH_2  = 5'd2;
    localparam [4:0] CH_3  = 5'd3;
    localparam [4:0] CH_4  = 5'd4;
    localparam [4:0] CH_5  = 5'd5;
    localparam [4:0] CH_6  = 5'd6;
    localparam [4:0] CH_7  = 5'd7;
    localparam [4:0] CH_8  = 5'd8;
    localparam [4:0] CH_9  = 5'd9;
    localparam [4:0] CH_SP = 5'd10;
    localparam [4:0] CH_S  = 5'd11;
    localparam [4:0] CH_C  = 5'd12;
    localparam [4:0] CH_O  = 5'd13;
    localparam [4:0] CH_R  = 5'd14;
    localparam [4:0] CH_E  = 5'd15;
    localparam [4:0] CH_L  = 5'd16;
    localparam [4:0] CH_I  = 5'd17;
    localparam [4:0] CH_V  = 5'd18;
    localparam [4:0] CH_G  = 5'd19;
    localparam [4:0] CH_A  = 5'd20;
    localparam [4:0] CH_M  = 5'd21;
    localparam [4:0] CH_P  = 5'd22;
    localparam [4:0] CH_N  = 5'd23;
    localparam [4:0] CH_D  = 5'd24;
    localparam [4:0] CH_Y  = 5'd25;
    localparam [4:0] CH_K  = 5'd26;
    localparam [4:0] CH_T  = 5'd27;
    localparam [4:0] CH_H  = 5'd28;
    localparam [4:0] CH_U  = 5'd29;
    localparam [4:0] CH_W  = 5'd30;

    // Row `row` (0 = top) of character `ch`, 5 bits, MSB = leftmost pixel,
    // 1 = lit. Each glyph is packed as 7 rows of 5 bits (35 bits total);
    // any character not needed by the HUD/message strings below falls
    // through to the default (blank), same as CH_SP.
    function [FONT_W-1:0] font_row;
        input [4:0] ch;
        input [2:0] row;
        reg [34:0] glyph;
        begin
            case (ch)
                CH_0: glyph = 35'b01110_10001_10011_10101_11001_10001_01110;
                CH_1: glyph = 35'b00100_01100_00100_00100_00100_00100_01110;
                CH_2: glyph = 35'b01110_10001_00001_00010_00100_01000_11111;
                CH_3: glyph = 35'b11111_00010_00100_00010_00001_10001_01110;
                CH_4: glyph = 35'b00010_00110_01010_10010_11111_00010_00010;
                CH_5: glyph = 35'b11111_10000_11110_00001_00001_10001_01110;
                CH_6: glyph = 35'b00110_01000_10000_11110_10001_10001_01110;
                CH_7: glyph = 35'b11111_00001_00010_00100_01000_01000_01000;
                CH_8: glyph = 35'b01110_10001_10001_01110_10001_10001_01110;
                CH_9: glyph = 35'b01110_10001_10001_01111_00001_00010_01100;
                CH_S: glyph = 35'b01111_10000_10000_01110_00001_00001_11110;
                CH_C: glyph = 35'b01111_10000_10000_10000_10000_10000_01111;
                CH_O: glyph = 35'b01110_10001_10001_10001_10001_10001_01110;
                CH_R: glyph = 35'b11110_10001_10001_11110_10100_10010_10001;
                CH_E: glyph = 35'b11111_10000_10000_11110_10000_10000_11111;
                CH_L: glyph = 35'b10000_10000_10000_10000_10000_10000_11111;
                CH_I: glyph = 35'b01110_00100_00100_00100_00100_00100_01110;
                CH_V: glyph = 35'b10001_10001_10001_10001_10001_01010_00100;
                CH_G: glyph = 35'b01111_10000_10000_10011_10001_10001_01111;
                CH_A: glyph = 35'b01110_10001_10001_11111_10001_10001_10001;
                CH_M: glyph = 35'b10001_11011_10101_10101_10001_10001_10001;
                CH_P: glyph = 35'b11110_10001_10001_11110_10000_10000_10000;
                CH_N: glyph = 35'b10001_11001_10101_10011_10001_10001_10001;
                CH_D: glyph = 35'b11110_10001_10001_10001_10001_10001_11110;
                CH_Y: glyph = 35'b10001_10001_01010_00100_00100_00100_00100;
                CH_K: glyph = 35'b10001_10010_10100_11000_10100_10010_10001;
                CH_T: glyph = 35'b11111_00100_00100_00100_00100_00100_00100;
                CH_H: glyph = 35'b10001_10001_10001_11111_10001_10001_10001;
                CH_U: glyph = 35'b10001_10001_10001_10001_10001_10001_01110;
                CH_W: glyph = 35'b10001_10001_10001_10101_10101_11011_10001;
                default: glyph = 35'b0;   // CH_SP (and anything else) -> blank
            endcase
            font_row = glyph[34 - row*5 -: 5];
        end
    endfunction

    // Title-screen strings, one character code per position.
    //   "SPACE INVADERS"          (14 chars)
    function [4:0] title_char;
        input integer i;
        begin
            case (i)
                0:  title_char = CH_S;
                1:  title_char = CH_P;
                2:  title_char = CH_A;
                3:  title_char = CH_C;
                4:  title_char = CH_E;
                5:  title_char = CH_SP;
                6:  title_char = CH_I;
                7:  title_char = CH_N;
                8:  title_char = CH_V;
                9:  title_char = CH_A;
                10: title_char = CH_D;
                11: title_char = CH_E;
                12: title_char = CH_R;
                13: title_char = CH_S;
                default: title_char = CH_SP;
            endcase
        end
    endfunction

    //   "PRESS ANY KEY TO START"  (22 chars)
    function [4:0] press_char;
        input integer i;
        begin
            case (i)
                0:  press_char = CH_P;
                1:  press_char = CH_R;
                2:  press_char = CH_E;
                3:  press_char = CH_S;
                4:  press_char = CH_S;
                5:  press_char = CH_SP;
                6:  press_char = CH_A;
                7:  press_char = CH_N;
                8:  press_char = CH_Y;
                9:  press_char = CH_SP;
                10: press_char = CH_K;
                11: press_char = CH_E;
                12: press_char = CH_Y;
                13: press_char = CH_SP;
                14: press_char = CH_T;
                15: press_char = CH_O;
                16: press_char = CH_SP;
                17: press_char = CH_S;
                18: press_char = CH_T;
                19: press_char = CH_A;
                20: press_char = CH_R;
                21: press_char = CH_T;
                default: press_char = CH_SP;
            endcase
        end
    endfunction

    //   "MODE EASY" / "MODE MEDIUM" / "MODE HARD". Laid out in an 11-character
    //   field: MEDIUM fills it, the 9-character names are centred in it.
    function [4:0] mode_char;
        input [1:0]  m;                    // 0 EASY, 1 MEDIUM, 2 HARD
        input integer i;
        integer j;
        begin
            j = (m == 2'd1) ? i : (i - 1);
            case (j)
                0: mode_char = CH_M;
                1: mode_char = CH_O;
                2: mode_char = CH_D;
                3: mode_char = CH_E;
                4: mode_char = CH_SP;
                5: mode_char = (m == 2'd1) ? CH_M : ((m == 2'd2) ? CH_H : CH_E);
                6: mode_char = (m == 2'd1) ? CH_E : CH_A;
                7: mode_char = (m == 2'd1) ? CH_D : ((m == 2'd2) ? CH_R : CH_S);
                8: mode_char = (m == 2'd1) ? CH_I : ((m == 2'd2) ? CH_D : CH_Y);
                9: mode_char = (m == 2'd1) ? CH_U : CH_SP;
                10: mode_char = (m == 2'd1) ? CH_M : CH_SP;
                default: mode_char = CH_SP;
            endcase
        end
    endfunction

    // 8-entry palette for the title letters (fixed per letter position; no red).
    function [2:0] rainbow;
        input [2:0] i;
        begin
            case (i)
                3'd0:    rainbow = COLOR_YELLOW;
                3'd1:    rainbow = COLOR_GREEN;
                3'd2:    rainbow = COLOR_CYAN;
                3'd3:    rainbow = COLOR_MAGENTA;
                3'd4:    rainbow = COLOR_WHITE;
                3'd5:    rainbow = COLOR_YELLOW;
                3'd6:    rainbow = COLOR_GREEN;
                default: rainbow = COLOR_CYAN;
            endcase
        end
    endfunction

    // score_reg is binary; split it into decimal digits combinationally
    // (constant divide/mod -- cheap for an 8-bit value: synthesises to a
    // small block of compare/subtract logic, not a real run-time divider)
    // purely so the on-screen HUD reads in normal base-10, instead of the
    // hex digits shown on the board's 7-segment displays.
    wire [3:0] score_d2 = score_reg / 8'd100;
    wire [3:0] score_d1 = (score_reg / 8'd10) % 8'd10;
    wire [3:0] score_d0 = score_reg % 8'd10;

    //----------------------------------------------------------------
    // HUD: "SCORE nnn" / "LIVES n" in the top-right corner. Not in the
    // paper.
    //----------------------------------------------------------------
    localparam HUD_SCALE    = 2;                      // font pixel -> 2x2 screen pixels
    localparam HUD_CHAR_W   = FONT_W * HUD_SCALE;      // 10
    localparam HUD_CHAR_H   = FONT_H * HUD_SCALE;      // 14
    localparam HUD_PITCH    = HUD_CHAR_W + HUD_SCALE;  // 12 (1 font-px gap between chars)
    localparam HUD_CHARS    = 9;                       // "SCORE" + space + 3 digits
    localparam HUD_MARGIN_R = 20;
    localparam HUD_MARGIN_T = 16;
    localparam HUD_LINE_GAP = 6;
    localparam HUD_X0       = SCREEN_WIDTH - HUD_MARGIN_R - HUD_CHARS*HUD_PITCH;
    localparam HUD_Y0       = HUD_MARGIN_T;
    localparam HUD_Y1       = HUD_Y0 + HUD_CHAR_H + HUD_LINE_GAP;

    //----------------------------------------------------------------
    // "GAME OVER" (magenta) / "GAME WON" (green) message: centred, static (no
    // flashing), replaces the whole screen once the FSM is in OVER / WON.
    //----------------------------------------------------------------
    localparam GO_SCALE  = 6;
    localparam GO_CHAR_W = FONT_W * GO_SCALE;          // 30
    localparam GO_CHAR_H = FONT_H * GO_SCALE;          // 42
    localparam GO_PITCH  = GO_CHAR_W + GO_SCALE;       // 36
    localparam GO_CHARS  = 9;                          // "GAME OVER" incl. the space
    localparam WN_CHARS  = 8;                          // "GAME WON"
    localparam GO_X0     = (SCREEN_WIDTH  - GO_CHARS*GO_PITCH) / 2;
    localparam WN_X0     = (SCREEN_WIDTH  - WN_CHARS*GO_PITCH) / 2;
    localparam GO_Y0     = (SCREEN_HEIGHT - GO_CHAR_H) / 2;

    //----------------------------------------------------------------
    // TITLE screen layout (top to bottom). Everything is STATIC -- colourful
    // but nothing moves, blinks or cycles; the only thing that ever changes
    // is the "MODE ..." line, and only when the mode switches are flipped.
    //   y   8..11   border (fixed diagonal magenta/yellow stripes)
    //   y  96..137  "SPACE INVADERS", 6x scale, one fixed colour per letter
    //   y 152..155  under-line (fixed white/blue 32 px segments)
    //   y 200..217  a row of 9 aliens (2x scale), alternating magenta / green
    //   y 290..310  "PRESS ANY KEY TO START", 3x scale, yellow
    //   y 330..350  "MODE EASY" (green) / "MODE MEDIUM" (yellow) /
    //               "MODE HARD" (magenta), live from the mode switches
    //   y 390..435  decorative ship (2x) with a still bullet above its nose
    //   (+ a fixed starfield on the black background)
    //----------------------------------------------------------------
    localparam TT_SCALE  = 6;
    localparam TT_CHAR_W = FONT_W * TT_SCALE;          // 30
    localparam TT_CHAR_H = FONT_H * TT_SCALE;          // 42
    localparam TT_PITCH  = TT_CHAR_W + TT_SCALE;       // 36
    localparam TT_CHARS  = 14;
    localparam TT_X0     = (SCREEN_WIDTH - TT_CHARS*TT_PITCH) / 2;   // 68
    localparam TT_Y0     = 96;
    localparam BAR_Y0    = 152;

    localparam PR_SCALE  = 3;
    localparam PR_CHAR_W = FONT_W * PR_SCALE;          // 15
    localparam PR_CHAR_H = FONT_H * PR_SCALE;          // 21
    localparam PR_PITCH  = PR_CHAR_W + PR_SCALE;       // 18
    localparam PR_CHARS  = 22;
    localparam PR_X0     = (SCREEN_WIDTH - PR_CHARS*PR_PITCH) / 2;   // 122
    localparam PR_Y0     = 290;

    localparam MD_CHARS  = 11;
    localparam MD_X0     = (SCREEN_WIDTH - MD_CHARS*PR_PITCH) / 2;   // 221
    localparam MD_Y0     = 330;

    localparam PAR_Y0    = 200;                        // alien row (2x sprites, 9 of them from x=48)

    localparam DS_X0     = 300;                        // decorative ship, 2x scale (40 x 16)
    localparam DS_Y0     = 420;

    //----------------------------------------------------------------
    // Pixel colour mux: background (the title screen's black starfield + frame), aliens, ship, bullets, HUD text
    // (combinational); replaced by the title screen while the FSM is in
    // TITLE and by the static "GAME OVER" / "GAME WON" message once it is
    // in OVER / WON.
    //----------------------------------------------------------------
    reg alien_hit, ship_hit, bullet_hit, alien_bullet_hit, alien_bullet_b_hit;
    reg [2:0] alien_rgb;               // colour of the alien under this pixel
    integer m;
    integer ax, ay;

    // ModelSim/Questa's vlog rejects bit-selecting a function call's return
    // value directly (e.g. star_row(...)[i]) -- "Illegal bit-select
    // expression". Capture the function result in a reg first, then index
    // that reg. Same workaround applies to font_row(...) below.
    reg [STAR_COLS-1:0] alien_bits;
    reg [SHIP_COLS-1:0] ship_bits;
    reg [FONT_W-1:0]    font_bits;

    // HUD text-lookup working variables
    reg       hud_hit;
    integer   hud_char_i;
    integer   hud_sub_x, hud_sub_y;
    reg [4:0] hud_ch;

    // "GAME OVER" / "GAME WON" text-lookup working variables
    reg       go_hit;
    integer   go_char_i;
    integer   go_sub_x, go_sub_y;
    reg [4:0] go_ch;
    reg [9:0] msg_x0;
    integer   msg_chars;

    // Title-screen working variables
    reg       tt_hit;                 // "SPACE INVADERS"
    integer   tt_char_i, tt_sub_x, tt_sub_y;
    reg [4:0] tt_ch;
    reg [2:0] tt_ci;                  // colour index of the letter under this pixel
    reg       pr_hit;                 // "PRESS ANY KEY TO START"
    integer   pr_char_i, pr_sub_x, pr_sub_y;
    reg [4:0] pr_ch;
    reg       md_hit;                 // "MODE EASY/MEDIUM/HARD"
    integer   md_char_i, md_sub_x, md_sub_y;
    reg [4:0] md_ch;
    reg       par_hit;                // alien row
    reg [9:0] par_sub;
    reg [STAR_COLS-1:0] par_bits;
    reg       dship_hit;              // decorative ship
    reg [SHIP_COLS-1:0] dship_bits;
    reg       dbul_hit;               // decorative bullet
    reg       bar_hit;                // under-line
    reg       frm_hit;                // border
    reg [4:0] frm_ph;
    reg       star_hit;               // stars
    reg [6:0] sh;
    reg [2:0] title_rgb;

    always @* begin
        ship_bits = ship_row((px_y - SHIP_Y) / SPR_SCALE);

        // Defaults for every working variable, so none of them is left
        // holding a value (i.e. none infers a latch) on the paths that skip it.
        alien_bits = {STAR_COLS{1'b0}};
        font_bits  = {FONT_W{1'b0}};
        ax = 0;  ay = 0;
        hud_char_i = 0;  hud_sub_x = 0;  hud_sub_y = 0;
        go_char_i  = 0;  go_sub_x  = 0;  go_sub_y  = 0;
        tt_char_i  = 0;  tt_sub_x  = 0;  tt_sub_y  = 0;
        pr_char_i  = 0;  pr_sub_x  = 0;  pr_sub_y  = 0;
        md_char_i  = 0;  md_sub_x  = 0;  md_sub_y  = 0;


        alien_hit = 1'b0;
        alien_rgb = ALIEN_COLOR_A;
        for (m = 0; m < TOTAL_ALIENS; m = m + 1) begin
            if (!alien_hit && alive[m]) begin
                ax = apx_flat[10*m +: 10];
                ay = apy_flat[10*m +: 10];
                if ((px_x >= ax) && (px_x < ax + ALIEN_W) &&
                    (px_y >= ay) && (px_y < ay + ALIEN_H)) begin
                    alien_bits = star_row((px_y - ay) / SPR_SCALE);
                    if (alien_bits[STAR_COLS-1 - (px_x - ax) / SPR_SCALE]) begin
                        alien_hit = 1'b1;
                        // two colour sets, assigned randomly per alien (acol)
                        alien_rgb = acol[m] ? ALIEN_COLOR_B : ALIEN_COLOR_A;
                    end
                end
            end
        end

        ship_hit = (px_x >= ship_x) && (px_x < ship_x + SHIP_W) &&
                   (px_y >= SHIP_Y) && (px_y < SHIP_Y + SHIP_H) &&
                   ship_bits[SHIP_COLS-1 - (px_x - ship_x) / SPR_SCALE];

        bullet_hit = bullet_active &&
                     (px_x >= bullet_x) && (px_x < bullet_x + BULLET_W) &&
                     (px_y >= bullet_y - BULLET_H) && (px_y <= bullet_y);

        alien_bullet_hit = alien_bullet_active &&
                            (px_x >= alien_bullet_x) && (px_x < alien_bullet_x + BULLET_W) &&
                            (px_y >= alien_bullet_y) && (px_y < alien_bullet_y + BULLET_H);

        alien_bullet_b_hit = alien_bullet_b_active &&
                             (px_x >= alien_bullet_b_x) && (px_x < alien_bullet_b_x + BULLET_W) &&
                             (px_y >= alien_bullet_b_y) && (px_y < alien_bullet_b_y + BULLET_H);

        //----------------------------------------------------------
        // HUD ("SCORE nnn" line, "LIVES n" line): figure out which
        // character cell (if any) this pixel falls in, which glyph that
        // cell holds, then whether this pixel is one of that glyph's lit
        // pixels. hud_ch defaults to CH_SP (blank) so gap pixels and any
        // index past a short string just render as background.
        //----------------------------------------------------------
        hud_hit = 1'b0;
        hud_ch  = CH_SP;
        if ((px_x >= HUD_X0) && (px_x < HUD_X0 + HUD_CHARS*HUD_PITCH) &&
            (px_y >= HUD_Y0) && (px_y < HUD_Y0 + HUD_CHAR_H)) begin
            hud_char_i = (px_x - HUD_X0) / HUD_PITCH;
            hud_sub_x  = (px_x - HUD_X0) % HUD_PITCH;
            hud_sub_y  = px_y - HUD_Y0;
            if (hud_sub_x < HUD_CHAR_W) begin
                case (hud_char_i)
                    0: hud_ch = CH_S;
                    1: hud_ch = CH_C;
                    2: hud_ch = CH_O;
                    3: hud_ch = CH_R;
                    4: hud_ch = CH_E;
                    5: hud_ch = CH_SP;
                    6: hud_ch = CH_0 + score_d2;
                    7: hud_ch = CH_0 + score_d1;
                    8: hud_ch = CH_0 + score_d0;
                    default: hud_ch = CH_SP;
                endcase
                font_bits = font_row(hud_ch, hud_sub_y / HUD_SCALE);
                if (font_bits[FONT_W-1 - (hud_sub_x / HUD_SCALE)])
                    hud_hit = 1'b1;
            end
        end else if ((px_x >= HUD_X0) && (px_x < HUD_X0 + HUD_CHARS*HUD_PITCH) &&
                     (px_y >= HUD_Y1) && (px_y < HUD_Y1 + HUD_CHAR_H)) begin
            hud_char_i = (px_x - HUD_X0) / HUD_PITCH;
            hud_sub_x  = (px_x - HUD_X0) % HUD_PITCH;
            hud_sub_y  = px_y - HUD_Y1;
            if (hud_sub_x < HUD_CHAR_W) begin
                case (hud_char_i)
                    0: hud_ch = CH_L;
                    1: hud_ch = CH_I;
                    2: hud_ch = CH_V;
                    3: hud_ch = CH_E;
                    4: hud_ch = CH_S;
                    5: hud_ch = CH_SP;
                    6: hud_ch = CH_0 + lives_reg;
                    default: hud_ch = CH_SP;
                endcase
                font_bits = font_row(hud_ch, hud_sub_y / HUD_SCALE);
                if (font_bits[FONT_W-1 - (hud_sub_x / HUD_SCALE)])
                    hud_hit = 1'b1;
            end
        end

        //----------------------------------------------------------
        // "GAME OVER" (9 chars) / "GAME WON" (8 chars) message, same
        // technique, drawn much larger and centred. Only meaningful once
        // the FSM is in OVER / WON (see the priority chain below), but it's
        // cheap to compute unconditionally.
        //----------------------------------------------------------
        go_hit    = 1'b0;
        go_ch     = CH_SP;
        msg_x0    = game_won ? WN_X0 : GO_X0;
        msg_chars = game_won ? WN_CHARS : GO_CHARS;
        if ((px_x >= msg_x0) && (px_x < msg_x0 + msg_chars*GO_PITCH) &&
            (px_y >= GO_Y0) && (px_y < GO_Y0 + GO_CHAR_H)) begin
            go_char_i = (px_x - msg_x0) / GO_PITCH;
            go_sub_x  = (px_x - msg_x0) % GO_PITCH;
            go_sub_y  = px_y - GO_Y0;
            if (go_sub_x < GO_CHAR_W) begin
                case (go_char_i)
                    0: go_ch = CH_G;
                    1: go_ch = CH_A;
                    2: go_ch = CH_M;
                    3: go_ch = CH_E;
                    4: go_ch = CH_SP;
                    5: go_ch = game_won ? CH_W : CH_O;
                    6: go_ch = game_won ? CH_O : CH_V;
                    7: go_ch = game_won ? CH_N : CH_E;
                    8: go_ch = CH_R;
                    default: go_ch = CH_SP;
                endcase
                font_bits = font_row(go_ch, go_sub_y / GO_SCALE);
                if (font_bits[FONT_W-1 - (go_sub_x / GO_SCALE)])
                    go_hit = 1'b1;
            end
        end

        //----------------------------------------------------------
        // TITLE screen (all static). Same text technique as the HUD /
        // GAME OVER above: find the character cell this pixel is in, look up
        // its glyph, test the pixel's bit. Every region defaults to "not
        // hit" first so the block never infers a latch.
        //----------------------------------------------------------

        // "SPACE INVADERS" -- each letter keeps its own fixed colour
        tt_hit = 1'b0;
        tt_ch  = CH_SP;
        tt_ci  = 3'd0;
        if ((px_x >= TT_X0) && (px_x < TT_X0 + TT_CHARS*TT_PITCH) &&
            (px_y >= TT_Y0) && (px_y < TT_Y0 + TT_CHAR_H)) begin
            tt_char_i = (px_x - TT_X0) / TT_PITCH;
            tt_sub_x  = (px_x - TT_X0) % TT_PITCH;
            tt_sub_y  = px_y - TT_Y0;
            if (tt_sub_x < TT_CHAR_W) begin
                tt_ch = title_char(tt_char_i);
                tt_ci = tt_char_i[2:0];
                font_bits = font_row(tt_ch, tt_sub_y / TT_SCALE);
                if (font_bits[FONT_W-1 - (tt_sub_x / TT_SCALE)])
                    tt_hit = 1'b1;
            end
        end

        // "PRESS ANY KEY TO START" -- steady, no blinking
        pr_hit = 1'b0;
        pr_ch  = CH_SP;
        if ((px_x >= PR_X0) && (px_x < PR_X0 + PR_CHARS*PR_PITCH) &&
            (px_y >= PR_Y0) && (px_y < PR_Y0 + PR_CHAR_H)) begin
            pr_char_i = (px_x - PR_X0) / PR_PITCH;
            pr_sub_x  = (px_x - PR_X0) % PR_PITCH;
            pr_sub_y  = px_y - PR_Y0;
            if (pr_sub_x < PR_CHAR_W) begin
                pr_ch = press_char(pr_char_i);
                font_bits = font_row(pr_ch, pr_sub_y / PR_SCALE);
                if (font_bits[FONT_W-1 - (pr_sub_x / PR_SCALE)])
                    pr_hit = 1'b1;
            end
        end

        // "MODE EASY" / "MODE MEDIUM" / "MODE HARD" -- follows the mode
        // switches live (this is the only part of the title that can change)
        md_hit = 1'b0;
        md_ch  = CH_SP;
        if ((px_x >= MD_X0) && (px_x < MD_X0 + MD_CHARS*PR_PITCH) &&
            (px_y >= MD_Y0) && (px_y < MD_Y0 + PR_CHAR_H)) begin
            md_char_i = (px_x - MD_X0) / PR_PITCH;
            md_sub_x  = (px_x - MD_X0) % PR_PITCH;
            md_sub_y  = px_y - MD_Y0;
            if (md_sub_x < PR_CHAR_W) begin
                md_ch = mode_char(mode_n, md_char_i);
                font_bits = font_row(md_ch, md_sub_y / PR_SCALE);
                if (font_bits[FONT_W-1 - (md_sub_x / PR_SCALE)])
                    md_hit = 1'b1;
            end
        end

        // Alien row: the strip x = 48 .. 623 is cut into 64 px cells
        // (par_sub = px_x - 48); the alien sprite (drawn at 2x, so 32 px
        // wide) fills the left half of each cell, i.e. par_sub[5] == 0, and
        // par_sub[4:1] is the sprite column. Alternate cells (par_sub[6])
        // are magenta / green. 9 aliens, symmetric about the screen centre.
        par_hit  = 1'b0;
        par_bits = {STAR_COLS{1'b0}};
        par_sub  = px_x - 10'd48;
        if ((px_x >= 48) && (px_x < 624) &&
            (px_y >= PAR_Y0) && (px_y < PAR_Y0 + 2*STAR_ROWS)) begin
            par_bits = star_row((px_y - PAR_Y0) / 2);
            if (!par_sub[5] && par_bits[STAR_COLS-1 - par_sub[4:1]])
                par_hit = 1'b1;
        end

        // Decorative ship (the in-game ship sprite at 2x) ...
        dship_hit  = 1'b0;
        dship_bits = {SHIP_COLS{1'b0}};
        if ((px_x >= DS_X0) && (px_x < DS_X0 + 2*SHIP_COLS) &&
            (px_y >= DS_Y0) && (px_y < DS_Y0 + 2*SHIP_ROWS)) begin
            dship_bits = ship_row((px_y - DS_Y0) / 2);
            if (dship_bits[SHIP_COLS-1 - ((px_x - DS_X0) / 2)])
                dship_hit = 1'b1;
        end

        // ... and a still bullet just above its nose.
        dbul_hit = (px_x >= DS_X0 + SHIP_COLS - 2) && (px_x < DS_X0 + SHIP_COLS + 2) &&
                   (px_y >= DS_Y0 - 30) && (px_y < DS_Y0 - 14);

        // Under-line beneath the title: fixed 32 px white / blue segments.
        bar_hit = (px_x >= TT_X0) && (px_x < TT_X0 + TT_CHARS*TT_PITCH) &&
                  (px_y >= BAR_Y0) && (px_y < BAR_Y0 + 4);

        // Border: 4 px wide, inset 8 px from every edge, fixed diagonal
        // magenta / yellow stripes.
        frm_ph  = px_x[4:0] + px_y[4:0];
        frm_hit = ((px_x >= 8) && (px_x < 632) && (px_y >= 8) && (px_y < 472)) &&
                  ((px_x < 12) || (px_x >= 628) || (px_y < 12) || (px_y >= 468));

        // Starfield: the screen is cut into 8x8 cells; a cheap XOR hash of
        // the cell coordinates (sh) decides which cells hold a star and
        // where in the cell it sits. Fixed -- no twinkling.
        sh = px_x[9:3] ^ {px_y[6:3], px_y[8:6]} ^ {px_x[5:3], px_x[9:6]};
        star_hit = ((px_x[4:3] ^ px_y[4:3]) == 2'b11) && (sh[2:0] == 3'b101) &&
                   (px_x[2:0] == sh[5:3]) && (px_y[2:0] == {sh[6], sh[4:3]});

        // Title priority chain, front to back.
        if (tt_hit)         title_rgb = rainbow(tt_ci);
        else if (pr_hit)    title_rgb = COLOR_YELLOW;
        else if (md_hit)    title_rgb = mode_n[1] ? COLOR_MAGENTA : (mode_n[0] ? COLOR_YELLOW : COLOR_GREEN);
        else if (dbul_hit)  title_rgb = COLOR_YELLOW;
        else if (dship_hit) title_rgb = COLOR_WHITE;
        else if (par_hit)   title_rgb = par_sub[6] ? COLOR_GREEN : COLOR_MAGENTA;
        else if (bar_hit)   title_rgb = px_x[5] ? COLOR_WHITE : COLOR_BLUE;
        else if (frm_hit)   title_rgb = frm_ph[3] ? COLOR_YELLOW : COLOR_MAGENTA;
        else if (star_hit)  title_rgb = COLOR_WHITE;
        else                title_rgb = COLOR_BLACK;

        if (!video_on)
            rgb = COLOR_BLACK;                      // blanking interval
        else if (state == S_TITLE)
            rgb = title_rgb;                        // static title screen
        else if (game_over)
            rgb = go_hit ? COLOR_MAGENTA : COLOR_BLACK; // static "GAME OVER" message
        else if (game_won)
            rgb = go_hit ? COLOR_GREEN : COLOR_BLACK;  // static "GAME WON" message
        else if (alien_hit)
            rgb = alien_rgb;
        else if (ship_hit)
            rgb = COLOR_WHITE;
        else if (bullet_hit)
            rgb = BULLET_COLOR;
        else if (alien_bullet_hit || alien_bullet_b_hit)
            rgb = ALIEN_BULLET_COLOR;
        else if (hud_hit)
            rgb = COLOR_WHITE;
        else if (frm_hit)
            rgb = frm_ph[3] ? COLOR_YELLOW : COLOR_MAGENTA;   // same frame as the title screen
        else if (star_hit)
            rgb = COLOR_WHITE;                      // same starfield as the title screen
        else
            rgb = COLOR_BLACK;                      // same black sky as the title screen
    end

endmodule
