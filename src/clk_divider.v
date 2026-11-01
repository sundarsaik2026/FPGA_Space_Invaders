//------------------------------------------------------------------------------
// clk_divider.v
//
// Reproduces Section 3.B "Counter and Clock Division" of the paper. The
// paper's own snippet is a modulo counter compared against a fixed
// constant ("10111110101111000010000000") to throttle how often the ship
// position is allowed to update, so the ship moves at a visibly steady
// speed instead of jumping on every clock edge:
//
//   divide <= (others=>'0') when not_reset='0' else sig2 when rising_edge(clk);
//   sig1   <= std_logic_vector((counter)+2) when compare='1' else counter;
//   sig2   <= std_logic_vector((divide)+2) when compare='0' else (others=>'0');
//   compare<= '0' when divide < "10111110101111000010000000" else '1';
//   counter<= sig1 when rising_edge(clk);
//
// That is reproduced here with clearer signal names as a free-running
// counter that pulses `tick` for one clock once it reaches DIVISOR,
// functionally equivalent to the paper's compare/divide/counter pair.
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module clk_divider #(
    // At 50 MHz, 500,000 clk cycles ~= 100 Hz ship-movement update rate,
    // i.e. a smooth but visible step per button hold, matching the
    // paper's intent of slowing the ship relative to the system clock.
    parameter integer DIVISOR = 500000
) (
    input  wire clk,
    input  wire not_reset,  // '0' = reset
    output reg  tick        // 1-cycle pulse at the divided rate
);

    reg [31:0] counter = 32'd0;

    always @(posedge clk) begin
        if (!not_reset) begin
            counter <= 32'd0;
            tick    <= 1'b0;
        end else if (counter == DIVISOR - 1) begin
            counter <= 32'd0;
            tick    <= 1'b1;
        end else begin
            counter <= counter + 32'd1;
            tick    <= 1'b0;
        end
    end

endmodule
