//============================================================================
//  Power Instinct -- ROM arbiter over one SDRAM
//
//  Adapted from projects/dataeast/stadium_hero/rtl/memory/sh_romarb.sv:
//  address-qualified `ok`, one always block owning every piece of state,
//  32-bit fetches as two consecutive reads of a LATCHED address.
//
//  THIS ARBITER IS A PLATFORM ARTEFACT (docs/HARDWARE_ARCHITECTURE.md 4).  On
//  OS93095 every ROM has its own bus; nobody waits for anybody.  Its costs
//  are visible and bounded: the 68000 sees a DTACK delay on program fetches,
//  and the tile layers render one line ahead (docs/DECISIONS.md D6).
//
//  ---- who goes next ---------------------------------------------------------
//  The two M6295s go first (DECISIONS D12).  jt6295 takes an ADPCM byte two
//  cen32 slots after presenting its address and never looks at rom_ok for it
//  (jt6295_rom.v) -- about 120 clocks at 4 MHz, and a missed deadline is a
//  wrong sample with nothing else looking wrong.  Behind a tile layer that
//  fills most of a line (below) that deadline is not safe.  pi_okicache keeps
//  their traffic to words that actually change, so first place costs little;
//  the two chips alternate so neither can hold the other off.
//
//  The 68000 has no slack: every clock its read is outstanding is a clock of
//  wait state.  The tile layers have a whole scanline.  So a pending CPU read
//  is served next -- but not twice in a row while video is waiting: after a
//  CPU word, one video fetch goes if one is pending.  That bounds the video
//  layers to at least half the bus under a CPU that fetches continuously,
//  which at 48 MHz is ~190 accesses a line against the ~164 the two tile
//  layers need (docs/VIDEO_PIPELINE.md).  An M6295 fetch does not count as
//  video for that rule.
//
//  The sprite renderer has a whole FRAME (pi_sprrend), so it goes last: only
//  when neither the CPU nor a tile layer is waiting.  Worst measured load in
//  MAME's attract, 7,314 visible tile rows = 14,628 fetches a frame
//  (docs/SPRITE_ANALYSIS.md 6) -- about 205k clocks of a frame's 854k.
//
//  ---- data conventions -------------------------------------------------------
//  SDRAM word W = { byte 2W, byte 2W+1 } (pi_download).
//    main  16 bit: the ROM files are little-endian words (ROM_LOAD16_WORD_SWAP),
//          so the 68000 word is { byte 2W+1, byte 2W } -- swapped here.
//    tx/bg 32 bit: { byte A, byte A+1, byte A+2, byte A+3 }, big-endian, so the
//          first pixel of a packed_msb row is data[31:28].
//    spr   32 bit: ROM_LOAD16_WORD_SWAP too, so { A+1, A, A+3, A+2 }.
//    oki   16 bit: plain byte ROMs, the word as stored -- the even byte is
//          [15:8]; pi_okicache picks the byte.  Chip 0 reads MAME region
//          "oki1" and chip 1 "oki2" (nmk112 set_rom0_tag / set_rom1_tag,
//          nmk16.cpp:5764-5765).
//============================================================================
`default_nettype none

module pi_romarb (
    input  wire        clk,
    input  wire        rst,

    // --- neutral memory port -------------------------------------------------
    output reg  [24:0] mem_addr,
    output wire [15:0] mem_din,
    input  wire [15:0] mem_dout,
    output reg         mem_req,
    output wire        mem_we,
    output wire [1:0]  mem_ds,
    input  wire        mem_ack,

    // --- download ------------------------------------------------------------
    input  wire        dl_active,
    input  wire [24:0] dl_addr,       // word address
    input  wire [15:0] dl_data,
    input  wire        dl_req,
    output wire        dl_ack,

    // --- readers -------------------------------------------------------------
    input  wire        main_cs,
    input  wire [19:1] main_addr,
    output reg  [15:0] main_data,
    output wire        main_ok,

    input  wire        tx_cs,
    input  wire [14:0] tx_addr,       // 32-bit word index into fgtile
    output reg  [31:0] tx_data,
    output wire        tx_ok,

    input  wire        bg_cs,
    input  wire [19:0] bg_addr,       // 32-bit word index into bgtile
    output reg  [31:0] bg_data,
    output wire        bg_ok,

    input  wire        spr_cs,
    input  wire [20:0] spr_addr,      // 32-bit word index into sprites
    output reg  [31:0] spr_data,
    output wire        spr_ok,

    input  wire        oki0_cs,
    input  wire [19:0] oki0_addr,     // 16-bit word index into "oki1"
    output reg  [15:0] oki0_data,
    output wire        oki0_ok,

    input  wire        oki1_cs,
    input  wire [19:0] oki1_addr,     // 16-bit word index into "oki2"
    output reg  [15:0] oki1_data,
    output wire        oki1_ok
);

`include "pi_rommap.svh"

assign mem_we  = dl_active & dl_req;
assign mem_din = dl_data;
assign mem_ds  = 2'b11;
assign dl_ack  = dl_active & mem_ack;

localparam [2:0] SEL_NONE = 3'd0,
                 SEL_MAIN = 3'd1,
                 SEL_TX   = 3'd2,
                 SEL_BG   = 3'd3,
                 SEL_SPR  = 3'd4,
                 SEL_OKI0 = 3'd5,
                 SEL_OKI1 = 3'd6;

reg [2:0] sel;
reg       half;
reg       rr;          // 0: tx next, 1: bg next
reg       rro;         // 0: oki0 next, 1: oki1 next
reg       vid_last;    // the last completed tile/sprite/CPU fetch was not the CPU's

reg [19:1] main_lat;  reg main_done;
reg [14:0] tx_lat;    reg tx_done;
reg [19:0] bg_lat;    reg bg_done;
reg [20:0] spr_lat;   reg spr_done;
reg [19:0] oki0_lat;  reg oki0_done;
reg [19:0] oki1_lat;  reg oki1_done;

assign main_ok = main_done & (main_lat == main_addr);
assign tx_ok   = tx_done   & (tx_lat   == tx_addr);
assign bg_ok   = bg_done   & (bg_lat   == bg_addr);
assign spr_ok  = spr_done  & (spr_lat  == spr_addr);
assign oki0_ok = oki0_done & (oki0_lat == oki0_addr);
assign oki1_ok = oki1_done & (oki1_lat == oki1_addr);

wire main_pend = main_cs & ~main_ok;
wire tx_pend   = tx_cs   & ~tx_ok;
wire bg_pend   = bg_cs   & ~bg_ok;
wire spr_pend  = spr_cs  & ~spr_ok;
wire oki0_pend = oki0_cs & ~oki0_ok;
wire oki1_pend = oki1_cs & ~oki1_ok;
wire vid_pend  = tx_pend | bg_pend;

wire [24:0] main_byte = PI_MAIN_BASE + { 5'd0, main_lat, 1'b0 };
wire [24:0] tx_byte   = PI_FG_BASE   + { 8'd0, tx_lat,   half, 1'b0 };
wire [24:0] bg_byte   = PI_BG_BASE   + { 3'd0, bg_lat,   half, 1'b0 };
wire [24:0] spr_byte  = PI_SPR_BASE  + { 2'd0, spr_lat,  half, 1'b0 };
wire [24:0] oki0_byte = PI_OKI1_BASE + { 4'd0, oki0_lat, 1'b0 };
wire [24:0] oki1_byte = PI_OKI2_BASE + { 4'd0, oki1_lat, 1'b0 };

wire two_halves = (sel == SEL_TX) || (sel == SEL_BG) || (sel == SEL_SPR);

always @(posedge clk) begin
    if (rst) begin
        sel       <= SEL_NONE;
        half      <= 1'b0;
        rr        <= 1'b0;
        rro       <= 1'b0;
        vid_last  <= 1'b0;
        mem_req   <= 1'b0;
        mem_addr  <= 25'd0;
        main_done <= 1'b0;
        tx_done   <= 1'b0;
        bg_done   <= 1'b0;
        spr_done  <= 1'b0;
        oki0_done <= 1'b0;
        oki1_done <= 1'b0;
    end else if (dl_active) begin
        sel      <= SEL_NONE;
        half     <= 1'b0;
        // `& ~mem_ack`: the downloader drops dl_req on the ack edge, so on that
        // edge dl_req still reads 1.  Without this a request survives the last
        // word and, once dl_active falls, a read of the old address completes
        // into whichever client is selected first.
        mem_req  <= dl_req & ~mem_ack;
        mem_addr <= dl_addr;
    end else if (sel == SEL_NONE) begin
        half    <= 1'b0;
        mem_req <= 1'b0;
        if (oki0_pend && (!rro || !oki1_pend)) begin
            sel <= SEL_OKI0; oki0_lat <= oki0_addr; oki0_done <= 1'b0; rro <= 1'b1;
        end else if (oki1_pend) begin
            sel <= SEL_OKI1; oki1_lat <= oki1_addr; oki1_done <= 1'b0; rro <= 1'b0;
        end else if (main_pend && (!vid_pend || vid_last)) begin
            sel <= SEL_MAIN; main_lat <= main_addr; main_done <= 1'b0;
        end else if (tx_pend && (!rr || !bg_pend)) begin
            sel <= SEL_TX;   tx_lat   <= tx_addr;   tx_done   <= 1'b0; rr <= 1'b1;
        end else if (bg_pend) begin
            sel <= SEL_BG;   bg_lat   <= bg_addr;   bg_done   <= 1'b0; rr <= 1'b0;
        end else if (spr_pend && !main_pend) begin
            sel <= SEL_SPR;  spr_lat  <= spr_addr;  spr_done  <= 1'b0;
        end
    end else if (!mem_req) begin
        mem_addr <= ((sel == SEL_MAIN) ? main_byte :
                     (sel == SEL_TX)   ? tx_byte   :
                     (sel == SEL_BG)   ? bg_byte   :
                     (sel == SEL_SPR)  ? spr_byte  :
                     (sel == SEL_OKI0) ? oki0_byte : oki1_byte) >> 1;
        mem_req  <= 1'b1;
    end else if (mem_ack) begin
        mem_req <= 1'b0;
        case (sel)
            SEL_MAIN: begin main_data <= { mem_dout[7:0], mem_dout[15:8] }; main_done <= 1'b1; end
            SEL_TX:   if (half) begin tx_data[15:0]  <= mem_dout; tx_done <= 1'b1; end
                      else            tx_data[31:16] <= mem_dout;
            SEL_BG:   if (half) begin bg_data[15:0]  <= mem_dout; bg_done <= 1'b1; end
                      else            bg_data[31:16] <= mem_dout;
            SEL_SPR:  if (half) begin spr_data[15:0]  <= { mem_dout[7:0], mem_dout[15:8] }; spr_done <= 1'b1; end
                      else            spr_data[31:16] <= { mem_dout[7:0], mem_dout[15:8] };
            SEL_OKI0: begin oki0_data <= mem_dout; oki0_done <= 1'b1; end
            SEL_OKI1: begin oki1_data <= mem_dout; oki1_done <= 1'b1; end
            default: ;
        endcase
        if (!half && two_halves) begin
            half <= 1'b1;
        end else begin
            sel      <= SEL_NONE;
            half     <= 1'b0;
            if (sel != SEL_OKI0 && sel != SEL_OKI1)
                vid_last <= (sel != SEL_MAIN);
        end
    end
end

endmodule

`default_nettype wire
