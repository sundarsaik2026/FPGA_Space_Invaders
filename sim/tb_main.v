//------------------------------------------------------------------------------
// tb_main.v
//
// Five testbenches in one file, all targeting graphics.v directly (the same
// block main.v wires together) so score/level/lives/destruction/game_over/
// game_won and the FSM `state` are directly visible. Run each separately:
//   vsim work.tb_main   vsim work.tb_touch   vsim work.tb_lives
//   vsim work.tb_modes  vsim work.tb_hard
//
//  1) tb_main: the gameplay test in EASY mode -- title screen (the FSM waits
//     in TITLE; any key starts the game without firing a stray bullet),
//     reset/movement, shoot edge-detect, collision, score increment, then
//     all ALIEN_ROWS x ALIEN_COLS = 21 aliens are shot (the formation drifts
//     randomly, so every shot is aimed from the formation's live x_offset,
//     with up to 3 re-aim rounds). Shooting the last alien must raise
//     `level` and put the FSM in WON ("GAME WON" screen), after which the
//     game is frozen (ship/score/bullets ignore the keys) and a reset
//     returns to the title. Alien return fire is disabled (ALIEN_FIRE_ENABLE
//     = 0) so the scripted aiming isn't disturbed by an alien bullet.
//
//  2) tb_touch: the "alien reaches the ship's row" rule. Nothing is shot and
//     nothing is fired at the ship, so all 3 lives are intact when the
//     descending formation reaches the ship's row -- which must still be
//     game over immediately, whatever the number of lives.
//
//  3) tb_lives: alien bullets vs the 3-life counter, with a stationary ship
//     and a short alien-fire wait. Lives may only step 3 -> 2 -> 1 -> 0 (one
//     per bullet hit); the only other way to reach 0 is an alien touching the
//     ship's row (a jump straight to 0 together with game_over).
//
//  4) tb_modes: EASY and MEDIUM instances side by side, fed the SAME clock and
//     (because the LFSR is free-running from the same initial value) the SAME
//     random bits, differing only in `mode`. Checks the FSM (stays in TITLE
//     until a key press, then PLAY), that the mode is latched at the start
//     press, and that MEDIUM's formation is really faster: >= 2x the descent
//     and >= 2.5x the sideways steps of EASY over the same 2000 move_ticks.
//
//  5) tb_hard: HARD mode (independent aliens). Checks that no alien is on
//     screen at the start and that they then ENTER one by one on the top
//     edge (y = BOX_Y0); that every present alien stays inside the play
//     rectangle on every clock; that the aliens do NOT move as a group (the
//     number of aliens that step sideways in one move_tick is almost never
//     "all of them"), that they end up at many different heights, that
//     shooting them works (score rises), and that the first alien to reach
//     the ship's row ends the game.
//
// The bounds/independence numbers in tb_hard were calibrated against a
// tick-level Python model of gen_alien using the real per-alien LFSRs.
//
// TEST_DIVISOR is shrunk to a small value purely to make ship/bullet
// movement tick fast enough to observe in a short simulation; synthesis
// uses the real default (500000, ~100 Hz at 50 MHz) in main.v.
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_main;

    localparam CLK_PERIOD   = 20;   // ns, 50 MHz
    localparam TEST_DIVISOR = 5;    // fast movement tick for simulation

    // Must mirror graphics.v's own localparams/parameters so this TB can
    // compute where each alien is and how far the ship needs to move.
    localparam SCREEN_WIDTH   = 640;
    localparam SHIP_COLS      = 40;   // ship width in pixels (20-col bitmap at 2x)
    localparam SHIP_STEP      = 5;
    localparam SHIP_X_INIT    = (SCREEN_WIDTH / 2) - (SHIP_COLS / 2);   // 300
    localparam STAR_COLS      = 32;   // alien width in pixels (16-col bitmap at 2x)
    localparam ALIEN_COLS     = 7;
    localparam ALIEN_SPACING  = 48;
    localparam ALIEN_X0       = (SCREEN_WIDTH - ((ALIEN_COLS - 1) * ALIEN_SPACING + STAR_COLS)) / 2; // 160
    localparam ALIEN_ROWS     = 3;
    localparam SHIP_MOVE_DIVIDER = 5;   // must match graphics.v's default (see U_GRAPHICS below)

    //==================================================================
    // 1) tb_main's own signals/instance: the gameplay test
    //==================================================================
    reg clk = 1'b0;
    reg not_reset = 1'b0;
    reg left = 1'b0, right = 1'b0, shoot = 1'b0;

    wire hsync, vsync, video_on, p_tick;
    wire [9:0] pixel_x, pixel_y;
    wire move_tick;
    wire [2:0] rgb;
    wire [7:0] score;
    wire [1:0] level;
    wire [1:0] lives;
    wire destruction;
    wire game_over;
    wire game_won;

    reg [7:0] prev_score;
    reg [1:0] prev_level;

    integer i, pass, round_i;
    integer ship_x_model;
    integer target, delta, ticks;
    integer waited;
    reg [9:0] sx_frozen;
    reg [7:0] sc_frozen;

    vga_controller U_VGA (
        .clk(clk), .not_reset(not_reset), .hsync(hsync), .vsync(vsync),
        .video_on(video_on), .p_tick(p_tick), .pixel_x(pixel_x), .pixel_y(pixel_y)
    );

    clk_divider #(.DIVISOR(TEST_DIVISOR)) U_CLKDIV (
        .clk(clk), .not_reset(not_reset), .tick(move_tick)
    );

    // ALIEN_FIRE_ENABLE = 0: aliens never shoot, keeping the scripted
    // aiming below undisturbed. Everything else uses graphics.v's real
    // synthesis defaults, in EASY mode (mode tied to 0).
    graphics #(
        .ALIEN_ROWS(ALIEN_ROWS), .ALIEN_FIRE_ENABLE(0), .SHIP_MOVE_DIVIDER(SHIP_MOVE_DIVIDER)
    ) U_GRAPHICS (
        .clk(clk), .not_reset(not_reset), .video_on(video_on),
        .px_x(pixel_x), .px_y(pixel_y), .move_tick(move_tick),
        .nes_left(left), .nes_right(right), .shoot(shoot),
        .mode(2'd0),
        .rgb(rgb), .score(score), .level(level), .lives(lives),
        .destruction_o(destruction), .game_over_o(game_over), .game_won_o(game_won)
    );

    // 50 MHz clock
    always #(CLK_PERIOD / 2) clk = ~clk;

    initial begin
        //------------------------------------------------------------
        // Test Case 1: reset, then release.
        //------------------------------------------------------------
        not_reset = 1'b0;
        left = 1'b0; right = 1'b0; shoot = 1'b0;
        #(CLK_PERIOD * 10);
        not_reset = 1'b1;
        #(CLK_PERIOD * 10);
        $display("Test Case 1: reset released.");

        //------------------------------------------------------------
        // Test Case 1b: TITLE screen. With no key pressed the FSM must
        // stay in TITLE (state 0) however long we wait, and nothing in the
        // game may move. Then a press of the SHOOT key must start the game
        // (state 1) WITHOUT also launching a bullet (the start press must
        // not double as a shot).
        //------------------------------------------------------------
        #(CLK_PERIOD * TEST_DIVISOR * 300);
        if (U_GRAPHICS.state == 2'd0 && U_GRAPHICS.ship_x == SHIP_X_INIT && score == 8'd0 && lives == 2'd3)
            $display("Test Case 1b PASS: still on the title screen after 300 move_ticks, nothing moved.");
        else
            $display("WARNING Test Case 1b: left the title screen without a key press, or game state changed (state=%0d).", U_GRAPHICS.state);

        shoot = 1'b1;
        #(CLK_PERIOD * 4);
        shoot = 1'b0;
        #(CLK_PERIOD * 10);
        if (U_GRAPHICS.state == 2'd1 && !U_GRAPHICS.bullet_active)
            $display("Test Case 1c PASS: key press started the game (state=PLAY), no stray bullet fired.");
        else
            $display("WARNING Test Case 1c: state=%0d bullet_active=%0d after the start press (expected PLAY and no bullet).",
                      U_GRAPHICS.state, U_GRAPHICS.bullet_active);

        ship_x_model = SHIP_X_INIT;
        prev_score   = score;
        prev_level   = level;

        //------------------------------------------------------------
        // Test Cases 2/3/4: sweep all ALIEN_COLS columns, ALIEN_ROWS
        // times. Each bullet meets whichever undefeated alien is closest
        // (the bottom row first), so pass 0 clears the bottom row, pass 1
        // the middle row, pass 2 the top row. The first shot fired below
        // is Test Case 2 (nes_a/nes_b edge -> bullet_active); every hit's
        // score bump is Test Case 3/4 (destruction -> +2).
        //------------------------------------------------------------
        for (pass = 0; pass < ALIEN_ROWS; pass = pass + 1) begin
            for (i = 0; i < ALIEN_COLS; i = i + 1) begin
                // Aim in up to 3 rounds, re-reading the DUT's own live
                // x_offset (via hierarchical reference into U_GRAPHICS)
                // each time: ship movement is divided down by
                // SHIP_MOVE_DIVIDER, so a big cross-screen move can take
                // long enough that the (randomly drifting) formation
                // moves noticeably during the move itself. The first round
                // gets close and the remaining rounds correct for whatever
                // the formation did meanwhile.
                for (round_i = 0; round_i < 3; round_i = round_i + 1) begin
                    target = ALIEN_X0 + i * ALIEN_SPACING + U_GRAPHICS.x_offset - U_GRAPHICS.MAX_SWEEP - 4;
                    delta  = target - ship_x_model;
                    ticks  = delta / SHIP_STEP;   // truncates toward zero; fine given the generous hit tolerance

                    if (ticks < 0) begin
                        left = 1'b1;
                        #(CLK_PERIOD * TEST_DIVISOR * SHIP_MOVE_DIVIDER * (-ticks));
                        left = 1'b0;
                        ship_x_model = ship_x_model + ticks * SHIP_STEP;
                    end else if (ticks > 0) begin
                        right = 1'b1;
                        #(CLK_PERIOD * TEST_DIVISOR * SHIP_MOVE_DIVIDER * ticks);
                        right = 1'b0;
                        ship_x_model = ship_x_model + ticks * SHIP_STEP;
                    end
                end
                #(CLK_PERIOD * 5);

                shoot = 1'b1;
                #(CLK_PERIOD);
                shoot = 1'b0;

                // wait for the bullet to fly from the ship up to whichever
                // row is currently closest and resolve
                #(CLK_PERIOD * TEST_DIVISOR * 150);

                $display("Pass %0d, col %0d/%0d: ship_x~=%0d, score=%0d, level=%0d",
                          pass, i, ALIEN_COLS - 1, ship_x_model, score, level);
            end
        end

        if (score == prev_score + ALIEN_ROWS * ALIEN_COLS * 2)
            $display("Test Case 3/4 PASS: all %0d aliens hit, score incremented correctly (%0d -> %0d)",
                      ALIEN_ROWS * ALIEN_COLS, prev_score, score);
        else
            $display("WARNING Test Case 3/4: expected score %0d, got %0d -- one or more shots likely missed (timing/alignment)",
                      prev_score + ALIEN_ROWS * ALIEN_COLS * 2, score);

        //------------------------------------------------------------
        // Test Case 5: all TOTAL_ALIENS aliens defeated -> level
        // increments.
        //------------------------------------------------------------
        if (level != prev_level)
            $display("Test Case 5 PASS: level advanced (%0d -> %0d)", prev_level, level);
        else
            $display("WARNING Test Case 5: level did not advance -- not all aliens were cleared together");

        //------------------------------------------------------------
        // Test Case 6: shooting the last alien ends the game with the WON
        // screen (state 3, game_won high, game_over low) -- no respawn.
        //------------------------------------------------------------
        if (U_GRAPHICS.state == 2'd3 && game_won && !game_over)
            $display("Test Case 6 PASS: all aliens shot -> GAME WON (state=WON, game_won=1, game_over=0).");
        else
            $display("WARNING Test Case 6: state=%0d game_won=%0d game_over=%0d after clearing every alien (expected WON).",
                      U_GRAPHICS.state, game_won, game_over);

        // Test Case 6b: the won game is frozen -- keys do nothing.
        sx_frozen = U_GRAPHICS.ship_x;
        sc_frozen = score;
        right = 1'b1; shoot = 1'b1;
        #(CLK_PERIOD * TEST_DIVISOR * SHIP_MOVE_DIVIDER * 20);
        right = 1'b0; shoot = 1'b0;
        #(CLK_PERIOD * 10);
        if (U_GRAPHICS.ship_x == sx_frozen && score == sc_frozen && !U_GRAPHICS.bullet_active && game_won)
            $display("Test Case 6b PASS: the won game is frozen (ship, score and bullet ignore the keys).");
        else
            $display("WARNING Test Case 6b: ship_x %0d->%0d score %0d->%0d bullet_active=%0d after the win.",
                      sx_frozen, U_GRAPHICS.ship_x, sc_frozen, score, U_GRAPHICS.bullet_active);

        // Test Case 6c: reset from the WON screen returns to the title.
        not_reset = 1'b0;
        #(CLK_PERIOD * 10);
        not_reset = 1'b1;
        #(CLK_PERIOD * 10);
        if (U_GRAPHICS.state == 2'd0 && !game_won && score == 8'd0 && lives == 2'd3)
            $display("Test Case 6c PASS: reset from GAME WON returns to the title screen with a clean game.");
        else
            $display("WARNING Test Case 6c: state=%0d game_won=%0d score=%0d lives=%0d after reset.", U_GRAPHICS.state, game_won, score, lives);

        $display("tb_main simulation complete.");
        $finish;
    end

endmodule


//==================================================================
// tb_lives: alien-return-fire / lives smoke test, in its own module
// so its very different (fast alien fire, stationary ship) setup doesn't
// affect tb_main at all. Run each testbench separately:
//   vsim work.tb_main (then tb_touch, tb_lives, tb_modes, tb_hard likewise)
//==================================================================
module tb_lives;

    localparam CLK_PERIOD   = 20;
    localparam TEST_DIVISOR = 5;

    reg clk = 1'b0;
    reg not_reset = 1'b0;
    reg start_key = 1'b0;

    wire hsync, vsync, video_on, p_tick;
    wire [9:0] pixel_x, pixel_y;
    wire move_tick;
    wire [2:0] rgb;
    wire [7:0] score;
    wire [1:0] level;
    wire [1:0] lives;
    wire destruction;
    wire game_over;

    integer waited;
    reg [1:0] prev_lives = 2'd3;
    reg       lives_ok   = 1'b1;

    vga_controller U_VGA (
        .clk(clk), .not_reset(not_reset), .hsync(hsync), .vsync(vsync),
        .video_on(video_on), .p_tick(p_tick), .pixel_x(pixel_x), .pixel_y(pixel_y)
    );

    clk_divider #(.DIVISOR(TEST_DIVISOR)) U_CLKDIV (
        .clk(clk), .not_reset(not_reset), .tick(move_tick)
    );

    // Short fire wait (EASY_FIRE_MIN = 1, so a shot every ~1..256 ticks)
    // so alien bullets come often; the ship is left stationary at its
    // reset (centre) position on purpose, directly under one of the alien
    // columns, so a fair share of the shots eventually land on it.
    graphics #(
        .ALIEN_ROWS(3), .EASY_FIRE_MIN(1)
    ) U_GRAPHICS (
        .clk(clk), .not_reset(not_reset), .video_on(video_on),
        .px_x(pixel_x), .px_y(pixel_y), .move_tick(move_tick),
        .nes_left(start_key), .nes_right(1'b0), .shoot(1'b0),
        .mode(2'd0),
        .rgb(rgb), .score(score), .level(level), .lives(lives),
        .destruction_o(destruction), .game_over_o(game_over), .game_won_o()
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    // Lives may only ever step 3 -> 2 -> 1 -> 0, one at a time -- except that an
    // alien touching the ship's row ends the game outright (lives jump to 0 on
    // the same edge game_over rises).
    always @(posedge clk) begin
        if (lives != prev_lives) begin
            $display("tb_lives: lives %0d -> %0d", prev_lives, lives);
            if (lives != prev_lives - 2'd1 && !game_over)
                lives_ok = 1'b0;
            prev_lives = lives;
        end
    end

    initial begin
        not_reset = 1'b0;
        #(CLK_PERIOD * 10);
        not_reset = 1'b1;
        #(CLK_PERIOD * 20);

        // Title screen -> press a key to start (left, held for less than
        // one move_tick so the ship doesn't get a chance to move).
        start_key = 1'b1;
        #(CLK_PERIOD * 4);
        start_key = 1'b0;
        $display("tb_lives: game started, ship left stationary at centre, waiting for lives to run out...");

        // Lives are lost to alien bullets at random times (and the game may
        // also end early if the formation reaches the ship's row first), so
        // poll in 1000-tick chunks and stop as soon as game_over latches
        // (ceiling: 300000 ticks).
        waited = 0;
        while (!game_over && waited < 300) begin
            #(CLK_PERIOD * TEST_DIVISOR * 1000);
            waited = waited + 1;
        end

        if (game_over && lives == 2'd0 && lives_ok)
            $display("tb_lives PASS: lives only ever stepped down by one per hit, and game_over latched with lives=0 (~%0d move_ticks).", waited * 1000);
        else
            $display("WARNING tb_lives: game_over=%0d lives=%0d lives_ok=%0d after ~%0d move_ticks -- expected game_over with lives=0 inside that time.",
                      game_over, lives, lives_ok, waited * 1000);

        $display("tb_lives simulation complete.");
        $finish;
    end

endmodule


//==================================================================
// tb_modes: EASY vs MEDIUM, plus the title-screen FSM. Two graphics
// instances share clk/move_tick/not_reset; because the LFSR is free-
// running from the same initial value in both, they see identical random
// bits -- the ONLY difference is the `mode` input, so any difference in
// behaviour is down to the mode setting. Alien fire is disabled and the
// ship is left alone, so neither game can lose a life during the 2000-tick
// measurement window (MEDIUM descends ~240 px in that time, under the ~323 px
// needed to reach the ship's row).
//==================================================================
module tb_modes;

    localparam CLK_PERIOD   = 20;
    localparam TEST_DIVISOR = 5;
    localparam WINDOW_TICKS = 2000;

    reg clk = 1'b0;
    reg not_reset = 1'b0;
    reg start_key = 1'b0;
    reg [1:0] mode_e = 2'd0;      // EASY instance (flipped after the start press as a latch check)
    reg [1:0] mode_m = 2'd1;      // MEDIUM instance

    wire move_tick;

    wire [2:0] rgb_e, rgb_m;
    wire [7:0] score_e, score_m;
    wire [1:0] level_e, level_m;
    wire [1:0] lives_e, lives_m;
    wire       dest_e, dest_m;
    wire       over_e, over_m;

    integer easy_desc_0, med_desc_0;
    integer easy_desc,   med_desc;
    integer easy_steps,  med_steps;
    reg [8:0] prev_xe, prev_xm;
    reg       counting = 1'b0;

    clk_divider #(.DIVISOR(TEST_DIVISOR)) U_CLKDIV (
        .clk(clk), .not_reset(not_reset), .tick(move_tick)
    );

    graphics #(.ALIEN_FIRE_ENABLE(0)) U_EASY (
        .clk(clk), .not_reset(not_reset), .video_on(1'b0),
        .px_x(10'd0), .px_y(10'd0), .move_tick(move_tick),
        .nes_left(start_key), .nes_right(1'b0), .shoot(1'b0),
        .mode(mode_e),
        .rgb(rgb_e), .score(score_e), .level(level_e), .lives(lives_e),
        .destruction_o(dest_e), .game_over_o(over_e), .game_won_o()
    );

    graphics #(.ALIEN_FIRE_ENABLE(0)) U_MED (
        .clk(clk), .not_reset(not_reset), .video_on(1'b0),
        .px_x(10'd0), .px_y(10'd0), .move_tick(move_tick),
        .nes_left(start_key), .nes_right(1'b0), .shoot(1'b0),
        .mode(mode_m),
        .rgb(rgb_m), .score(score_m), .level(level_m), .lives(lives_m),
        .destruction_o(dest_m), .game_over_o(over_m), .game_won_o()
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    // Count sideways steps (x_offset changes) inside the measurement window.
    always @(posedge clk) begin
        if (counting) begin
            if (U_EASY.x_offset != prev_xe) easy_steps = easy_steps + 1;
            if (U_MED.x_offset  != prev_xm) med_steps  = med_steps + 1;
        end
        prev_xe = U_EASY.x_offset;
        prev_xm = U_MED.x_offset;
    end

    initial begin
        easy_steps = 0;
        med_steps  = 0;

        not_reset = 1'b0;
        #(CLK_PERIOD * 10);
        not_reset = 1'b1;
        #(CLK_PERIOD * 20);

        // --- title screen: both stay in TITLE (state 0) with no key ---
        #(CLK_PERIOD * TEST_DIVISOR * 200);
        if (U_EASY.state == 2'd0 && U_MED.state == 2'd0)
            $display("tb_modes: both instances waiting on the title screen.");
        else
            $display("WARNING tb_modes: an instance left the title screen without a key press.");

        // --- start both with one key press; the mode is latched now ---
        start_key = 1'b1;
        #(CLK_PERIOD * 4);
        start_key = 1'b0;
        #(CLK_PERIOD * 10);
        if (U_EASY.state == 2'd1 && U_MED.state == 2'd1 && U_EASY.diff == 2'd0 && U_MED.diff == 2'd1)
            $display("tb_modes PASS (FSM): both started on the key press; mode latched EASY=0 / MEDIUM=1.");
        else
            $display("WARNING tb_modes (FSM): states %0d/%0d, diff %0d/%0d after the start press.",
                      U_EASY.state, U_MED.state, U_EASY.diff, U_MED.diff);

        // flipping the switches now must change nothing (latched at start)
        mode_e = 2'd2;
        mode_m = 2'd0;
        #(CLK_PERIOD * TEST_DIVISOR * 5);
        if (U_EASY.diff == 2'd0 && U_MED.diff == 2'd1)
            $display("tb_modes PASS (latch): flipping the switches mid-game did not change the mode.");
        else
            $display("WARNING tb_modes (latch): mode changed mid-game.");

        // --- speed comparison over the same WINDOW_TICKS ---
        easy_desc_0 = U_EASY.descent_offset;
        med_desc_0  = U_MED.descent_offset;
        counting = 1'b1;
        #(CLK_PERIOD * TEST_DIVISOR * WINDOW_TICKS);
        counting = 1'b0;
        easy_desc = U_EASY.descent_offset - easy_desc_0;
        med_desc  = U_MED.descent_offset  - med_desc_0;

        $display("tb_modes: over %0d move_ticks -- descent: EASY %0d px, MEDIUM %0d px; sideways steps: EASY %0d, MEDIUM %0d",
                  WINDOW_TICKS, easy_desc, med_desc, easy_steps, med_steps);

        if (U_EASY.lives == 2'd3 && U_MED.lives == 2'd3 && U_EASY.state == 2'd1 && U_MED.state == 2'd1 &&
            med_desc >= 2 * easy_desc && easy_desc > 0)
            $display("tb_modes PASS (descent): MEDIUM descended %0d px vs EASY %0d px (>= 2x).", med_desc, easy_desc);
        else
            $display("WARNING tb_modes (descent): MEDIUM %0d px vs EASY %0d px -- expected MEDIUM >= 2x EASY (and still playing, no life lost).", med_desc, easy_desc);

        if (easy_steps > 0 && (med_steps * 2) >= (easy_steps * 5))
            $display("tb_modes PASS (sideways): MEDIUM took %0d sideways steps vs EASY %0d (>= 2.5x).", med_steps, easy_steps);
        else
            $display("WARNING tb_modes (sideways): MEDIUM %0d vs EASY %0d steps -- expected MEDIUM >= 2.5x EASY.", med_steps, easy_steps);

        $display("tb_modes simulation complete.");
        $finish;
    end

endmodule


//==================================================================
// tb_touch: an alien reaching the ship's row is game over immediately,
// whatever the number of lives. Aliens never fire and the player never
// shoots, so all 3 lives are intact the whole time (lives_seen proves it);
// the EASY formation simply descends until its bottom row touches the
// ship's row (~8000 move_ticks).
//==================================================================
module tb_touch;

    localparam CLK_PERIOD   = 20;
    localparam TEST_DIVISOR = 5;

    reg clk = 1'b0;
    reg not_reset = 1'b0;
    reg start_key = 1'b0;

    wire hsync, vsync, video_on, p_tick;
    wire [9:0] pixel_x, pixel_y;
    wire move_tick;
    wire [2:0] rgb;
    wire [7:0] score;
    wire [1:0] level;
    wire [1:0] lives;
    wire destruction, game_over;

    integer waited;
    reg [1:0] lives_seen = 2'd3;      // lowest `lives` value seen before game_over

    vga_controller U_VGA (
        .clk(clk), .not_reset(not_reset), .hsync(hsync), .vsync(vsync),
        .video_on(video_on), .p_tick(p_tick), .pixel_x(pixel_x), .pixel_y(pixel_y)
    );

    clk_divider #(.DIVISOR(TEST_DIVISOR)) U_CLKDIV (
        .clk(clk), .not_reset(not_reset), .tick(move_tick)
    );

    graphics #(.ALIEN_FIRE_ENABLE(0)) U_GRAPHICS (
        .clk(clk), .not_reset(not_reset), .video_on(video_on),
        .px_x(pixel_x), .px_y(pixel_y), .move_tick(move_tick),
        .nes_left(start_key), .nes_right(1'b0), .shoot(1'b0),
        .mode(2'd0),
        .rgb(rgb), .score(score), .level(level), .lives(lives),
        .destruction_o(destruction), .game_over_o(game_over), .game_won_o()
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    always @(posedge clk) begin
        if (!game_over && lives < lives_seen)
            lives_seen = lives;
    end

    initial begin
        not_reset = 1'b0;
        #(CLK_PERIOD * 10);
        not_reset = 1'b1;
        #(CLK_PERIOD * 20);
        start_key = 1'b1;
        #(CLK_PERIOD * 4);
        start_key = 1'b0;

        waited = 0;
        while (!game_over && waited < 300) begin
            #(CLK_PERIOD * TEST_DIVISOR * 1000);
            waited = waited + 1;
        end

        if (game_over && lives_seen == 2'd3 && lives == 2'd0)
            $display("tb_touch PASS: the formation reached the ship's row -> GAME OVER with all 3 lives still intact (~%0d move_ticks).", waited * 1000);
        else
            $display("WARNING tb_touch: game_over=%0d lives_seen=%0d lives=%0d after ~%0d move_ticks.", game_over, lives_seen, lives, waited * 1000);

        $display("tb_touch simulation complete.");
        $finish;
    end

endmodule


//==================================================================
// tb_hard: HARD mode (independent aliens). Alien return fire is off. The
// ship sweeps left and right firing, to prove that moving independent
// aliens can be shot; nothing else is touched.
//==================================================================
module tb_hard;

    localparam CLK_PERIOD   = 20;
    localparam TEST_DIVISOR = 5;
    localparam N            = 21;          // 7 columns x 3 rows
    // must mirror graphics.v's play rectangle
    localparam BOX_X0 = 16, BOX_X1 = 618, BOX_Y0 = 52, BOX_Y1 = 440;
    localparam X_MAX  = BOX_X1 - 32;
    localparam Y_MAX  = BOX_Y1 - 18;

    reg clk = 1'b0;
    reg not_reset = 1'b0;
    reg left = 1'b0, right = 1'b0, shoot = 1'b0;

    wire hsync, vsync, video_on, p_tick;
    wire [9:0] pixel_x, pixel_y;
    wire move_tick;
    wire [2:0] rgb;
    wire [7:0] score;
    wire [1:0] level;
    wire [1:0] lives;
    wire destruction, game_over, game_won;

    // monitor state
    reg          running = 1'b0;
    reg [N-1:0]  prev_p;
    reg [10*N-1:0] prev_x;
    integer k, j, mk, np, nmoved;
    integer bad_bounds, bad_spawn_y, spawns, ticks_any, ticks_all;
    integer distinct, maxy, waited, iter;
    reg [9:0] vx, vy;
    reg       dup;

    vga_controller U_VGA (
        .clk(clk), .not_reset(not_reset), .hsync(hsync), .vsync(vsync),
        .video_on(video_on), .p_tick(p_tick), .pixel_x(pixel_x), .pixel_y(pixel_y)
    );

    clk_divider #(.DIVISOR(TEST_DIVISOR)) U_CLKDIV (
        .clk(clk), .not_reset(not_reset), .tick(move_tick)
    );

    graphics #(.ALIEN_FIRE_ENABLE(0)) U_GRAPHICS (
        .clk(clk), .not_reset(not_reset), .video_on(video_on),
        .px_x(pixel_x), .px_y(pixel_y), .move_tick(move_tick),
        .nes_left(left), .nes_right(right), .shoot(shoot),
        .mode(2'd2),
        .rgb(rgb), .score(score), .level(level), .lives(lives),
        .destruction_o(destruction), .game_over_o(game_over), .game_won_o(game_won)
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    // Per-clock monitor. At a posedge, the DUT registers still hold the values
    // written at the PREVIOUS edge, so each sample sees one clean update.
    always @(posedge clk) begin
        if (running) begin
            np = 0;
            nmoved = 0;
            for (mk = 0; mk < N; mk = mk + 1) begin
                if (U_GRAPHICS.hp_flat[mk]) begin
                    if (!U_GRAPHICS.defeated[mk]) np = np + 1;     // shot aliens stop moving; don't count them
                    vx = U_GRAPHICS.hx_flat[10*mk +: 10];
                    vy = U_GRAPHICS.hy_flat[10*mk +: 10];
                    // strictly inside the play rectangle
                    if (vx < BOX_X0 || vx > X_MAX || vy < BOX_Y0 || vy > Y_MAX)
                        bad_bounds = bad_bounds + 1;
                    if (!prev_p[mk]) begin
                        // just appeared: must be on the top edge
                        spawns = spawns + 1;
                        if (vy != BOX_Y0) bad_spawn_y = bad_spawn_y + 1;
                    end else if (vx != prev_x[10*mk +: 10]) begin
                        nmoved = nmoved + 1;
                    end
                end
            end
            if (nmoved > 0) ticks_any = ticks_any + 1;
            if (nmoved > 0 && nmoved == np && np >= 5) ticks_all = ticks_all + 1;
            prev_p = U_GRAPHICS.hp_flat;
            prev_x = U_GRAPHICS.hx_flat;
        end
    end

    initial begin
        bad_bounds = 0; bad_spawn_y = 0; spawns = 0; ticks_any = 0; ticks_all = 0;
        prev_p = {N{1'b0}};
        prev_x = {(10*N){1'b0}};

        not_reset = 1'b0;
        #(CLK_PERIOD * 10);
        not_reset = 1'b1;
        #(CLK_PERIOD * 20);
        #(CLK_PERIOD * TEST_DIVISOR * 100);      // sit on the title screen a while

        // start with a short LEFT press (shorter than a move_tick: no ship move)
        left = 1'b1;
        #(CLK_PERIOD * 4);
        left = 1'b0;
        #(CLK_PERIOD * 10);
        running = 1'b1;

        if (U_GRAPHICS.state == 2'd1 && U_GRAPHICS.diff == 2'd2 && U_GRAPHICS.hp_flat == {N{1'b0}})
            $display("tb_hard PASS (start): HARD latched, game running, no alien on screen yet.");
        else
            $display("WARNING tb_hard (start): state=%0d diff=%0d present=%b", U_GRAPHICS.state, U_GRAPHICS.diff, U_GRAPHICS.hp_flat);

        // give every alien time to enter (spawn delays are at most ~330 ticks)
        #(CLK_PERIOD * TEST_DIVISOR * 450);
        if (spawns == N && U_GRAPHICS.hp_flat == {N{1'b1}})
            $display("tb_hard PASS (entry): all %0d aliens entered one by one (%0d appearances).", N, spawns);
        else
            $display("WARNING tb_hard (entry): %0d appearances, present=%b", spawns, U_GRAPHICS.hp_flat);
        if (bad_spawn_y == 0)
            $display("tb_hard PASS (spawn edge): every alien appeared exactly on the top edge (y=%0d).", BOX_Y0);
        else
            $display("WARNING tb_hard (spawn edge): %0d aliens appeared away from the top edge.", bad_spawn_y);

        // Sweep the ship left/right for ~2400 more ticks, firing as often as
        // the single-bullet rule allows. Each iteration = 4 ship steps.
        for (iter = 0; iter < 120; iter = iter + 1) begin
            if ((iter / 10) % 2 == 0) begin right = 1'b1; left = 1'b0; end
            else                      begin right = 1'b0; left = 1'b1; end
            shoot = 1'b1;
            #(CLK_PERIOD * 3);
            shoot = 1'b0;
            #(CLK_PERIOD * TEST_DIVISOR * 5 * 4);
        end
        right = 1'b0; left = 1'b0;

        $display("tb_hard: sideways-move ticks: %0d, of which ALL live aliens moved together: %0d", ticks_any, ticks_all);

        if (bad_bounds == 0)
            $display("tb_hard PASS (bounds): no alien was ever outside the play rectangle (x %0d..%0d, y %0d..%0d).", BOX_X0, X_MAX, BOX_Y0, Y_MAX);
        else
            $display("WARNING tb_hard (bounds): %0d out-of-rectangle samples.", bad_bounds);

        if (ticks_any > 0 && ticks_all * 20 <= ticks_any)
            $display("tb_hard PASS (independence): aliens step sideways independently (all-at-once only %0d of %0d move ticks).", ticks_all, ticks_any);
        else
            $display("WARNING tb_hard (independence): all-at-once %0d of %0d move ticks -- aliens look synchronised.", ticks_all, ticks_any);

        // different heights: count distinct y among the 21 aliens
        distinct = 0;
        for (k = 0; k < N; k = k + 1) begin
            dup = 1'b0;
            for (j = 0; j < k; j = j + 1)
                if (U_GRAPHICS.hy_flat[10*j +: 10] == U_GRAPHICS.hy_flat[10*k +: 10]) dup = 1'b1;
            if (!dup) distinct = distinct + 1;
        end
        if (distinct >= 10)
            $display("tb_hard PASS (descent): the aliens are at %0d different heights (each descends at its own rate).", distinct);
        else
            $display("WARNING tb_hard (descent): only %0d distinct heights among %0d aliens.", distinct, N);

        if (score > 8'd0)
            $display("tb_hard PASS (shooting): independent aliens can be shot (score=%0d, defeated=%b).", score, U_GRAPHICS.defeated);
        else
            $display("WARNING tb_hard (shooting): no alien was hit by ~20 swept shots (score=%0d).", score);

        // Let it run: the first alien to reach the ship's row must end the game.
        waited = 0;
        while (!game_over && !game_won && waited < 300) begin
            #(CLK_PERIOD * TEST_DIVISOR * 1000);
            waited = waited + 1;
        end
        maxy = 0;
        for (k = 0; k < N; k = k + 1)
            if (!U_GRAPHICS.defeated[k] && U_GRAPHICS.hy_flat[10*k +: 10] > maxy) maxy = U_GRAPHICS.hy_flat[10*k +: 10];
        if (game_over && lives == 2'd0 && maxy + 18 >= BOX_Y1)
            $display("tb_hard PASS (bottom): an alien reached the ship's row (y=%0d) -> GAME OVER.", maxy);
        else
            $display("WARNING tb_hard (bottom): game_over=%0d game_won=%0d lives=%0d lowest live alien y=%0d.", game_over, game_won, lives, maxy);

        $display("tb_hard simulation complete.");
        $finish;
    end

endmodule
