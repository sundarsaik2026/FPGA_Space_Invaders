//------------------------------------------------------------------------------
// hex7seg.v
//
// Not from the paper -- a plain 4-bit-to-7-segment decoder, used on the
// DE2-115 to show `score`/`level` on the onboard HEX displays. The
// DE2-115's 7-segment displays are ACTIVE-LOW: driving a segment pin to 0
// turns that segment ON (per the official DE2-115 User Manual, Section
// 4.4: "Applying a low logic level to a segment will light it up"), so
// `seg` is built directly in that polarity -- wire it straight to a HEXn
// port in board/de2115/de2115_top.v, no extra inversion needed.
//
// Values are shown in hexadecimal (0-F), not decimal -- simplest to build
// with a plain lookup table and perfectly legible for a lab demo, just
// note it's hex when reading the display.
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module hex7seg (
    input  wire [3:0] hex,
    output reg  [6:0] seg   // {g,f,e,d,c,b,a}, active-low (0 = segment on)
);

    always @(*) begin
        case (hex)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111;   // all off
        endcase
    end

endmodule
