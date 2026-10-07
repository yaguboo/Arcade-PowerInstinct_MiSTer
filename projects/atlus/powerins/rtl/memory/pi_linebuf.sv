//============================================================================
//  Power Instinct -- one line buffer (simple dual port, 512 entries)
//
//  One write address, one read address, nothing else: the only shape that
//  always infers M10K.  Stadium Hero's sh_linebuf adds a blanking wipe on the
//  write port; this board does not need one (docs/DECISIONS.md D6) -- every
//  line rewrites the full width because the BG layer is opaque and the text
//  layer writes every column, transparent or not.
//
//  A layer uses TWO of these, alternating per line.  Two arrays, not one
//  indexed by parity: one array would make a port read and write different
//  addresses, which is a register file (super_slams CLAUDE.md Must-Not-Break 5).
//============================================================================
`default_nettype none

module pi_linebuf #(
    parameter DW = 8
) (
    input  wire          clk,

    input  wire          we,
    input  wire [8:0]    waddr,
    input  wire [DW-1:0] wdata,

    input  wire          rd_en,
    input  wire [8:0]    raddr,
    output reg  [DW-1:0] q
);

(* ramstyle = "no_rw_check" *) reg [DW-1:0] mem [0:511];

// synthesis translate_off
integer i;
initial for (i = 0; i < 512; i = i + 1) mem[i] = {DW{1'b0}};
// synthesis translate_on

always @(posedge clk) if (we)    mem[waddr] <= wdata;
always @(posedge clk) if (rd_en) q <= mem[raddr];

endmodule

`default_nettype wire
