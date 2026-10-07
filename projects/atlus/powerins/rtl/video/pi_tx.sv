//============================================================================
//  Power Instinct -- 8x8 text layer
//
//  What it is, from MAME (docs/SOURCE_EVIDENCE.md "tilemap 1"):
//      VRAM 0x170000-0x170fff, mirror 0x171000 (nmk16.cpp:1207)
//      TILEMAP_SCAN_COLS, 64 x 32 tiles: index = col*32 + row (nmk16_v.cpp:200)
//      [15:12] colour, [11:0] code (:46-50)
//      pen 15 transparent (:202), palette page 0x200 (gfx :4221; 22.u81 agrees)
//      no scroll; screen x 0 is tilemap x -32, i.e. column 60 (scrolldx 92)
//  The ROM is gfx_8x8x4_packed_msb: 32 bytes a tile, 4 bytes a row, high
//  nibble first -- one 32-bit fetch is exactly one row of eight pixels.
//  FG ROM tile 0 is all 0xFF (ROM_MEASURED), so FBNeo skipping code 0 and MAME
//  drawing it give the same picture (EMULATOR_DIFF D5).
//
//  How it is built (DECISIONS D6): at render_go the line shown after the next
//  line_end is rendered into the line buffer not on display; the buffers swap
//  at line_end.  Forty columns, every one written, so no wipe.
//============================================================================
`default_nettype none

module pi_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        pxl_cen,

    // --- CPU -----------------------------------------------------------------
    input  wire        vram_cs,
    input  wire [11:1] cpu_addr,
    input  wire [15:0] cpu_dout,
    output wire [15:0] cpu_din,
    input  wire        cpu_rnw,
    input  wire [1:0]  cpu_dsn,

    // --- timing --------------------------------------------------------------
    input  wire        line_end,
    input  wire        render_go,
    input  wire        render_vis,
    input  wire [8:0]  render_line,
    input  wire [8:0]  hpos,

    // --- ROM -----------------------------------------------------------------
    output reg         rom_cs,
    output reg  [14:0] rom_addr,
    input  wire [31:0] rom_data,
    input  wire        rom_ok,

    input  wire        enable,
    output wire [7:0]  pxl,             // { colour, pen }, pen 15 = clear
    output reg         late             // a render_go found the last line unfinished
);

// ---------------------------------------------------------------------- VRAM
wire [1:0]  cpu_we = ~cpu_dsn & {2{vram_cs & ~cpu_rnw}};
wire [10:0] scan_addr;
wire [15:0] scan_q;

pi_dpram16 #(.AW(11)) u_vram (
    .clk    ( clk       ),
    .addr_a ( cpu_addr  ),
    .data_a ( cpu_dout  ),
    .we_a   ( cpu_we    ),
    .q_a    ( cpu_din   ),
    .addr_b ( scan_addr ),
    .q_b    ( scan_q    )
);

// -------------------------------------------------------------- line buffers
reg        wsel;                        // buffer being written
reg        rsel;
reg        dw_we;
reg  [8:0] dw_addr;
reg  [7:0] dw_data;
wire [8:0] raddr = hpos - 9'd60;        // PROM visible start (20.u54 entry 0x3E)
wire [7:0] qa, qb;

pi_linebuf #(.DW(8)) u_buf_a (
    .clk(clk), .we(dw_we & ~wsel), .waddr(dw_addr), .wdata(dw_data),
    .rd_en(pxl_cen), .raddr(raddr), .q(qa));
pi_linebuf #(.DW(8)) u_buf_b (
    .clk(clk), .we(dw_we &  wsel), .waddr(dw_addr), .wdata(dw_data),
    .rd_en(pxl_cen), .raddr(raddr), .q(qb));

always @(posedge clk) if (pxl_cen) rsel <= ~wsel;
wire [7:0] q = rsel ? qb : qa;
assign pxl = enable ? q : 8'h0F;

// ------------------------------------------------------------------ renderer
localparam [1:0] S_IDLE = 2'd0, S_VRAM = 2'd1, S_VRAM2 = 2'd2, S_ROM = 2'd3;

reg [1:0] st;
reg [8:0] line;
reg [5:0] col;
reg [5:0] n;                            // 0..39
reg [3:0] colour;

assign scan_addr = { col, line[7:3] };  // visible lines are < 256

reg        draw_go;
reg [31:0] draw_data;
reg [3:0]  draw_col;
reg [8:0]  draw_addr;
reg        draw_busy;
reg [31:0] dsh;
reg [3:0]  dcol;
reg [3:0]  dcnt;

always @(posedge clk) begin
    if (rst) begin
        st       <= S_IDLE;
        rom_cs   <= 1'b0;
        draw_go  <= 1'b0;
        wsel     <= 1'b0;
        late     <= 1'b0;
    end else begin
        draw_go <= 1'b0;
        late    <= 1'b0;
        if (line_end) wsel <= ~wsel;

        if (render_go) begin
            late   <= (st != S_IDLE);
            rom_cs <= 1'b0;
            line   <= render_line;
            col    <= 6'd60;
            n      <= 6'd0;
            st     <= render_vis ? S_VRAM : S_IDLE;
        end else begin
            case (st)
                // scan_addr settled; the RAM registers q on this edge
                S_VRAM:  st <= S_VRAM2;
                S_VRAM2: begin
                    colour   <= scan_q[15:12];
                    rom_addr <= { scan_q[11:0], line[2:0] };
                    rom_cs   <= 1'b1;
                    st       <= S_ROM;
                end
                S_ROM: if (rom_ok && !draw_busy) begin
                    rom_cs    <= 1'b0;
                    draw_data <= rom_data;
                    draw_col  <= colour;
                    draw_addr <= { n, 3'b000 };
                    draw_go   <= 1'b1;
                    if (n == 6'd39) begin
                        st <= S_IDLE;
                    end else begin
                        n   <= n + 6'd1;
                        col <= col + 6'd1;      // 63 -> 0 wraps with the 6 bits
                        st  <= S_VRAM;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
end

// ---- eight pixels into the buffer, high nibble first ----------------------
always @(posedge clk) begin
    if (rst || line_end) begin
        draw_busy <= 1'b0;
        dw_we     <= 1'b0;
    end else if (draw_go) begin
        dsh       <= draw_data;
        dcol      <= draw_col;
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
