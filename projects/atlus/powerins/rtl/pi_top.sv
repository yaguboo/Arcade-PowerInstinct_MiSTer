//============================================================================
//  Power Instinct (OS93095) -- board top
//
//  The arcade board and nothing else.  No hps_io, no ioctl, no MRA: those are
//  in targets/ (root CLAUDE.md 4).  Across this boundary: a neutral memory
//  port (mem_*), a neutral download port (dl_*), cabinet inputs, video, audio.
//
//  Clock: one 48.000 MHz domain (docs/DECISIONS.md D1).
//
//  Implemented in this build:
//      68000, full map, work RAM, I/O, interrupt from 21.u71     yes
//      video timing from 20.u54 / 21.u71                        yes
//      8x8 text layer, 16x16 BG layer, 22.u81 mixer, palette    yes
//      sprites (DMA, list walker, frame store)                  yes
//      Z80, YM2203, 2 x M6295, NMK112                           yes (D12)
//
//  The three PROMs arrive in the download stream at PI_PROM_BASE and are
//  copied into block RAM here as they pass (DECISIONS D3).  Nothing about the
//  ROM set is baked into the bitstream.
//============================================================================
`default_nettype none

module pi_top (
    input  wire        clk,            // 48.000 MHz
    input  wire        rst,
    input  wire        mem_rst,        // the memory path runs during download
    input  wire        pause,

    // --- neutral memory port -------------------------------------------------
    output wire [24:0] mem_addr,
    output wire [15:0] mem_din,
    input  wire [15:0] mem_dout,
    output wire        mem_req,
    output wire        mem_we,
    output wire [1:0]  mem_ds,
    input  wire        mem_ack,

    // --- download ------------------------------------------------------------
    input  wire        dl_active,
    input  wire [24:0] dl_addr,        // WORD address
    input  wire [15:0] dl_data,        // { byte 2W, byte 2W+1 }
    input  wire        dl_req,
    output wire        dl_ack,

    // --- cabinet, active low ---------------------------------------------------
    input  wire [7:0]  sys_in,         // coin1 coin2 service start1 start2 test - -
    input  wire [15:0] joy_in,         // { P2, P1 }: R L D U B1 B2 B3 B4
    input  wire [15:0] dsw,            // { DSW2, DSW1 }

    input  wire [2:0]  gfx_en,         // [0] BG  [1] text  [2] sprites
    input  wire [1:0]  cfg_ssg_level,  // pi_sound mix: SSG scale, 0 = calibrated
    input  wire        cfg_oki_uncal,  // pi_sound mix: 1 = M6295 without jt6295's calibration

    // --- video ----------------------------------------------------------------
    output wire [7:0]  red,
    output wire [7:0]  green,
    output wire [7:0]  blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        ce_pix,

    // --- audio ----------------------------------------------------------------
    output wire signed [15:0] snd_l,
    output wire signed [15:0] snd_r,

    // --- observability --------------------------------------------------------
    output wire        dbg_halted_n,
    output wire [7:0]  dbg_late_tx,
    output wire [7:0]  dbg_late_bg,
    output wire [7:0]  dbg_late_spr,
    output wire        dbg_cpu_waiting
);

`include "pi_rommap.svh"

// ------------------------------------------------------------ clock enables
wire pxl_cen, cen_z80, cen_opn, cen_oki;

pi_cen u_cen (
    .clk     ( clk     ),
    .rst     ( rst     ),
    .pxl_cen ( pxl_cen ),
    .cen_z80 ( cen_z80 ),
    .cen_opn ( cen_opn ),
    .cen_oki ( cen_oki )
);

assign ce_pix = pxl_cen;

// The 68000 also stops while the sprite list is copied (pi_sprlist, T-SPR-3).
wire spr_cpu_hold;
wire cpu_rst = rst | dl_active;
wire ce_en   = ~pause & ~dl_active & ~spr_cpu_hold;

// ------------------------------------------------------------- PROM capture
//  dl word W carries bytes 2W and 2W+1.  A word inside the PROM window is
//  written as two single-byte writes on consecutive clocks, so the PROM RAMs
//  keep ONE write port and infer as memory.  The downloader cannot present
//  the next word sooner than an SDRAM write takes.
wire [24:0] dl_byte = { dl_addr[23:0], 1'b0 };
wire        in_prom = (dl_byte >= PI_PROM_BASE) && (dl_byte < PI_PROM_BASE + 25'h220);
wire [9:0]  dl_poff = dl_byte[9:0];     // PI_PROM_BASE has zero low bits

reg        prom_we;
reg  [9:0] prom_waddr;
reg  [7:0] prom_wdata;
reg        odd_pend;
reg  [7:0] odd_byte;
reg  [9:0] odd_addr;

always @(posedge clk) begin
    if (mem_rst) begin
        prom_we  <= 1'b0;
        odd_pend <= 1'b0;
    end else begin
        prom_we <= 1'b0;
        if (odd_pend) begin
            prom_we    <= 1'b1;
            prom_waddr <= odd_addr;
            prom_wdata <= odd_byte;
            odd_pend   <= 1'b0;
        end else if (dl_ack && in_prom) begin
            prom_we    <= 1'b1;
            prom_waddr <= dl_poff;
            prom_wdata <= dl_data[15:8];
            odd_byte   <= dl_data[7:0];
            odd_addr   <= dl_poff + 10'd1;
            odd_pend   <= 1'b1;
        end
    end
end

// ------------------------------------------------------------------ 68000
wire        rom_cs, rom_ok;
wire [19:1] rom_addr;
wire [15:0] rom_data;

wire        pal_cs, scroll_cs, bgv_cs, txv_cs;
wire [15:0] pal_din, scroll_din, bgv_din, txv_din;
wire [23:1] cpu_addr;
wire [15:0] cpu_dout;
wire        cpu_rnw;
wire [1:0]  cpu_dsn;
wire [2:0]  irq_level;
wire        irq_trig, dma, vblank_raw;
wire [7:0]  snd_latch;
wire        snd_req;
wire [3:0]  bg_bank;
wire        flip;
wire [14:0] spr_ram_addr;
wire [15:0] spr_ram_q;

pi_main u_main (
    .clk          ( clk             ),
    .rst          ( rst             ),
    .cpu_rst      ( cpu_rst         ),
    .ce_en        ( ce_en           ),
    .rom_cs       ( rom_cs          ),
    .rom_addr     ( rom_addr        ),
    .rom_data     ( rom_data        ),
    .rom_ok       ( rom_ok          ),
    .pal_cs       ( pal_cs          ),
    .scroll_cs    ( scroll_cs       ),
    .bgv_cs       ( bgv_cs          ),
    .txv_cs       ( txv_cs          ),
    .pal_din      ( pal_din         ),
    .scroll_din   ( scroll_din      ),
    .bgv_din      ( bgv_din         ),
    .txv_din      ( txv_din         ),
    .cpu_addr     ( cpu_addr        ),
    .cpu_dout     ( cpu_dout        ),
    .cpu_rnw      ( cpu_rnw         ),
    .cpu_dsn      ( cpu_dsn         ),
    .irq_level    ( irq_level       ),
    .irq_trig     ( irq_trig        ),
    .sys_in       ( sys_in          ),
    .joy_in       ( joy_in          ),
    .dsw          ( dsw             ),
    .snd_latch    ( snd_latch       ),
    .snd_req      ( snd_req         ),
    .bg_bank      ( bg_bank         ),
    .flip         ( flip            ),
    .spr_ram_addr ( spr_ram_addr    ),
    .spr_ram_q    ( spr_ram_q       ),
    .halted_n     ( dbg_halted_n    ),
    .cpu_waiting  ( dbg_cpu_waiting )
);

// ------------------------------------------------------------------ video
wire        tx_rom_cs, bg_rom_cs, spr_rom_cs, tx_rom_ok, bg_rom_ok, spr_rom_ok;
wire [14:0] tx_rom_addr;
wire [19:0] bg_rom_addr;
wire [20:0] spr_rom_addr;
wire [31:0] tx_rom_data, bg_rom_data, spr_rom_data;

pi_video u_video (
    .clk          ( clk              ),
    .rst          ( rst              ),
    .pxl_cen      ( pxl_cen          ),
    .cpu_addr     ( cpu_addr[13:1]   ),
    .cpu_dout     ( cpu_dout         ),
    .cpu_rnw      ( cpu_rnw          ),
    .cpu_dsn      ( cpu_dsn          ),
    .pal_cs       ( pal_cs           ),
    .scroll_cs    ( scroll_cs        ),
    .bgv_cs       ( bgv_cs           ),
    .txv_cs       ( txv_cs           ),
    .pal_din      ( pal_din          ),
    .scroll_din   ( scroll_din       ),
    .bgv_din      ( bgv_din          ),
    .txv_din      ( txv_din          ),
    .bg_bank      ( bg_bank          ),
    .flip         ( flip             ),
    .spr_ram_addr ( spr_ram_addr     ),
    .spr_ram_q    ( spr_ram_q        ),
    .spr_cpu_hold ( spr_cpu_hold     ),
    .prom_we      ( prom_we          ),
    .prom_waddr   ( prom_waddr       ),
    .prom_wdata   ( prom_wdata       ),
    .tx_rom_cs    ( tx_rom_cs        ),
    .tx_rom_addr  ( tx_rom_addr      ),
    .tx_rom_data  ( tx_rom_data      ),
    .tx_rom_ok    ( tx_rom_ok        ),
    .bg_rom_cs    ( bg_rom_cs        ),
    .bg_rom_addr  ( bg_rom_addr      ),
    .bg_rom_data  ( bg_rom_data      ),
    .bg_rom_ok    ( bg_rom_ok        ),
    .spr_rom_cs   ( spr_rom_cs       ),
    .spr_rom_addr ( spr_rom_addr     ),
    .spr_rom_data ( spr_rom_data     ),
    .spr_rom_ok   ( spr_rom_ok       ),
    .red          ( red              ),
    .green        ( green            ),
    .blue         ( blue             ),
    .hsync        ( hsync            ),
    .vsync        ( vsync            ),
    .hblank       ( hblank           ),
    .vblank       ( vblank           ),
    .irq_level    ( irq_level        ),
    .irq_trig     ( irq_trig         ),
    .dma          ( dma              ),
    .vblank_raw   ( vblank_raw       ),
    .gfx_en       ( gfx_en           ),
    .dbg_late_tx  ( dbg_late_tx      ),
    .dbg_late_bg  ( dbg_late_bg      ),
    .dbg_late_spr ( dbg_late_spr     )
);

// ------------------------------------------------------------------- sound
//  Z80 + YM2203 + 2 x M6295 + NMK112 (rtl/sound, DECISIONS D12).  The 68000
//  never reads the sound side back (the latch is the only path,
//  nmk16.cpp:1203).  The Z80 program is copied from the download stream into
//  block RAM as it passes, the way the PROMs are; the M6295 sample ROMs stay
//  in SDRAM behind pi_okicache and the arbiter's first place.
localparam [24:0] PI_SND_W0 = PI_SND_BASE >> 1;                  // word address
wire        in_sndrom  = (dl_addr >= PI_SND_W0) && (dl_addr < PI_SND_W0 + 25'h6000);  // 0xc000 bytes
wire        snd_rom_we = dl_ack && in_sndrom;
wire [24:0] snd_rom_w  = dl_addr - PI_SND_W0;

wire [20:0] oki0_rom_addr, oki1_rom_addr;
wire [7:0]  oki0_rom_data, oki1_rom_data;
wire        oki0_rom_ok, oki1_rom_ok;
wire        oki0_m_cs, oki1_m_cs, oki0_m_ok, oki1_m_ok, oki0_fetch, oki1_fetch;
wire [19:0] oki0_m_addr, oki1_m_addr;
wire [15:0] oki0_m_data, oki1_m_data;
wire signed [15:0] snd;

pi_sound u_sound (
    .clk           ( clk                 ),
    .rst           ( cpu_rst             ),
    .en            ( ~pause & ~dl_active ),
    .latch_din     ( snd_latch           ),
    .latch_we      ( snd_req             ),
    .rom_we        ( snd_rom_we          ),
    .rom_wa        ( snd_rom_w[14:0]     ),
    .rom_wd        ( dl_data             ),
    .oki0_rom_addr ( oki0_rom_addr       ),
    .oki0_rom_data ( oki0_rom_data       ),
    .oki0_rom_ok   ( oki0_rom_ok         ),
    .oki1_rom_addr ( oki1_rom_addr       ),
    .oki1_rom_data ( oki1_rom_data       ),
    .oki1_rom_ok   ( oki1_rom_ok         ),
    .cfg_ssg_level ( cfg_ssg_level       ),
    .cfg_oki_uncal ( cfg_oki_uncal       ),
    .snd           ( snd                 )
);

// The cached words are ROM contents: invalid across a download.
pi_okicache #(.N(8)) u_oki0cache (
    .clk       ( clk                  ),
    .rst       ( mem_rst | dl_active  ),
    .rom_addr  ( oki0_rom_addr        ),
    .rom_data  ( oki0_rom_data        ),
    .rom_ok    ( oki0_rom_ok          ),
    .m_cs      ( oki0_m_cs            ),
    .m_addr    ( oki0_m_addr          ),
    .m_data    ( oki0_m_data          ),
    .m_ok      ( oki0_m_ok            ),
    .fetch_stb ( oki0_fetch           )
);

pi_okicache #(.N(8)) u_oki1cache (
    .clk       ( clk                  ),
    .rst       ( mem_rst | dl_active  ),
    .rom_addr  ( oki1_rom_addr        ),
    .rom_data  ( oki1_rom_data        ),
    .rom_ok    ( oki1_rom_ok          ),
    .m_cs      ( oki1_m_cs            ),
    .m_addr    ( oki1_m_addr          ),
    .m_data    ( oki1_m_data          ),
    .m_ok      ( oki1_m_ok            ),
    .fetch_stb ( oki1_fetch           )
);

// MAME's speaker is mono (nmk16.cpp:5754); both channels carry it.
assign snd_l = snd;
assign snd_r = snd;

// ------------------------------------------------------------------ memory
pi_romarb u_romarb (
    .clk        ( clk          ),
    .rst        ( mem_rst      ),
    .mem_addr   ( mem_addr     ),
    .mem_din    ( mem_din      ),
    .mem_dout   ( mem_dout     ),
    .mem_req    ( mem_req      ),
    .mem_we     ( mem_we       ),
    .mem_ds     ( mem_ds       ),
    .mem_ack    ( mem_ack      ),
    .dl_active  ( dl_active    ),
    .dl_addr    ( dl_addr      ),
    .dl_data    ( dl_data      ),
    .dl_req     ( dl_req       ),
    .dl_ack     ( dl_ack       ),
    .main_cs    ( rom_cs       ),
    .main_addr  ( rom_addr     ),
    .main_data  ( rom_data     ),
    .main_ok    ( rom_ok       ),
    .tx_cs      ( tx_rom_cs    ),
    .tx_addr    ( tx_rom_addr  ),
    .tx_data    ( tx_rom_data  ),
    .tx_ok      ( tx_rom_ok    ),
    .bg_cs      ( bg_rom_cs    ),
    .bg_addr    ( bg_rom_addr  ),
    .bg_data    ( bg_rom_data  ),
    .bg_ok      ( bg_rom_ok    ),
    .spr_cs     ( spr_rom_cs   ),
    .spr_addr   ( spr_rom_addr ),
    .spr_data   ( spr_rom_data ),
    .spr_ok     ( spr_rom_ok   ),
    .oki0_cs    ( oki0_m_cs    ),
    .oki0_addr  ( oki0_m_addr  ),
    .oki0_data  ( oki0_m_data  ),
    .oki0_ok    ( oki0_m_ok    ),
    .oki1_cs    ( oki1_m_cs    ),
    .oki1_addr  ( oki1_m_addr  ),
    .oki1_data  ( oki1_m_data  ),
    .oki1_ok    ( oki1_m_ok    )
);

endmodule

`default_nettype wire
