//============================================================================
//  Power Instinct -- 16x16 paged background tilemap
//
//  From MAME (docs/SOURCE_EVIDENCE.md "tilemap 0", "scrolling", "tile banking"):
//      VRAM 0x140000-0x143fff, 0x2000 words (nmk16.cpp:1206)
//      index = { row[4], col[7:0], row[3:0] }  (tilemap_scan_pages nmk16_v.cpp:34-37)
//      256 x 32 tiles = 4096 x 512 px  (FBNeo uses 2048 wide: EMULATOR_DIFF D4)
//      code   = attr[10:0] | bank << 11       (:68-75)
//      colour = { attr[11], attr[15:12] }     -> palette 0x000 / 0x100 via 22.u81
//      opaque, no transparent pen
//      scroll X = {reg0, reg1}, Y = {reg2, reg3}, bytes at 0x130001/3/5/7
//      tilemap_x = screen_x - 32 + scrollx,  tilemap_y = frame_line + scrolly
//        EMULATION_DERIVED T-BG-2: the -32 is MAME scrolldx 92 = HBLANK end 60 + 32
//        and FBNeo's +32.  Where the 32 comes from on the PCB is not known.
//      The ROM is gfx_8x8x4_col_2x2_group_packed_msb: a tile is four 8x8 blocks
//      stored [top-left, bottom-left, top-right, bottom-right], 32 bytes each,
//      4 bytes a row, high nibble first.  So the ROM address IS the pixel's
//      coordinates: { code, block column, block row, row within block } --
//      one 32-bit fetch is eight pixels, two fetches are one tile row.
//
//  Line-ahead rendering, DECISIONS D6.  The scroll registers are sampled at
//  render_go, one line before display: APPROXIMATION T-BG-4.
//============================================================================
`default_nettype none

module pi_bg (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,

    // --- CPU -----------------------------------------------------------------
    input  wire        vram_cs,
    input  wire        scroll_cs,
    input  wire [13:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    output wire [15:0] vram_din,
    output wire [15:0] scroll_din,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,

    input  wire [3:0]  bank,

    // --- timing --------------------------------------------------------------
    input  wire        line_end,
    input  wire        render_go,
    input  wire        render_vis,
    input  wire [8:0]  render_line,
    input  wire [8:0]  hpos,

    // --- ROM -----------------------------------------------------------------
    output reg         rom_cs,
    output reg  [19:0] rom_addr,
    input  wire [31:0] rom_data,
    input  wire        rom_ok,

    input  wire        enable,
    output wire [8:0]  pxl,             // { colour[4:0], pen }
    output reg         late
);

// ------------------------------------------------------------ scroll register
//  MAME maps 0x130000-7 as RAM with umask 0x00ff: four readable bytes on the
//  LOW data lane, high byte reads 0.  The boot screen prints
//  "SCROLL RAM CHECK... OK", so they must read back (EMULATOR_DIFF D8).
reg [7:0] scr [0:3];
integer si;
always @(posedge clk) begin
    if (rst) begin
        for (si = 0; si < 4; si = si + 1) scr[si] <= 8'd0;
    end else if (scroll_cs && !cpu_rnw && !cpu_dsn[0]) begin
        scr[cpu_addr[2:1]] <= cpu_dout[7:0];
    end
end
assign scroll_din = { 8'h00, scr[cpu_addr[2:1]] };

// ---------------------------------------------------------------------- VRAM
wire [1:0]  cpu_we = ~cpu_dsn & {2{vram_cs & ~cpu_rnw}};
wire [12:0] scan_addr;
wire [15:0] scan_q;

pi_dpram16 #(.AW(13)) u_vram (
    .clk    ( clk       ),
    .addr_a ( cpu_addr  ),
    .data_a ( cpu_dout  ),
    .we_a   ( cpu_we    ),
    .q_a    ( vram_din  ),
    .addr_b ( scan_addr ),
    .q_b    ( scan_q    )
);

// -------------------------------------------------------------- line buffers
reg        wsel, rsel;
reg        dw_we;
reg  [8:0] dw_addr;
reg  [8:0] dw_data;
wire [8:0] raddr = hpos - 9'd60;
wire [8:0] qa, qb;

pi_linebuf #(.DW(9)) u_buf_a (
    .clk(clk), .we(dw_we & ~wsel), .waddr(dw_addr), .wdata(dw_data),
    .rd_en(pxl_cen), .raddr(raddr), .q(qa));
pi_linebuf #(.DW(9)) u_buf_b (
    .clk(clk), .we(dw_we &  wsel), .waddr(dw_addr), .wdata(dw_data),
    .rd_en(pxl_cen), .raddr(raddr), .q(qb));

always @(posedge clk) if (pxl_cen) rsel <= ~wsel;
wire [8:0] q = rsel ? qb : qa;
assign pxl = enable ? q : 9'd0;

// ------------------------------------------------------------------ renderer
localparam [2:0] S_IDLE = 3'd0, S_VRAM = 3'd1, S_VRAM2 = 3'd2,
                 S_ROMA = 3'd3, S_ROMB = 3'd4;

reg [2:0]  st;
reg [4:0]  row;
reg        yb;                          // block row: tile y 8..15
reg [2:0]  y3;                          // row within the 8x8 block
reg [7:0]  col;
reg [3:0]  ox;                          // sub-tile x offset of the first tile
reg [4:0]  j;                           // 0..20
reg [14:0] code;
reg [4:0]  colour;

assign scan_addr = { row[4], col, row[3:0] };

wire [15:0] sx  = { scr[0], scr[1] };
wire [15:0] sy  = { scr[2], scr[3] };
wire [8:0]  ty  = render_line + sy[8:0];                 // 512 px high
wire [11:0] tx0 = sx[11:0] - 12'd32;                     // 4096 px wide

reg        draw_go;
reg [31:0] draw_data;
reg [8:0]  draw_addr;
reg        draw_busy;
reg [31:0] dsh;
reg [4:0]  dcol;
reg [3:0]  dcnt;

wire [8:0] tile_x = { j, 4'b0000 } - { 5'd0, ox };

always @(posedge clk) begin
    if (rst) begin
        st      <= S_IDLE;
        rom_cs  <= 1'b0;
        draw_go <= 1'b0;
        wsel    <= 1'b0;
        late    <= 1'b0;
    end else begin
        draw_go <= 1'b0;
        late    <= 1'b0;
        if (line_end) wsel <= ~wsel;

        if (render_go) begin
            late   <= (st != S_IDLE);
            rom_cs <= 1'b0;
            row    <= ty[8:4];
            yb     <= ty[3];
            y3     <= ty[2:0];
            col    <= tx0[11:4];
            ox     <= tx0[3:0];
            j      <= 5'd0;
            st     <= render_vis ? S_VRAM : S_IDLE;
        end else begin
            case (st)
                S_VRAM:  st <= S_VRAM2;
                S_VRAM2: begin
                    code     <= { bank, scan_q[10:0] };
                    colour   <= { scan_q[11], scan_q[15:12] };
                    rom_addr <= { bank, scan_q[10:0], 1'b0, yb, y3 };
                    rom_cs   <= 1'b1;
                    st       <= S_ROMA;
                end
                // left block of the tile row
                S_ROMA: if (rom_ok && !draw_busy) begin
                    draw_data <= rom_data;
                    draw_addr <= tile_x;
                    draw_go   <= 1'b1;
                    rom_addr  <= { code, 1'b1, yb, y3 };  // right block
                    st        <= S_ROMB;
                end
                S_ROMB: if (rom_ok && !draw_busy) begin
                    rom_cs    <= 1'b0;
                    draw_data <= rom_data;
                    draw_addr <= tile_x + 9'd8;
                    draw_go   <= 1'b1;
                    if (j == 5'd20) begin
                        st <= S_IDLE;
                    end else begin
                        j   <= j + 5'd1;
                        col <= col + 8'd1;
                        st  <= S_VRAM;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
end

always @(posedge clk) begin
    if (rst || line_end) begin
        draw_busy <= 1'b0;
        dw_we     <= 1'b0;
    end else if (draw_go) begin
        dsh       <= draw_data;
        dcol      <= colour;
        dw_addr   <= draw_addr;
        dcnt      <= 4'd0;
        draw_busy <= 1'b1;
        dw_we     <= 1'b0;
    end else if (draw_busy) begin
        dw_we   <= 1'b1;
        dw_data <= { dcol, dsh[31:28] };
        if (dw_we) dw_addr <= dw_addr + 9'd1;
        dsh     <= dsh << 4;
        dcnt    <= dcnt + 4'd1;
        if (dcnt == 4'd7) draw_busy <= 1'b0;
    end else begin
        dw_we <= 1'b0;
    end
end

endmodule

`default_nettype wire
