//============================================================================
//  Power Instinct -- sample-ROM word cache between one jt6295 and the arbiter
//
//  jt6295 owns its ROM pins: no request strobe, and its ADPCM path does not
//  look at rom_ok at all -- it takes rom_data two cen32 slots after presenting
//  the address (jt6295_rom.v header, "No adpcm_ok signal is generated").  The
//  control path does wait for rom_ok.  So the byte must be there, for the
//  address on the pins, quickly and every time.
//
//  jt6295_rom time-shares rom_addr between the four channels' ADPCM pointers
//  and the control machine's table pointer, so even a silent chip keeps
//  presenting several different addresses in turn.  A single latched word --
//  what the arbiter's address-qualified `ok` gives on its own -- would refetch
//  on every change; this board's SDRAM is already the 68000's measured
//  bottleneck (docs/VALIDATION.md V11-V13).  N words cached here make a chip
//  whose pointers are not moving cost nothing.
//
//  From Shadow Force (sf_sound.sv), each lesson paid for there:
//    * follow the WORD, not the byte: the two bytes of a word do not refetch
//    * pick the byte from the held word LIVE -- a byte latched at the fetch is
//      stale the moment the address moves to the other byte of the same word,
//      while ok stays high, and the phrase table is read as consecutive bytes
//  New here: N entries instead of one, fully associative, round-robin
//  replacement.  The key is the final ROM word (after NMK112), so a bank
//  change needs no invalidation -- the ROM never changes.
//
//  SDRAM word W = { byte 2W, byte 2W+1 } (pi_download): the even byte is [15:8].
//============================================================================
`default_nettype none

module pi_okicache #(
    parameter int N = 8
) (
    input  wire        clk,
    input  wire        rst,

    // --- jt6295 side (through pi_nmk112) ------------------------------------
    input  wire [20:0] rom_addr,        // byte offset into the chip's 2 MB ROM
    output wire [7:0]  rom_data,
    output wire        rom_ok,

    // --- arbiter side: one word at a time, level request -----------------------
    output reg         m_cs,
    output reg  [19:0] m_addr,          // word index into the region
    input  wire [15:0] m_data,
    input  wire        m_ok,            // address-qualified, level

    output reg         fetch_stb        // one clock per word fetched (instrument)
);

// Widths by bit-select of an int localparam, the form pi_m68k's LAST_I[DW-1:0]
// already put through Quartus 17.0 (a parameter-named size cast has not been).
localparam int PW     = (N > 1) ? $clog2(N) : 1;
localparam int LAST_I = N - 1;

reg  [N-1:0]  v;
reg  [19:0]   tag [0:N-1];
reg  [15:0]   dat [0:N-1];
reg  [PW-1:0] next;

wire [19:0] word = rom_addr[20:1];

reg        hit;
reg [15:0] hit_dat;
integer    i;
always @* begin
    hit     = 1'b0;
    hit_dat = 16'h0000;
    for (i = 0; i < N; i = i + 1)
        if (v[i] && tag[i] == word) begin
            hit     = 1'b1;
            hit_dat = dat[i];
        end
end

assign rom_ok   = hit;
assign rom_data = rom_addr[0] ? hit_dat[7:0] : hit_dat[15:8];

always @(posedge clk) begin
    fetch_stb <= 1'b0;
    if (rst) begin
        v      <= '0;
        next   <= '0;
        m_cs   <= 1'b0;
        m_addr <= 20'd0;
    end else if (!m_cs) begin
        if (!hit) begin
            m_cs   <= 1'b1;
            m_addr <= word;             // held until the arbiter answers
        end
    end else if (m_ok) begin
        m_cs         <= 1'b0;
        v[next]      <= 1'b1;
        tag[next]    <= m_addr;
        dat[next]    <= m_data;
        next         <= (next == LAST_I[PW-1:0]) ? '0 : next + 1'b1;
        fetch_stb    <= 1'b1;
    end
end

endmodule

`default_nettype wire
