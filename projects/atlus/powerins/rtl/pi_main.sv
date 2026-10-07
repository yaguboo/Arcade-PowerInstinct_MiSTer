//============================================================================
//  Power Instinct -- 68000 side: address decode, work RAM, I/O, interrupt
//
//  Map: powerins_map, nmk16.cpp:1193-1209 (docs/MEMORY_MAP.md 1)
//
//    000000-0fffff  R   program ROM (SDRAM, through pi_romarb)
//    100000-100001  R   SYSTEM      100002-100003 R  P1_P2
//    100008-100009  R   DSW1        10000a-10000b R  DSW2
//    100015          W  flip screen (bit 0)
//    100016-100017   W  ?  (MAME nopw -- T-MAP-2)
//    100019          W  BG tile bank
//    10001f          W  sound latch
//    120000-120fff  RW  palette
//    130001/3/5/7   RW  scroll bytes
//    140000-143fff  RW  BG VRAM
//    170000-171fff  RW  text VRAM (0x171000 mirrors 0x170000)
//    180000-18ffff  RW  work RAM (sprite list at 188000-188fff)
//
//  EMULATION_DERIVED T-MAP-1: exactly MAME's decode.  Unmapped reads return
//  0 and every access gets DTACK.  The PCB's PALs are undumped.
//
//  ---- interrupt: HYPOTHESIS H-IRQ-1 (second form) ---------------------------
//  21.u71 holds the IPL code steady from one entry BEFORE each /TRIG edge to
//  several after it.  That is the setup/hold window of a latch clocked by
//  /TRIG: the IPL level is CAPTURED at the edge and held until the interrupt
//  acknowledge clears it.  Each trigger overwrites the level.
//
//  The first form -- a pending flag with IPL following the PROM live -- was
//  wrong, and the board simulation said so: levels 1-3 are masked by the game,
//  so their pending flag stayed set, and when the PROM's IPL bits turned to 4
//  one entry before the real trigger (line 238) the CPU took IRQ4 there AND at
//  the trigger.  Two IRQ4s a frame; the handler's text writes doubled (20 a
//  frame against MAME's 10) and the attract never reached the FBI screen.
//  docs/TODO_HARDWARE.md H-IRQ-1, docs/VALIDATION.md V4.
//
//  MAME uses a HOLD_LINE per level; with levels 1-3 masked and vectoring to
//  RTE (0x1A0, ROM_MEASURED) both give one IRQ4 a frame.
//============================================================================
`default_nettype none

module pi_main (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_rst,
    input  wire        ce_en,

    // --- program ROM ---------------------------------------------------------
    output wire        rom_cs,          // cache miss request to the arbiter
    output wire [19:1] rom_addr,
    input  wire [15:0] rom_data,
    input  wire        rom_ok,

    // --- video chip selects and read data --------------------------------------
    output wire        pal_cs,
    output wire        scroll_cs,
    output wire        bgv_cs,
    output wire        txv_cs,
    input  wire [15:0] pal_din,
    input  wire [15:0] scroll_din,
    input  wire [15:0] bgv_din,
    input  wire [15:0] txv_din,

    output wire [23:1] cpu_addr,
    output wire [15:0] cpu_dout,
    output wire        cpu_rnw,
    output wire [1:0]  cpu_dsn,

    // --- interrupt, from 21.u71 ----------------------------------------------
    input  wire [2:0]  irq_level,       // IPL bits of the triggering entry
    input  wire        irq_trig,

    // --- cabinet (active low) -------------------------------------------------
    input  wire [7:0]  sys_in,
    input  wire [15:0] joy_in,          // { P2, P1 }
    input  wire [15:0] dsw,             // { DSW2, DSW1 }

    output reg  [7:0]  snd_latch,
    output reg         snd_req,
    output reg  [3:0]  bg_bank,
    output reg         flip,

    // --- sprite DMA reads the list through the work RAM's second port ----------
    input  wire [14:0] spr_ram_addr,
    output wire [15:0] spr_ram_q,

    output wire        halted_n,
    output wire        cpu_waiting      // a program-ROM read is outstanding
);

wire [23:1] addr;
wire [15:0] cpu_do, cpu_di;
wire        cpu_rd, cpu_wr, uds_n, lds_n;
wire        bus_ack;
wire [2:0]  ipl_n;
wire [2:0]  fc;
wire        iack_stb;
wire        phi1_unused;

assign cpu_addr = addr;
assign cpu_dout = cpu_do;
assign cpu_rnw  = ~cpu_wr;
assign cpu_dsn  = { uds_n, lds_n };

wire acc = cpu_rd | cpu_wr;

// ------------------------------------------------------------ address decode
wire cs_rom = acc & (addr[23:20] == 4'h0);                 // 000000-0fffff
wire cs_io  = acc & (addr[23:16] == 8'h10) & (addr[15:6] == 10'd0);
wire cs_pal = acc & (addr[23:12] == 12'h120);              // 120000-120fff
wire cs_scr = acc & (addr[23:3]  == 21'h026000);           // 130000-130007
wire cs_bgv = acc & (addr[23:14] == 10'h050);              // 140000-143fff
wire cs_txv = acc & (addr[23:13] == 11'h0B8);              // 170000-171fff
wire cs_ram = acc & (addr[23:16] == 8'h18);                 // 180000-18ffff

wire rom_rd = cs_rom & cpu_rd;

// ---- program ROM through the word cache (pi_romcache, T-DTACK-1) ----------
//  rom_cs / rom_addr / rom_ok / rom_data are the ARBITER side now: the cache
//  asks for a word only on a miss.  pi_romarb's main_ok is address-qualified
//  and level, so it serves as the cache's m_ack directly.
wire        cache_ack;
wire [15:0] cache_q;

pi_romcache #(.IDX_BITS(14), .AW(19)) u_romcache (
    .clk   ( clk        ),
    .rst   ( rst | cpu_rst ),
    .c_a   ( addr[19:1] ),
    .c_rd  ( rom_rd     ),
    .c_ack ( cache_ack  ),
    .c_q   ( cache_q    ),
    .m_a   ( rom_addr   ),
    .m_rd  ( rom_cs     ),
    .m_ack ( rom_ok     ),
    .m_q   ( rom_data   )
);

assign pal_cs    = cs_pal;
assign scroll_cs = cs_scr;
assign bgv_cs    = cs_bgv;
assign txv_cs    = cs_txv;
assign cpu_waiting = rom_rd & ~cache_ack;

// ------------------------------------------------------------------ work RAM
wire [1:0]  ram_we = ~cpu_dsn & {2{cs_ram & cpu_wr}};
wire [15:0] ram_q;

pi_dpram16 #(.AW(15)) u_ram (
    .clk    ( clk        ),
    .addr_a ( addr[15:1] ),
    .data_a ( cpu_do     ),
    .we_a   ( ram_we     ),
    .q_a    ( ram_q      ),
    .addr_b ( spr_ram_addr ),   // sprite DMA (pi_sprlist) reads the list here
    .q_b    ( spr_ram_q    )
);

// ------------------------------------------------------------------------ I/O
//  EMULATION_DERIVED T-IO-1: the undefined high byte of SYSTEM and the DSWs
//  reads 0, as in MAME.  FBNeo returns 0xFF (EMULATOR_DIFF D6).
reg [15:0] io_q;
always @* begin
    case (addr[5:1])
        5'h00:   io_q = { 8'h00, sys_in };
        5'h01:   io_q = joy_in;
        5'h04:   io_q = { 8'h00, dsw[7:0] };
        5'h05:   io_q = { 8'h00, dsw[15:8] };
        default: io_q = 16'h0000;
    endcase
end

// Writes land on the LOW byte lane: MAME's byte handlers sit at the odd
// addresses, and the game writes these as words (the reset code's
// MOVE.W #$00FF,$10001E -- ROM_MEASURED; FBNeo's byte handler ignores them
// and the game still runs, EMULATOR_DIFF D7).
wire io_wr = cs_io & cpu_wr & ~lds_n & bus_ack;

always @(posedge clk) begin
    if (rst) begin
        snd_latch <= 8'd0;
        snd_req   <= 1'b0;
        bg_bank   <= 4'd0;
        flip      <= 1'b0;
    end else begin
        snd_req <= 1'b0;
        if (io_wr) begin
            case (addr[5:1])
                5'h0A: flip    <= cpu_do[0];
                5'h0C: bg_bank <= cpu_do[3:0];     // T-BG-3: width
                5'h0F: begin snd_latch <= cpu_do[7:0]; snd_req <= 1'b1; end
                default: ;
            endcase
        end
    end
end

// ------------------------------------------------------------------ interrupt
reg [2:0] irq_lat;
reg       iack_d;
always @(posedge clk) begin
    if (rst | cpu_rst) begin
        irq_lat <= 3'd0;
        iack_d  <= 1'b0;
    end else begin
        iack_d <= iack_stb;
        if (irq_trig)                 irq_lat <= irq_level;
        else if (iack_stb && !iack_d) irq_lat <= 3'd0;
    end
end

assign ipl_n = ~irq_lat;

// ------------------------------------------------------------------ read mux
assign cpu_di = cs_rom ? cache_q    :
                cs_ram ? ram_q      :
                cs_pal ? pal_din    :
                cs_bgv ? bgv_din    :
                cs_txv ? txv_din    :
                cs_scr ? scroll_din :
                cs_io  ? io_q       : 16'h0000;

// ------------------------------------------------------------------- bus ack
//  Program ROM waits for the cache (2 clocks on a hit, the SDRAM on a miss).
//  Other READS answer one clock later, when the block RAMs' q is valid.
//  WRITES answer at once.  fx68k lowers DS for a write half a CPU clock later
//  than for a read (S2, fx68k.sv:2426) and samples DTACK on the next phi2
//  (fx68k.sv:222), so a registered ack missed that sample and put one wait
//  state on every write -- 4.35 raster lines a frame in the fight scene
//  (docs/VALIDATION.md V11).  Every write target is a clocked register or a
//  block RAM, so one clock of strobe writes it; the data is on the bus before
//  DS falls (tb_board `wrchg` counts any change while DS is low).
//  TODO(HARDWAREIZE) T-DTACK-1: the PCB's own wait states are not known (its
//  PALs are undumped; MAME models none).  The ROM wait is the SDRAM's.
reg ack_d;
always @(posedge clk) begin
    if (rst) ack_d <= 1'b0;
    else     ack_d <= acc & ~rom_rd & ~ack_d & ~bus_ack;
end

assign bus_ack = rom_rd ? cache_ack : cpu_wr ? 1'b1 : ack_d;

// ------------------------------------------------------------------------ CPU
pi_m68k #(.CLK_DIV(4)) u_cpu (
    .clk      ( clk         ),
    .rst      ( rst         ),
    .cpu_rst  ( cpu_rst     ),
    .ce_en    ( ce_en       ),
    .addr     ( addr        ),
    .dout     ( cpu_do      ),
    .din      ( cpu_di      ),
    .rd       ( cpu_rd      ),
    .wr       ( cpu_wr      ),
    .uds_n    ( uds_n       ),
    .lds_n    ( lds_n       ),
    .ack      ( bus_ack     ),
    .ipl_n    ( ipl_n       ),
    .fc       ( fc          ),
    .iack_stb ( iack_stb    ),
    .halted_n ( halted_n    ),
    .dbg_phi1 ( phi1_unused )
);

endmodule

`default_nettype wire
