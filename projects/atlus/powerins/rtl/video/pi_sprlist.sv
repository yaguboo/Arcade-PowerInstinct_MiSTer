//============================================================================
//  Power Instinct -- sprite list: DMA copy and list walker (NMK008 role)
//
//  What the list is (MAME nmk16spr.cpp:15-30, get_flip_extcode_powerins
//  nmk16_v.cpp:355-359; FBNeo d_powerins.cpp:1310-1335 agrees field by field):
//      work RAM 0x188000-0x188fff, 256 entries x 8 words
//      w0 bit0 visible   w1 bit12 flip X, bit8 code bit 15, [7:4] rows-1,
//      [3:0] columns-1   w3 [14:0] code   w4 [9:0] X   w6 [9:0] Y
//      w7 [5:0] colour
//
//  ---- DMA -------------------------------------------------------------------
//  At the rising edge of 21.u71's /SPR-DMA (line 242, docs/PLD_PROM_ANALYSIS.md
//  2) the whole 0x1000-byte list is copied into the list buffer, as MAME's
//  sprite_dma() does.  The hardware manual's timing chart (quoted in
//  nmk16.cpp:4478-4497) says "CPU is stopped during DMA", 694 us.  Here the
//  68000 is held (cpu_hold) for the copy's own length, 2049 clocks = 43 us:
//  that keeps the copy atomic, as MAME's memcpy is, without the full 694 us.
//  HYPOTHESIS T-SPR-3 -- neither the stop mechanism (BR/BG?) nor the
//  duration is verified; MAME leaves its CPU stop commented out.
//
//  ---- walk --------------------------------------------------------------------
//  Entries 0..255 in order, every tile of a visible entry handed to the
//  renderer as one command { code, screen X, screen Y, flip, colour }.
//  Tile order rows-then-columns, code + row*(columns) + column, and flip X
//  places the columns right to left (MAME; FBNeo is column-first, EMULATOR_DIFF
//  D3 -- every sprite this game shows is one column wide, so the two agree).
//
//  Screen position, 10-bit arithmetic with wrap:
//      X = (w4 + 32) & 0x3ff      Y = (w6 - 16) & 0x3ff
//  EMULATION_DERIVED T-SPR-XY: MAME's videoshift 92 = HBLANK end 60 + 32, and
//  its cliprect starting at frame line 16; FBNeo's +32 / -16.  The BG layer's
//  X origin is the same -92 from the H counter (T-BG-2), so both layers
//  appear to share one board X origin -- not verified.
//
//  Later entries are drawn over earlier ones by the renderer (last write
//  wins).  MAME's prio_transpen reaches the same result (reverse order, first
//  write wins, drawgfx.cpp pmask |= 1<<31), FBNeo draws in order; the golden
//  model matched MAME on 91/91 frames with this rule (docs/SPRITE_ANALYSIS.md).
//
//  A tile that cannot reach the 320 x 224 window is not sent: a platform
//  saving of SDRAM fetches that changes nothing on screen.
//============================================================================
`default_nettype none

module pi_sprlist (
    input  wire        clk,
    input  wire        rst,
    input  wire        dma,             // one clock, /SPR-DMA rising

    // --- work RAM, second port -------------------------------------------------
    output wire [14:0] ram_addr,        // word index into 0x180000
    input  wire [15:0] ram_q,           // one clock after ram_addr
    output reg         cpu_hold,

    // --- tile commands to pi_sprrend --------------------------------------------
    output reg         cmd_valid,
    input  wire        cmd_ready,
    output reg  [15:0] cmd_code,
    output reg  [9:0]  cmd_x,
    output reg  [9:0]  cmd_y,
    output reg         cmd_flip,
    output reg  [5:0]  cmd_colour,

    output wire        busy
);

localparam [2:0] S_IDLE = 3'd0, S_COPY = 3'd1, S_FLUSH = 3'd2, S_RD = 3'd3,
                 S_EVAL = 3'd4, S_TILE = 3'd5, S_WAIT = 3'd6;

reg [2:0] st;
assign busy = (st != S_IDLE);

// ------------------------------------------------------------- list buffer
//  0x188000 is word 0x4000 of work RAM; the list is 2048 words.
reg  [10:0] cp_cnt;
reg         cp_p1;
reg  [10:0] cp_i1;
reg  [10:0] lb_raddr;
wire [15:0] lb_q;

assign ram_addr = { 4'b1000, cp_cnt };

pi_dpram16 #(.AW(11)) u_list (
    .clk    ( clk          ),
    .addr_a ( cp_i1        ),
    .data_a ( ram_q        ),
    .we_a   ( {2{cp_p1}}   ),
    .q_a    (              ),
    .addr_b ( lb_raddr     ),
    .q_b    ( lb_q         )
);

// ------------------------------------------------------------------ walker
reg  [7:0]  ent;
reg  [2:0]  rs;
reg  [15:0] w0, w1, w3, w4, w6, w7;

function automatic [2:0] widx(input [2:0] s);
    case (s)
        3'd0: widx = 3'd0;
        3'd1: widx = 3'd1;
        3'd2: widx = 3'd3;
        3'd3: widx = 3'd4;
        3'd4: widx = 3'd6;
        default: widx = 3'd7;
    endcase
endfunction

reg  [3:0]  ncol, nrow, c, r;
reg  [15:0] row_code;
reg  [9:0]  xc, xc0, yc;
reg         flip;
reg  [5:0]  colour;

wire tile_vis = ((yc < 10'd224) || (yc >= 10'd1009)) &&
                ((xc < 10'd320) || (xc >= 10'd1009));

// x of column 0: flip places the columns right to left
wire [9:0] x_first = w4[9:0] + 10'd32 + (w1[12] ? { 2'd0, w1[3:0], 4'd0 } : 10'd0);

task automatic advance;
begin
    if (c != ncol) begin
        c  <= c + 4'd1;
        xc <= flip ? xc - 10'd16 : xc + 10'd16;
        st <= S_TILE;
    end else if (r != nrow) begin
        r        <= r + 4'd1;
        c        <= 4'd0;
        row_code <= row_code + { 12'd0, ncol } + 16'd1;
        yc       <= yc + 10'd16;
        xc       <= xc0;
        st       <= S_TILE;
    end else if (ent != 8'd255) begin
        ent      <= ent + 8'd1;
        lb_raddr <= { ent + 8'd1, 3'd0 };
        rs       <= 3'd0;
        st       <= S_RD;
    end else begin
        st <= S_IDLE;
    end
end
endtask

always @(posedge clk) begin
    cp_p1 <= (st == S_COPY);
    cp_i1 <= cp_cnt;

    if (rst) begin
        st        <= S_IDLE;
        cpu_hold  <= 1'b0;
        cmd_valid <= 1'b0;
        cp_cnt    <= 11'd0;
    end else if (dma) begin
        st        <= S_COPY;
        cpu_hold  <= 1'b1;
        cmd_valid <= 1'b0;
        cp_cnt    <= 11'd0;
    end else begin
        case (st)
            S_COPY: begin
                cp_cnt <= cp_cnt + 11'd1;
                if (cp_cnt == 11'd2047) st <= S_FLUSH;
            end
            // the last word's write happens on this clock
            S_FLUSH: begin
                cpu_hold <= 1'b0;
                ent      <= 8'd0;
                lb_raddr <= 11'd0;
                rs       <= 3'd0;
                st       <= S_RD;
            end
            // six words; each is captured two clocks after it is presented
            S_RD: begin
                lb_raddr <= { ent, widx(rs + 3'd1) };
                rs       <= rs + 3'd1;
                case (rs)
                    3'd1: w0 <= lb_q;
                    3'd2: w1 <= lb_q;
                    3'd3: w3 <= lb_q;
                    3'd4: w4 <= lb_q;
                    3'd5: w6 <= lb_q;
                    3'd6: begin w7 <= lb_q; st <= S_EVAL; end
                    default: ;
                endcase
            end
            S_EVAL: begin
                ncol     <= w1[3:0];
                nrow     <= w1[7:4];
                flip     <= w1[12];
                colour   <= w7[5:0];
                row_code <= { w1[8], w3[14:0] };
                c        <= 4'd0;
                r        <= 4'd0;
                xc       <= x_first;
                xc0      <= x_first;
                yc       <= w6[9:0] - 10'd16;
                if (w0[0]) st <= S_TILE;
                else begin
                    // reuse advance's entry step: make it see a finished entry
                    ncol <= 4'd0; nrow <= 4'd0;
                    if (ent != 8'd255) begin
                        ent      <= ent + 8'd1;
                        lb_raddr <= { ent + 8'd1, 3'd0 };
                        rs       <= 3'd0;
                        st       <= S_RD;
                    end else begin
                        st <= S_IDLE;
                    end
                end
            end
            S_TILE: begin
                if (tile_vis) begin
                    cmd_valid  <= 1'b1;
                    cmd_code   <= row_code + { 12'd0, c };
                    cmd_x      <= xc;
                    cmd_y      <= yc;
                    cmd_flip   <= flip;
                    cmd_colour <= colour;
                    st         <= S_WAIT;
                end else begin
                    advance;
                end
            end
            S_WAIT: if (cmd_ready) begin
                cmd_valid <= 1'b0;
                advance;
            end
            default: st <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
