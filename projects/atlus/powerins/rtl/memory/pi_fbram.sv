//============================================================================
//  Power Instinct -- one sprite frame-store page (simple dual port)
//
//  320 x 224 entries of { colour[5:0], pen[3:0] }, address row*320 + column.
//  One write port and one read port and nothing else: the shape that infers
//  M10K (root CLAUDE.md 7 step 0).  pi_sprrend uses two -- one on display,
//  one being drawn -- and swaps them at /SPR-DMA.
//
//  HYPOTHESIS H-SPR-FB (docs/SPRITE_ANALYSIS.md): the PCB draws sprites into
//  a frame store (the RAM bank beside the NMK009s).  By its part count that
//  store is larger than the screen; this one holds only the window that can
//  reach the screen, which changes nothing that is displayed.
//============================================================================
`default_nettype none

module pi_fbram #(
    parameter int DEPTH = 71680,
    parameter int AW    = 17,
    parameter int DW    = 10
) (
    input  wire          clk,

    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,

    input  wire          rd_en,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] q
);

(* ramstyle = "no_rw_check" *) reg [DW-1:0] mem [0:DEPTH-1];

// synthesis translate_off
integer i;
initial for (i = 0; i < DEPTH; i = i + 1) mem[i] = {DW{1'b0}};
// synthesis translate_on

always @(posedge clk) if (we)    mem[waddr] <= wdata;
always @(posedge clk) if (rd_en) q <= mem[raddr];

endmodule

`default_nettype wire
