//============================================================================
//  Power Instinct -- 16-bit dual-port RAM with byte enables
//
//  From projects/dataeast/stadium_hero/rtl/memory/sh_dpram16.sv, unchanged in
//  behaviour.  Two byte-wide arrays rather than one masked 16-bit array: byte
//  enables on a single array are the classic way to fall off M10K inference
//  (root CLAUDE.md 7, step 0).
//
//  Port A: CPU, read/write.  Port B: read only.  Read data one clock after
//  the address on both ports.
//============================================================================
`default_nettype none

module pi_dpram16 #(
    parameter AW = 10
) (
    input  wire            clk,

    input  wire [AW-1:0]   addr_a,
    input  wire [15:0]     data_a,
    input  wire [1:0]      we_a,       // [1] upper byte, [0] lower byte
    output wire [15:0]     q_a,

    input  wire [AW-1:0]   addr_b,
    output wire [15:0]     q_b
);

(* ramstyle = "no_rw_check" *) reg [7:0] mem_hi [0:(1<<AW)-1];
(* ramstyle = "no_rw_check" *) reg [7:0] mem_lo [0:(1<<AW)-1];

// Simulation power-up state only; Quartus zeroes M10K anyway.  translate_off
// because Quartus refuses to unroll a constant loop past 5000 iterations.
// synthesis translate_off
integer ram_i;
initial for (ram_i = 0; ram_i < (1<<AW); ram_i = ram_i + 1)
    begin mem_hi[ram_i] = 8'd0; mem_lo[ram_i] = 8'd0; end
// synthesis translate_on

reg [7:0] qa_hi, qa_lo, qb_hi, qb_lo;

always @(posedge clk) begin
    if (we_a[1]) mem_hi[addr_a] <= data_a[15:8];
    qa_hi <= mem_hi[addr_a];
end

always @(posedge clk) begin
    if (we_a[0]) mem_lo[addr_a] <= data_a[7:0];
    qa_lo <= mem_lo[addr_a];
end

always @(posedge clk) begin
    qb_hi <= mem_hi[addr_b];
    qb_lo <= mem_lo[addr_b];
end

assign q_a = { qa_hi, qa_lo };
assign q_b = { qb_hi, qb_lo };

endmodule

`default_nettype wire
