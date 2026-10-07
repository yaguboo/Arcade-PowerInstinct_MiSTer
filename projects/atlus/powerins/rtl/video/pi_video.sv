//============================================================================
//  Power Instinct -- video subsystem
//
//  Timing (20.u54 / 21.u71), text layer, background layer, sprites, 22.u81
//  mixer and palette.
//
//      pi_timing ── hpos, vline, blanking, line_end, render_go, IRQ, DMA
//      pi_tx     ── 8x8 text, line buffers                  ┐
//      pi_bg     ── 16x16 tilemap, line buffers              ├─> pi_colmix -> RGB
//      pi_sprlist ─> pi_sprrend ── sprite frame store       ┘
//      (DMA copy, walker)  (ROM fetch, pixels, 2 pages)
//
//  Output alignment: the RGB is two pixels behind hpos (pi_colmix header), so
//  sync and blanking leave through the same two-stage delay.
//
//  Flip screen: the layers are given mirrored coordinates (section below).
//============================================================================
`default_nettype none

module pi_video (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,

    // --- CPU -----------------------------------------------------------------
    input  wire [13:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,
    input  wire        pal_cs,
    input  wire        scroll_cs,
    input  wire        bgv_cs,
    input  wire        txv_cs,
    output wire [15:0] pal_din,
    output wire [15:0] scroll_din,
    output wire [15:0] bgv_din,
    output wire [15:0] txv_din,
    input  wire [3:0]  bg_bank,
    input  wire        flip,            // 0x100015 bit 0, pi_main's register

    // --- sprite DMA: work RAM second port, CPU stop ---------------------------
    output wire [14:0] spr_ram_addr,
    input  wire [15:0] spr_ram_q,
    output wire        spr_cpu_hold,

    // --- PROM load (0x000-0x0ff 20.u54, 0x100-0x1ff 21.u71, 0x200-0x21f 22.u81)
    input  wire        prom_we,
    input  wire [9:0]  prom_waddr,
    input  wire [7:0]  prom_wdata,

    // --- ROM -----------------------------------------------------------------
    output wire        tx_rom_cs,
    output wire [14:0] tx_rom_addr,
    input  wire [31:0] tx_rom_data,
    input  wire        tx_rom_ok,
    output wire        bg_rom_cs,
    output wire [19:0] bg_rom_addr,
    input  wire [31:0] bg_rom_data,
    input  wire        bg_rom_ok,
    output wire        spr_rom_cs,
    output wire [20:0] spr_rom_addr,
    input  wire [31:0] spr_rom_data,
    input  wire        spr_rom_ok,

    // --- out -----------------------------------------------------------------
    output wire [7:0]  red,
    output wire [7:0]  green,
    output wire [7:0]  blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,

    output wire [2:0]  irq_level,
    output wire        irq_trig,
    output wire        dma,
    output wire        vblank_raw,

    input  wire [2:0]  gfx_en,          // [0] BG, [1] text, [2] sprites
    output reg  [7:0]  dbg_late_tx,     // lines per frame a renderer overran
    output reg  [7:0]  dbg_late_bg,
    output reg  [7:0]  dbg_late_spr     // frames whose sprites were cut by the next DMA
);

wire [8:0] hpos, render_line, vline;
wire       hb_raw, hs_raw, vb_raw, vs_raw;
wire       line_end, render_go, render_vis;

pi_timing u_timing (
    .clk         ( clk         ),
    .rst         ( rst         ),
    .pxl_cen     ( pxl_cen     ),
    .prom_we     ( prom_we     ),
    .prom_waddr  ( prom_waddr  ),
    .prom_wdata  ( prom_wdata  ),
    .hpos        ( hpos        ),
    .hblank      ( hb_raw      ),
    .hsync       ( hs_raw      ),
    .vblank      ( vb_raw      ),
    .vsync       ( vs_raw      ),
    .line_end    ( line_end    ),
    .vline       ( vline       ),
    .render_go   ( render_go   ),
    .render_line ( render_line ),
    .render_vis  ( render_vis  ),
    .ipl         (             ),
    .irq_trig    ( irq_trig    ),
    .irq_level   ( irq_level   ),
    .dma         ( dma         )
);

assign vblank_raw = vb_raw;

// ---- output alignment: two pixels, see header ------------------------------
reg [1:0] hs_p, vs_p, hb_p, vb_p;
always @(posedge clk) if (pxl_cen) begin
    hs_p <= { hs_p[0], hs_raw };
    vs_p <= { vs_p[0], vs_raw };
    hb_p <= { hb_p[0], hb_raw };
    vb_p <= { vb_p[0], vb_raw };
end
assign hsync  = hs_p[1];
assign vsync  = vs_p[1];
assign hblank = hb_p[1];
assign vblank = vb_p[1];

// ------------------------------------------------------------- flip screen
//  EMULATION_DERIVED T-FLIP-1: with flip on, the visible 320 x 224 picture is
//  turned 180 degrees.  From MAME: tilemap.cpp effective_row/colscroll with
//  xextent 440 / yextent 256 and scrolldx 92 both ways (nmk16_v.cpp VIDEO_START
//  powerins), nmk16spr.cpp sx = 440-16-sx, sy = 256-16-sy with the unit order
//  and flip X reversed.  pi_goldmodel.py, rendering unflipped and turning the
//  picture, matches all 91 frames of a MAME run with the Flip Screen DIP on.
//  Done by giving every layer mirrored coordinates, as counters counting the
//  other way would: the tile layers render frame line 255-L and are read at
//  column 439-hpos (their buffers are read at hpos-60, so x becomes 319-x); the
//  sprite store is read at (439-hpos, 255-vline).  The visible ranges map onto
//  themselves (lines 16-239, hpos 60-379) and no latency changes, so the three
//  layers stay aligned.  How the NMK chips flip on the PCB is NOT known.
//  The register is taken at VBLANK start, so a frame uses one value.
reg flip_f = 1'b0, flip_vb_d = 1'b0;
always @(posedge clk) begin
    if (rst) begin
        flip_f    <= 1'b0;
        flip_vb_d <= 1'b0;
    end else begin
        flip_vb_d <= vb_raw;
        if (vb_raw && !flip_vb_d) flip_f <= flip;
    end
end

wire [8:0] hpos_l  = flip_f ? 9'd439 - hpos        : hpos;
wire [8:0] rline_l = flip_f ? 9'd255 - render_line : render_line;
wire [8:0] vline_l = flip_f ? 9'd255 - vline       : vline;

// ------------------------------------------------------------------ layers
wire [7:0] tx_pxl;
wire [8:0] bg_pxl;
wire [9:0] spr_pxl;
wire       tx_late, bg_late;

pi_tx u_tx (
    .clk         ( clk            ),
    .rst         ( rst            ),
    .pxl_cen     ( pxl_cen        ),
    .vram_cs     ( txv_cs         ),
    .cpu_addr    ( cpu_addr[11:1] ),
    .cpu_dout    ( cpu_dout       ),
    .cpu_din     ( txv_din        ),
    .cpu_rnw     ( cpu_rnw        ),
    .cpu_dsn     ( cpu_dsn        ),
    .line_end    ( line_end       ),
    .render_go   ( render_go      ),
    .render_vis  ( render_vis     ),
    .render_line ( rline_l        ),
    .hpos        ( hpos_l         ),
    .rom_cs      ( tx_rom_cs      ),
    .rom_addr    ( tx_rom_addr    ),
    .rom_data    ( tx_rom_data    ),
    .rom_ok      ( tx_rom_ok      ),
    .enable      ( gfx_en[1]      ),
    .pxl         ( tx_pxl         ),
    .late        ( tx_late        )
);

pi_bg u_bg (
    .clk         ( clk            ),
    .rst         ( rst            ),
    .pxl_cen     ( pxl_cen        ),
    .vram_cs     ( bgv_cs         ),
    .scroll_cs   ( scroll_cs      ),
    .cpu_addr    ( cpu_addr       ),
    .cpu_dout    ( cpu_dout       ),
    .vram_din    ( bgv_din        ),
    .scroll_din  ( scroll_din     ),
    .cpu_rnw     ( cpu_rnw        ),
    .cpu_dsn     ( cpu_dsn        ),
    .bank        ( bg_bank        ),
    .line_end    ( line_end       ),
    .render_go   ( render_go      ),
    .render_vis  ( render_vis     ),
    .render_line ( rline_l        ),
    .hpos        ( hpos_l         ),
    .rom_cs      ( bg_rom_cs      ),
    .rom_addr    ( bg_rom_addr    ),
    .rom_data    ( bg_rom_data    ),
    .rom_ok      ( bg_rom_ok      ),
    .enable      ( gfx_en[0]      ),
    .pxl         ( bg_pxl         ),
    .late        ( bg_late        )
);

// ----------------------------------------------------------------- sprites
wire        cmd_valid, cmd_ready, cmd_flip;
wire [15:0] cmd_code;
wire [9:0]  cmd_x, cmd_y;
wire [5:0]  cmd_colour;
wire        list_busy, rend_busy;

pi_sprlist u_sprlist (
    .clk        ( clk          ),
    .rst        ( rst          ),
    .dma        ( dma          ),
    .ram_addr   ( spr_ram_addr ),
    .ram_q      ( spr_ram_q    ),
    .cpu_hold   ( spr_cpu_hold ),
    .cmd_valid  ( cmd_valid    ),
    .cmd_ready  ( cmd_ready    ),
    .cmd_code   ( cmd_code     ),
    .cmd_x      ( cmd_x        ),
    .cmd_y      ( cmd_y        ),
    .cmd_flip   ( cmd_flip     ),
    .cmd_colour ( cmd_colour   ),
    .busy       ( list_busy    )
);

pi_sprrend u_sprrend (
    .clk        ( clk          ),
    .rst        ( rst          ),
    .pxl_cen    ( pxl_cen      ),
    .dma        ( dma          ),
    .cmd_valid  ( cmd_valid    ),
    .cmd_ready  ( cmd_ready    ),
    .cmd_code   ( cmd_code     ),
    .cmd_x      ( cmd_x        ),
    .cmd_y      ( cmd_y        ),
    .cmd_flip   ( cmd_flip     ),
    .cmd_colour ( cmd_colour   ),
    .rom_cs     ( spr_rom_cs   ),
    .rom_addr   ( spr_rom_addr ),
    .rom_data   ( spr_rom_data ),
    .rom_ok     ( spr_rom_ok   ),
    .hpos       ( hpos_l       ),
    .vline      ( vline_l      ),
    .enable     ( gfx_en[2]    ),
    .pxl        ( spr_pxl      ),
    .busy       ( rend_busy    )
);

// ------------------------------------------------------------------- mixer
wire prom22_we = prom_we & (prom_waddr[9:5] == 5'b10000);

pi_colmix u_colmix (
    .clk        ( clk              ),
    .rst        ( rst              ),
    .pxl_cen    ( pxl_cen          ),
    .pal_cs     ( pal_cs           ),
    .cpu_addr   ( cpu_addr[11:1]   ),
    .cpu_dout   ( cpu_dout         ),
    .cpu_din    ( pal_din          ),
    .cpu_rnw    ( cpu_rnw          ),
    .cpu_dsn    ( cpu_dsn          ),
    .prom_we    ( prom22_we        ),
    .prom_waddr ( prom_waddr[4:0]  ),
    .prom_wdata ( prom_wdata       ),
    .tx_pxl     ( tx_pxl           ),
    .bg_pxl     ( bg_pxl           ),
    .spr_pxl    ( spr_pxl          ),
    .blank      ( hb_raw | vb_raw  ),
    .red        ( red              ),
    .green      ( green            ),
    .blue       ( blue             )
);

// ------------------------------------------------------- late-line counters
reg [7:0] acc_tx, acc_bg;
reg       vb_d;
always @(posedge clk) begin
    if (rst) begin
        acc_tx <= 8'd0; acc_bg <= 8'd0; vb_d <= 1'b0;
        dbg_late_tx <= 8'd0; dbg_late_bg <= 8'd0; dbg_late_spr <= 8'd0;
    end else begin
        vb_d <= vb_raw;
        if (vb_raw && !vb_d) begin
            dbg_late_tx <= acc_tx; acc_tx <= 8'd0;
            dbg_late_bg <= acc_bg; acc_bg <= 8'd0;
        end else begin
            if (tx_late && !(&acc_tx)) acc_tx <= acc_tx + 8'd1;
            if (bg_late && !(&acc_bg)) acc_bg <= acc_bg + 8'd1;
        end
        // cumulative: a sprite frame still in progress when the next DMA comes
        if (dma && (list_busy || rend_busy) && !(&dbg_late_spr))
            dbg_late_spr <= dbg_late_spr + 8'd1;
    end
end

endmodule

`default_nettype wire
