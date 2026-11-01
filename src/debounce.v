//------------------------------------------------------------------------------
// debounce.v
//
// Simple counter-based push-button debouncer. Neither the paper nor the
// earlier version of this reproduction debounced KEY presses; on real
// hardware a single physical press can register as several rapid
// transitions (mechanical switch bounce), making the ship jump multiple
// steps or fire multiple bullets per press. This module cleans that up:
// the input is first passed through a 2-flop synchronizer, then `out`
// only follows the input once it has been stable for DEBOUNCE_LIMIT
// consecutive clock cycles (~10 ms at 50 MHz with the default).
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module debounce #(
    parameter integer DEBOUNCE_LIMIT = 500000   // ~10 ms at 50 MHz
) (
    input  wire clk,
    input  wire in,
    output reg  out = 1'b1   // idle/un-pressed level for DE2-115's active-low KEYs
);

    reg in_sync0 = 1'b1;
    reg in_sync1 = 1'b1;
    reg [19:0] counter = 20'd0;

    // 2-flop synchronizer: buttons are an asynchronous, mechanical input
    always @(posedge clk) begin
        in_sync0 <= in;
        in_sync1 <= in_sync0;
    end

    // Only accept the new level once it has held steady for DEBOUNCE_LIMIT cycles
    always @(posedge clk) begin
        if (in_sync1 == out) begin
            counter <= 20'd0;
        end else begin
            counter <= counter + 20'd1;
            if (counter >= DEBOUNCE_LIMIT) begin
                out     <= in_sync1;
                counter <= 20'd0;
            end
        end
    end

endmodule
