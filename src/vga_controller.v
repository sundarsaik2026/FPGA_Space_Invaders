//------------------------------------------------------------------------------
// vga_controller.v
//
// Reproduces Section 3.A.1 "VGA controller" of the paper: generates the
// 640x480 @ 60Hz timing (hsync, vsync, video_on) and the current pixel
// coordinate (pixel_x, pixel_y) needed by the graphics module. The board
// clock is 50 MHz (Table 2); it is divided by 2 with a tick enable to
// approximate the paper's 25.175 MHz pixel clock (generated "from the
// 100 MHz system clock" per the paper's text -- the RTL/Table 2 pin list
// instead documents a 50 MHz clk, so a /2 enable is used here to land on
// the same ~25 MHz VGA pixel rate from that 50 MHz input).
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module vga_controller (
    input  wire        clk,        // 50 MHz board clock
    input  wire        not_reset,  // '0' = reset (paper's reverse-logic reset)
    output wire        hsync,
    output wire        vsync,
    output wire        video_on,
    output wire        p_tick,     // 1-cycle pixel-clock enable (~25 MHz)
    output wire [9:0]  pixel_x,
    output wire [9:0]  pixel_y
);

    // 640x480 @ 60 Hz timing (25.175 MHz pixel clock), negative sync polarity
    localparam H_DISPLAY = 640;
    localparam H_FRONT   = 16;
    localparam H_SYNC_W  = 96;
    localparam H_BACK    = 48;
    localparam H_MAX     = H_DISPLAY + H_FRONT + H_SYNC_W + H_BACK - 1; // 799

    localparam V_DISPLAY = 480;
    localparam V_FRONT   = 10;
    localparam V_SYNC_W  = 2;
    localparam V_BACK    = 33;
    localparam V_MAX     = V_DISPLAY + V_FRONT + V_SYNC_W + V_BACK - 1; // 524

    reg        pixel_tick = 1'b0;   // /2 divider off the 50 MHz clk
    reg [9:0]  h_count    = 10'd0;
    reg [9:0]  v_count    = 10'd0;

    //--------------------------------------------------------------------
    // Pixel-clock enable: divide 50 MHz by 2 -> ~25 MHz tick
    //--------------------------------------------------------------------
    always @(posedge clk) begin
        if (!not_reset)
            pixel_tick <= 1'b0;
        else
            pixel_tick <= ~pixel_tick;
    end

    assign p_tick = pixel_tick;

    //--------------------------------------------------------------------
    // Horizontal / vertical counters, advanced once per pixel tick
    //--------------------------------------------------------------------
    always @(posedge clk) begin
        if (!not_reset) begin
            h_count <= 10'd0;
            v_count <= 10'd0;
        end else if (pixel_tick) begin
            if (h_count == H_MAX) begin
                h_count <= 10'd0;
                if (v_count == V_MAX)
                    v_count <= 10'd0;
                else
                    v_count <= v_count + 10'd1;
            end else begin
                h_count <= h_count + 10'd1;
            end
        end
    end

    //--------------------------------------------------------------------
    // Sync pulses (active low) and video_on
    //--------------------------------------------------------------------
    assign hsync = ~((h_count >= (H_DISPLAY + H_FRONT)) &&
                      (h_count <  (H_DISPLAY + H_FRONT + H_SYNC_W)));

    assign vsync = ~((v_count >= (V_DISPLAY + V_FRONT)) &&
                      (v_count <  (V_DISPLAY + V_FRONT + V_SYNC_W)));

    assign video_on = (h_count < H_DISPLAY) && (v_count < V_DISPLAY);

    assign pixel_x = h_count;
    assign pixel_y = v_count;

endmodule
