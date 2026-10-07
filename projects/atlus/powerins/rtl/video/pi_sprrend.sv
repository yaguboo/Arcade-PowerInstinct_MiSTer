//============================================================================
//  Power Instinct -- sprite renderer and frame store (NMK009 role)
//
//  HYPOTHESIS H-SPR-FB (docs/SPRITE_ANALYSIS.md): sprites are drawn into a
//  frame store over a whole frame and shown the frame after.  The evidence:
//    * MAME's sprite limit is a clock budget of one frame's length (448 x 263,
//      nmk16.cpp set_screen_midres) -- a drawing-time limit, not a per-line one
//    * MAME draws the list from TWO DMA copies back ("2 buffers confirmed on
//      PCB"), which is DMA + one frame of drawing
//    * a RAM bank beside the two NMK009s (8 x CXK58258 + 8 x AAA64K1P)
//  None of these is a schematic.  The visible timing it produces is MAME's:
//  the list copied at DMA k is on screen in frame k+2.
//
//  ---- a frame ---------------------------------------------------------------
//  /SPR-DMA: the page just drawn goes on display, the other page is cleared
//  (pen 15), then the tile commands from pi_sprlist are drawn into it.  A
//  frame whose list is not finished by the next DMA is shown as far as it got
//  (dbg late counter) -- the same kind of cut as the budget, not its size.
//
//  ---- a tile -------------------------------------------------------------------
//  sprites ROM is gfx_8x8x4_col_2x2_group_packed_msb after WORD_SWAP (MAME
//  gfx_powerins, generic.cpp:180): a tile is 128 bytes, column 0-7 rows 0-15
//  then column 8-15 rows 0-15, 4 bytes a row, high nibble first.  So one
//  32-bit fetch at { code, block, row } is eight pixels -- the ROM address is
//  the pixel's position, as on the tile layers.  A row is two fetches; with
//  flip X the right block goes on the left and each block is read backwards.
//  Rows and blocks that cannot reach the window are not fetched.
//
//  ---- priority -------------------------------------------------------------------
//  Later commands overwrite earlier ones (last write wins); pen 15 is not
//  written.  Sprite against the tile layers is 22.u81's job (pi_colmix).
//
//  ---- display ------------------------------------------------------------------
//  Read at row = vline - 16, column = hpos - 60 with pxl_cen, exactly as the
//  tile line buffers are read, so pi_colmix sees the three layers aligned.
//============================================================================
`default_nettype none

module pi_sprrend (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,
    input  wire        dma,

    // --- tile commands ------------------------------------------------------
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [15:0] cmd_code,
    input  wire [9:0]  cmd_x,
    input  wire [9:0]  cmd_y,
    input  wire        cmd_flip,
    input  wire [5:0]  cmd_colour,

    // --- ROM ------------------------------------------------------------------
    output reg         rom_cs,
    output reg  [20:0] rom_addr,        // 32-bit word index { code, block, row }
    input  wire [31:0] rom_data,
    input  wire        rom_ok,

    // --- display ----------------------------------------------------------------
    input  wire [8:0]  hpos,
    input  wire [8:0]  vline,
    input  wire        enable,
    output wire [9:0]  pxl,             // { colour[5:0], pen }, pen 15 = clear

    output wire        busy
);

localparam [16:0] LAST_ADDR = 17'd71679;

localparam [1:0] S_CLEAR = 2'd0, S_IDLE = 2'd1, S_ROW = 2'd2, S_FETCH = 2'd3;

reg [1:0]  st;
reg        front;                       // page on display: 0 = A, 1 = B
reg        clr_both;                    // power-up: both pages
reg [16:0] clr_addr;

assign cmd_ready = (st == S_IDLE);

// ------------------------------------------------------------------ the tile
reg [15:0] t_code;
reg [9:0]  t_x, t_y;
reg        t_flip;
reg [5:0]  t_colour;
reg [3:0]  q;                           // tile row
reg        hs;                          // screen half: 0 = columns 0-7
reg [16:0] row_base;

wire [9:0] sy   = t_y + { 6'd0, q };
wire [9:0] sx1  = t_x + 10'd8;
wire       vis0 = (t_x < 10'd320) || (t_x >= 10'd1017);
wire       vis1 = (sx1 < 10'd320) || (sx1 >= 10'd1017);

// ---------------------------------------------------------------- the writer
reg        draw_go, draw_busy;
reg [31:0] draw_data, dsh;
reg [9:0]  draw_sx, dsx;
reg [16:0] draw_base, dbase;
reg        dflip;
reg [5:0]  dcol;
reg [3:0]  dk;
reg        dw_we;
reg [16:0] dw_addr;
reg [9:0]  dw_data;

assign busy = (st != S_IDLE) | draw_busy | draw_go;

always @(posedge clk) begin
    draw_go <= 1'b0;
    if (rst) begin
        st       <= S_CLEAR;
        front    <= 1'b0;
        clr_both <= 1'b1;
        clr_addr <= 17'd0;
        rom_cs   <= 1'b0;
    end else if (dma) begin
        st       <= S_CLEAR;
        front    <= ~front;
        clr_addr <= 17'd0;
        rom_cs   <= 1'b0;
    end else begin
        case (st)
            S_CLEAR: begin
                clr_addr <= clr_addr + 17'd1;
                if (clr_addr == LAST_ADDR) begin
                    clr_both <= 1'b0;
                    st       <= S_IDLE;
                end
            end
            S_IDLE: if (cmd_valid) begin
                t_code   <= cmd_code;
                t_x      <= cmd_x;
                t_y      <= cmd_y;
                t_flip   <= cmd_flip;
                t_colour <= cmd_colour;
                q        <= 4'd0;
                st       <= S_ROW;
            end
            S_ROW: begin
                if (sy < 10'd224 && (vis0 || vis1)) begin
                    row_base <= { 1'b0, sy[7:0], 8'd0 } + { 3'd0, sy[7:0], 6'd0 };   // sy * 320
                    hs       <= ~vis0;
                    rom_addr <= { t_code, t_flip ^ ~vis0, q };
                    rom_cs   <= 1'b1;
                    st       <= S_FETCH;
                end else if (q == 4'd15) begin
                    st <= S_IDLE;
                end else begin
                    q <= q + 4'd1;
                end
            end
            S_FETCH: if (rom_ok && !draw_busy && !draw_go) begin
                draw_go   <= 1'b1;
                draw_data <= rom_data;
                draw_sx   <= hs ? sx1 : t_x;
                draw_base <= row_base;
                if (!hs && vis1) begin
                    hs       <= 1'b1;
                    rom_addr <= { t_code, ~t_flip, q };
                end else begin
                    rom_cs <= 1'b0;
                    if (q == 4'd15) st <= S_IDLE;
                    else begin
                        q  <= q + 4'd1;
                        st <= S_ROW;
                    end
                end
            end
            default: st <= S_IDLE;
        endcase
    end
end

// eight pixels a fetch, one clock each; pen 15 and off-window are not written
wire [3:0] dpen = dflip ? dsh[3:0] : dsh[31:28];

always @(posedge clk) begin
    if (rst || dma) begin
        draw_busy <= 1'b0;
        dw_we     <= 1'b0;
    end else if (draw_go) begin
        dsh       <= draw_data;
        dsx       <= draw_sx;
        dbase     <= draw_base;
        dflip     <= t_flip;
        dcol      <= t_colour;
        dk        <= 4'd0;
        draw_busy <= 1'b1;
        dw_we     <= 1'b0;
    end else if (draw_busy) begin
        dw_we   <= (dpen != 4'hF) && (dsx < 10'd320);
        dw_addr <= dbase + { 7'd0, dsx };
        dw_data <= { dcol, dpen };
        dsh     <= dflip ? (dsh >> 4) : (dsh << 4);
        dsx     <= dsx + 10'd1;
        dk      <= dk + 4'd1;
        if (dk == 4'd7) draw_busy <= 1'b0;
    end else begin
        dw_we <= 1'b0;
    end
end

// ----------------------------------------------------------------- the pages
wire        clearing = (st == S_CLEAR);
wire        w_en     = clearing | dw_we;
wire [16:0] w_addr   = clearing ? clr_addr : dw_addr;
wire [9:0]  w_data   = clearing ? 10'h00F  : dw_data;
wire        we_a     = w_en & (clr_both | front);      // A is drawn while B is shown
wire        we_b     = w_en & (clr_both | ~front);

wire        rowv = (vline >= 9'd16) && (vline < 9'd240);
wire        colv = (hpos  >= 9'd60) && (hpos  < 9'd380);
wire [7:0]  vrow = vline[7:0] - 8'd16;
wire [8:0]  vcol = hpos - 9'd60;
reg  [16:0] disp_base;
always @(posedge clk) disp_base <= { 1'b0, vrow, 8'd0 } + { 3'd0, vrow, 6'd0 };

wire [16:0] raddr = (rowv && colv) ? disp_base + { 8'd0, vcol } : 17'd0;

wire [9:0] qa, qb;
reg        rsel;

pi_fbram u_page_a (
    .clk(clk), .we(we_a), .waddr(w_addr), .wdata(w_data),
    .rd_en(pxl_cen), .raddr(raddr), .q(qa));
pi_fbram u_page_b (
    .clk(clk), .we(we_b), .waddr(w_addr), .wdata(w_data),
    .rd_en(pxl_cen), .raddr(raddr), .q(qb));

always @(posedge clk) if (pxl_cen) rsel <= front;

assign pxl = enable ? (rsel ? qb : qa) : 10'h00F;

endmodule

`default_nettype wire
