//============================================================================
//  Power Instinct -- layer mixer (22.u81) and palette
//
//  22.u81 (82S123, 32 x 8) is loaded from the ROM set and does the mixing,
//  as it does on the PCB.  MAME loads it as "color" and never reads it; the
//  decode is in docs/PLD_PROM_ANALYSIS.md 3:
//
//      address  A4 = TX pen is 15 (clear)      A3 = sprite pen is 15 (clear)
//               A2 = BG colour bit 4           A1:0 = sprite colour bits 5:4
//      output   q[2:0] = palette index [10:8]
//               q[4] /BG_OE   q[5] /SPR_OE   q[6] /TX_OE   q[7] unused
//
//  HYPOTHESIS H-MIX-1: the address wiring.  The PROM's contents are
//  consistent with it and with three independent MAME colour bases
//  (TX 0x200, sprites 0x400 x 64, BG 0x000 x 32), and inconsistent with the
//  opposite polarity (a clear TX pen would cover the screen).
//
//  Palette 0x120000-0x120fff, 2048 x RRRRGGGGBBBBRGBx (nmk16.cpp:5750):
//      R5 = {w[15:12], w[3]}  G5 = {w[11:8], w[2]}  B5 = {w[7:4], w[1]}
//  expanded {x5, x5[4:2]} as MAME's pal5bit and FBNeo's CalcCol both do.
//  EMULATION_DERIVED T-PAL-1: the PCB's DAC ladder is not known.
//
//  Latency: the line buffer read (1 pxl_cen), the palette read (1 clock),
//  the output register (next pxl_cen) -- two pixels behind hpos.  pi_video
//  delays sync and blanking by the same two.
//============================================================================
`default_nettype none

module pi_colmix (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,

    input  wire        pal_cs,
    input  wire [11:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    output wire [15:0] cpu_din,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,

    input  wire        prom_we,
    input  wire [4:0]  prom_waddr,
    input  wire [7:0]  prom_wdata,

    input  wire [7:0]  tx_pxl,          // { colour[3:0], pen }
    input  wire [8:0]  bg_pxl,          // { colour[4:0], pen }
    input  wire [9:0]  spr_pxl,         // { colour[5:0], pen }

    input  wire        blank,           // hblank | vblank, aligned with the pixels

    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue
);

// ------------------------------------------------------------------ 22.u81
reg [7:0] prom [0:31];
// synthesis translate_off
integer i;
initial for (i = 0; i < 32; i = i + 1) prom[i] = 8'h00;
// synthesis translate_on
always @(posedge clk) if (prom_we) prom[prom_waddr] <= prom_wdata;

wire [4:0] pa = { tx_pxl[3:0] == 4'hF, spr_pxl[3:0] == 4'hF, bg_pxl[8], spr_pxl[9:8] };
wire [7:0] pq = prom[pa];

wire [7:0]  low     = ~pq[6] ? tx_pxl        :
                      ~pq[5] ? spr_pxl[7:0]  :
                               bg_pxl[7:0];
wire [10:0] pal_idx = { pq[2:0], low };

// ----------------------------------------------------------------- palette
wire [1:0]  pal_we = ~cpu_dsn & {2{pal_cs & ~cpu_rnw}};
wire [15:0] pal_q;

pi_dpram16 #(.AW(11)) u_pal (
    .clk    ( clk      ),
    .addr_a ( cpu_addr ),
    .data_a ( cpu_dout ),
    .we_a   ( pal_we   ),
    .q_a    ( cpu_din  ),
    .addr_b ( pal_idx  ),
    .q_b    ( pal_q    )
);

wire [4:0] r5 = { pal_q[15:12], pal_q[3] };
wire [4:0] g5 = { pal_q[11:8],  pal_q[2] };
wire [4:0] b5 = { pal_q[7:4],   pal_q[1] };

reg blank_d;
always @(posedge clk) begin
    if (rst) begin
        red <= 8'd0; green <= 8'd0; blue <= 8'd0; blank_d <= 1'b1;
    end else if (pxl_cen) begin
        blank_d <= blank;
        if (blank_d) begin
            red <= 8'd0; green <= 8'd0; blue <= 8'd0;
        end else begin
            red   <= { r5, r5[4:2] };
            green <= { g5, g5[4:2] };
            blue  <= { b5, b5[4:2] };
        end
    end
end

endmodule

`default_nettype wire
