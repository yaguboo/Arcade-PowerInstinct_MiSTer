//============================================================================
//  Power Instinct -- NMK112: sample-ROM bank switch for the two M6295s
//
//  The whole device, from MAME src/devices/machine/nmk112.cpp (BSD-3-Clause,
//  references/upstream/mame @446356f).  It is small and fully defined there;
//  no open FPGA implementation exists in the factory's allowed sources
//  (third_party, references/upstream except the one repository DECISIONS D11
//  excludes), so this is new RTL -- root CLAUDE.md 1.2 box 5.
//
//    registers   eight, written at Z80 I/O 0x90-0x97
//                (macross2_sound_io_map, nmk16.cpp:1163).  offset bit 2 picks
//                the chip, bits 1:0 the bank (nmk112.cpp:96-97).
//    reset       all eight written with 0 (nmk112.cpp:84-88).
//    mask        data & bankmask at write time (nmk112.cpp:101).  The mask is
//                map_non_power_of_two over size / 64 KB (nmk112.cpp:43-47):
//                the 2 MB ROMs are 32 pages, so 5 bits.  Only those are kept.
//    samples     each chip's 18-bit space is four 64 KB banks
//                (nmk112.cpp:119-122):  ROM = page[a[17:16]] * 64 KB + a[15:0]
//    table       0x000-0x3ff is paged as well, 256 bytes a bank, when the chip
//                is paged (nmk112.cpp:125-131).  The table bank's base is
//                pagebase | i << 8 (nmk112.cpp:57), so an address a in bank i
//                reads   ROM = page[a[9:8]] * 64 KB + a[9:0]
//                powerins never calls set_page_mask; the constructor's
//                m_page_mask 0xff makes both chips paged (nmk112.cpp:26).
//
//  FBNeo src/burn/devices/nmk112.cpp, read for the facts only (no code taken):
//  bankaddr = data * 64 KB % size, bank 0 mapped from 0x400 when paged, table
//  bank i at bankaddr + i * 0x100 -- the same ROM address for every access.
//  Two emulators agreeing is evidence grade C (DECISIONS D11), not a PCB fact.
//
//  Both cases are one expression: the ROM byte is { page[n], a[15:0] } with
//  n = a[9:8] inside the table and a[17:16] everywhere else (inside the table
//  a[15:10] is zero, so a[15:0] = a[9:0]).
//
//  Combinational on the address side: jt6295 registers its own rom_addr
//  (jt6295_rom.v) and the arbiter latches what it fetches.
//============================================================================
`default_nettype none

module pi_nmk112 (
    input  wire        clk,
    input  wire        rst,

    input  wire        wr,             // one clock per Z80 write
    input  wire [2:0]  offset,         // I/O port - 0x90
    input  wire [7:0]  din,

    input  wire [17:0] oki0_addr,
    input  wire [17:0] oki1_addr,
    output wire [20:0] oki0_rom,       // byte offset into that chip's 2 MB ROM
    output wire [20:0] oki1_rom
);

reg [4:0] page [0:7];

integer i;
always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < 8; i = i + 1) page[i] <= 5'd0;
    end else if (wr) begin
        page[offset] <= din[4:0];
    end
end

function automatic [20:0] rom_of(input [17:0] a, input [4:0] p0, input [4:0] p1,
                                 input [4:0] p2, input [4:0] p3);
    reg [1:0] n;
begin
    n = (a[17:10] == 8'd0) ? a[9:8] : a[17:16];
    case (n)
        2'd0:    rom_of = { p0, a[15:0] };
        2'd1:    rom_of = { p1, a[15:0] };
        2'd2:    rom_of = { p2, a[15:0] };
        default: rom_of = { p3, a[15:0] };
    endcase
end
endfunction

assign oki0_rom = rom_of(oki0_addr, page[0], page[1], page[2], page[3]);
assign oki1_rom = rom_of(oki1_addr, page[4], page[5], page[6], page[7]);

endmodule

`default_nettype wire
