//============================================================================
//  Power Instinct -- clock enables
//
//  One domain at 48.000 MHz (docs/DECISIONS.md D1).  OS93095 has three
//  crystals; everything on the 12 MHz and 16 MHz ones divides exactly:
//
//      68000    12.000 MHz   48 / 4    in pi_m68k (CLK_DIV)   nmk16.cpp:5735
//      Z80       6.000 MHz   48 / 8    cen_z80                 :5739, PCB note :8976
//      YM2203    1.500 MHz   48 / 32   cen_opn                 :5758, :8978
//      M6295     4.000 MHz   48 / 12   cen_oki                 :5766 "verified on PCB"
//
//  The 14 MHz video crystal is independent on the PCB and is fractional here:
//
//      pixel     7.000 MHz   48 x 7/48 pxl_cen                 :4370 "confirmed"
//
//  APPROXIMATION (DECISIONS D1): pulses are 6 or 7 clocks apart, 7 per 48 on
//  average.  Every video circuit runs on pxl_cen, so counts and frame content
//  are exact; only the analogue pixel spacing jitters.
//============================================================================
`default_nettype none

module pi_cen (
    input  wire clk,            // 48.000 MHz
    input  wire rst,

    output reg  pxl_cen,        // 7.000 MHz average
    output reg  cen_z80,        // 6.000 MHz
    output reg  cen_opn,        // 1.500 MHz
    output reg  cen_oki         // 4.000 MHz
);

reg [5:0] pacc;                 // 0..47
reg [4:0] div32;
reg [3:0] div12;

always @(posedge clk) begin
    if (rst) begin
        pacc    <= 6'd0;
        div32   <= 5'd0;
        div12   <= 4'd0;
        pxl_cen <= 1'b0;
        cen_z80 <= 1'b0;
        cen_opn <= 1'b0;
        cen_oki <= 1'b0;
    end else begin
        // pacc + 7 >= 48  <=>  pacc >= 41.  Compared, not reduced modulo:
        // a `%` here is a divider in the fastest path of the design.
        if (pacc >= 6'd41) begin
            pacc    <= pacc - 6'd41;
            pxl_cen <= 1'b1;
        end else begin
            pacc    <= pacc + 6'd7;
            pxl_cen <= 1'b0;
        end

        div32   <= div32 + 5'd1;
        div12   <= (div12 == 4'd11) ? 4'd0 : div12 + 4'd1;
        cen_z80 <= (div32[2:0] == 3'd0);
        cen_opn <= (div32 == 5'd0);
        cen_oki <= (div12 == 4'd0);
    end
end

endmodule

`default_nettype wire
