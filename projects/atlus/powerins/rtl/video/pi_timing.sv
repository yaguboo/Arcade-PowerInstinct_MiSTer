//============================================================================
//  Power Instinct -- video timing from the two timing PROMs
//
//  Not MAME's screen parameters: the PCB's own counters and PROMs
//  (docs/VIDEO_TIMING.md, docs/PLD_PROM_ANALYSIS.md 1-2, DECISIONS D4).
//
//  ---- horizontal: 20.u54, 82S129, 256 x 4 --------------------------------
//  An 8-bit counter from 0x20 to 0xFF, one step per two pixels (448 px):
//      bit0 /LINE-END (px 400)   bit1 /HSYNC (px 416-447)   bit2 /HBLANK
//
//  ---- vertical: 21.u71, 82S135, 256 x 8 ----------------------------------
//  An 8-bit counter from 0x75 to 0xFF, one step per two lines (278 lines),
//  clocked by /LINE-END:
//      bit0 /SPR-DMA  bit1 /VSYNC  bit2 /VBLANK  bit6:4 IPL  bit7 /TRIG
//  Frame line 0 is entry 0x80: line = ((e - 0x80) mod 139) * 2 + half.
//
//  The PROMs are loaded from the ROM set during the download (DECISIONS D3).
//  Until they arrive every output is blank and nothing interrupts.
//
//  ---- what is a hypothesis --------------------------------------------------
//  HYPOTHESIS T-IRQ-2: which of the two lines of a V step is "half 0".  The
//  relation between IRQ, VBLANK and DMA does not depend on it.
//  HYPOTHESIS T-VID-1: the V counter moves at /LINE-END (px 400), as the PROM
//  places it, so VBLANK and VSYNC change inside HBLANK.
//============================================================================
`default_nettype none

module pi_timing (
    input  wire       clk,
    input  wire       rst,
    input  wire       pxl_cen,

    // --- PROM load: 0x000-0x0ff = 20.u54, 0x100-0x1ff = 21.u71 ---------------
    input  wire       prom_we,
    input  wire [9:0] prom_waddr,
    input  wire [7:0] prom_wdata,

    output reg  [8:0] hpos,          // 0..447, the pixel hq describes
    output wire       hblank,
    output wire       hsync,
    output wire       vblank,
    output wire       vsync,

    output reg        line_end,      // one clock, px 400
    output reg  [8:0] vline,         // frame line of the pixels now being scanned

    // --- line-ahead rendering (DECISIONS D6) ----------------------------------
    output reg        render_go,     // a few clocks after line_end
    output reg  [8:0] render_line,   // the line shown after the NEXT line_end
    output reg        render_vis,    // that line is outside V-PROM blanking

    output wire [2:0] ipl,           // IPL bits of the current V-PROM entry
    output reg        irq_trig,      // one clock, /TRIG rising
    output reg  [2:0] irq_level,     // IPL bits of the entry that raised /TRIG
    output reg        dma            // one clock, /SPR-DMA rising
);

(* ramstyle = "no_rw_check" *) reg [3:0] hprom [0:255];
(* ramstyle = "no_rw_check" *) reg [7:0] vprom [0:255];

// synthesis translate_off
integer i;
initial for (i = 0; i < 256; i = i + 1) begin hprom[i] = 4'h0; vprom[i] = 8'h00; end
// synthesis translate_on

always @(posedge clk) if (prom_we && prom_waddr[9:8] == 2'b00) hprom[prom_waddr[7:0]] <= prom_wdata[3:0];
always @(posedge clk) if (prom_we && prom_waddr[9:8] == 2'b01) vprom[prom_waddr[7:0]] <= prom_wdata;

// ------------------------------------------------------------------ horizontal
reg  [8:0] hcnt;                               // PROM address counter, pixels
reg  [3:0] hq;
reg        hq0_prev, pxl_d;
wire [7:0] haddr = 8'h20 + hcnt[8:1];          // 0x20..0xFF

// hq is a registered PROM read enabled by pxl_cen: after the edge it holds
// PROM(hcnt_old), and hpos holds hcnt_old, so the two describe the same pixel.
always @(posedge clk) if (pxl_cen) hq <= hprom[haddr];

always @(posedge clk) begin
    pxl_d <= pxl_cen;
    if (rst) begin
        hcnt     <= 9'd0;
        hpos     <= 9'd0;
        hq0_prev <= 1'b1;
        line_end <= 1'b0;
    end else begin
        if (pxl_cen) begin
            hcnt     <= (hcnt == 9'd447) ? 9'd0 : hcnt + 9'd1;
            hpos     <= hcnt;
            hq0_prev <= hq[0];
        end
        line_end <= pxl_d & ~hq[0] & hq0_prev;
    end
end

assign hblank = ~hq[2];
assign hsync  = ~hq[1];

// -------------------------------------------------------------------- vertical
reg        vhalf;
reg  [7:0] vcnt;
reg  [7:0] vq, vq_next, vq_cur;
reg        step, step_d;
reg  [3:0] go_dly;

wire [7:0] vcnt_inc  = (vcnt == 8'hFF) ? 8'h75 : vcnt + 8'd1;
// Entry of the line AFTER the current one: the second line of this step, or
// the first of the next.
wire [7:0] vaddr_nxt = vhalf ? vcnt_inc : vcnt;

always @(posedge clk) begin
    vq      <= vprom[vcnt];
    vq_next <= vprom[vaddr_nxt];
end

always @(posedge clk) begin
    if (rst) begin
        vhalf       <= 1'b0;
        vcnt        <= 8'h75;
        vline       <= 9'd256;
        vq_cur      <= 8'h00;
        step        <= 1'b0;
        step_d      <= 1'b0;
        irq_trig    <= 1'b0;
        irq_level   <= 3'd0;
        dma         <= 1'b0;
        go_dly      <= 4'd0;
        render_go   <= 1'b0;
        render_line <= 9'd0;
        render_vis  <= 1'b0;
    end else begin
        step     <= 1'b0;
        irq_trig <= 1'b0;
        dma      <= 1'b0;

        if (line_end) begin
            vhalf <= ~vhalf;
            vline <= (vline == 9'd277) ? 9'd0 : vline + 9'd1;
            if (vhalf) begin
                vcnt <= vcnt_inc;
                step <= 1'b1;
            end
        end

        // vcnt moved at `step`; vq has the new entry one clock later.
        step_d <= step;
        if (step_d) begin
            irq_trig <= vq[7] & ~vq_cur[7];
            if (vq[7] & ~vq_cur[7]) irq_level <= vq[6:4];
            dma      <= vq[0] & ~vq_cur[0];
            vq_cur   <= vq;
        end

        // render_go three clocks after line_end, when vline and vq_next have
        // both settled on the new line.
        go_dly    <= { go_dly[2:0], line_end };
        render_go <= go_dly[2];
        if (go_dly[2]) begin
            render_line <= (vline == 9'd277) ? 9'd0 : vline + 9'd1;
            render_vis  <= vq_next[2];          // /VBLANK high = visible
        end
    end
end

assign vblank = ~vq_cur[2];
assign vsync  = ~vq_cur[1];
assign ipl    = vq_cur[6:4];

endmodule

`default_nettype wire
