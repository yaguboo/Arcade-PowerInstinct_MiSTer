//============================================================================
//  Power Instinct -- sound board: Z80 + YM2203 + 2 x M6295 + NMK112
//
//  docs/SOUND_ARCHITECTURE.md, docs/DECISIONS.md D12.  MAME nmk16.cpp @446356f:
//    powerins_sound_map     1219-1225  0000-bfff ROM, c000-dfff RAM,
//                                      e000 R sound latch
//    macross2_sound_io_map  1157-1163  00-01 YM2203, 80 M6295 #1, 88 M6295 #2,
//                                      90-97 NMK112
//    powerins (config)      5732-5774  Z80 12M/2; YM2203 12M/8, IRQ -> Z80 INT,
//                                      gain 2.0; M6295 16M/4 PIN7_LOW
//                                      "verified on PCB", gain 0.15 each; no NMI
//
//  ---- taken from sibling lanes, each one paid for there ---------------------
//  * Z80 program ROM and RAM in BRAM (D12; Super Slams ss_sound.sv).
//  * A refresh cycle also pulls MREQ: memory decode is MREQ & RFSH.  An I/O
//    decode excludes the interrupt acknowledge, IORQ & M1.  (ss_sound.sv)
//  * jt12's register block samples cs_n/wr_n on EVERY clk, so a YM write is
//    edged to ONE raw clock with its data captured -- held longer, each write
//    executes several times and re-triggers key-on.  (ss_sound.sv, Super Slams
//    DEBUG_LOG C8)
//  * jt03 reads return the register at the ADDRESS pin, so the address is the
//    captured one only while a write is presented.  (ss_sound.sv)
//  * jt12 / jt6295 pipelines initialise by shifting reset through themselves:
//    reset is held 4096 clocks.  (ss_sound.sv)
//  * PIN7_LOW is jt6295 ss = 0.  The sibling boards are PIN7 HIGH (ss = 1).
//  * jt6295 does not wait for rom_ok on ADPCM bytes; the arbiter serves the
//    M6295s first (D12, sh_romarb "deadline").
//
//  ---- clock enables, all integer at 48 MHz (D1) ------------------------------
//    Z80     6.000 MHz  48 / 8   CEN_p at 0, CEN_n at 4, half a period apart
//    YM2203  1.500 MHz  48 / 32  jt03 takes the chip clock (as Stadium Hero)
//    M6295   4.000 MHz  48 / 12
//  They stop with `en` (pause, download) and NOT with the 68000's DMA hold.
//
//  jt03 and jt6295 (c) Jose Tejada Gomez, GPLv3, third_party/audio.  T80,
//  third_party/cpu/t80.  T80 is VHDL: the board simulation binds
//  sim/stub/T80pa.v, which never runs, so a sim result says nothing about this
//  module's Z80 side (root CLAUDE.md 6.5).
//============================================================================
`default_nettype none

module pi_sound (
    input  wire        clk,             // 48.000 MHz
    input  wire        rst,             // held through the ROM download
    input  wire        en,              // low while paused or downloading

    // --- 68000 -> Z80 command latch (68000 0x10001f, nmk16.cpp:1203) --------
    input  wire [7:0]  latch_din,
    input  wire        latch_we,        // one clock

    // --- Z80 program ROM, filled from the download stream --------------------
    input  wire        rom_we,
    input  wire [14:0] rom_wa,          // word index, Z80 0x0000-0xbfff
    input  wire [15:0] rom_wd,          // { byte 2W, byte 2W+1 }

    // --- M6295 sample ROMs through the arbiter: byte offsets, 2 MB each ------
    output wire [20:0] oki0_rom_addr,
    input  wire [7:0]  oki0_rom_data,
    input  wire        oki0_rom_ok,
    output wire [20:0] oki1_rom_addr,
    input  wire [7:0]  oki1_rom_data,
    input  wire        oki1_rom_ok,

    // --- mix settings (OSD debug page): 0 is the calibrated mix below ---------
    input  wire [1:0]  cfg_ssg_level,   // SSG scale: 0 x40 (calibrated, V24), 1 x64, 2-3 x128 (builds 7-9)
    input  wire        cfg_oki_uncal,   // 1: M6295 at MAME's 0.15 without the calibration (builds 7-9 shape)

    output reg  signed [15:0] snd
);

// ------------------------------------------------------------ clock enables
reg [2:0] zdiv;
reg [4:0] ydiv;
reg [3:0] odiv;
always @(posedge clk) begin
    if (rst) begin
        zdiv <= 3'd0;
        ydiv <= 5'd0;
        odiv <= 4'd0;
    end else if (en) begin
        zdiv <= zdiv + 3'd1;                              // wraps at 8
        ydiv <= ydiv + 5'd1;                              // wraps at 32
        odiv <= (odiv == 4'd11) ? 4'd0 : odiv + 4'd1;
    end
end
wire cen_p   = en & (zdiv == 3'd0);
wire cen_n   = en & (zdiv == 3'd4);
wire ym_cen  = en & (ydiv == 5'd0);
wire oki_cen = en & (odiv == 4'd0);

// -------------------------------------------------------------------- reset
reg [12:0] rstcnt;
always @(posedge clk) begin
    if (rst)              rstcnt <= 13'd0;
    else if (!rstcnt[12]) rstcnt <= rstcnt + 13'd1;
end
wire snd_rst = rst | ~rstcnt[12];

// ---------------------------------------------------------------------- Z80
wire [15:0] z80_a;
wire [7:0]  z80_do;
reg  [7:0]  z80_di;
wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n;
wire        ym_irq_n;

T80pa #(.Mode(0)) u_z80 (
    .RESET_n ( ~snd_rst  ),
    .CLK     ( clk       ),
    .CEN_p   ( cen_p     ),
    .CEN_n   ( cen_n     ),
    .WAIT_n  ( 1'b1      ),     // ROM and RAM are BRAM: nothing stalls
    .INT_n   ( ym_irq_n  ),     // nmk16.cpp:5760
    .NMI_n   ( 1'b1      ),     // no NMI on this board: the Z80 polls e000
    .BUSRQ_n ( 1'b1      ),
    .M1_n    ( m1_n      ),
    .MREQ_n  ( mreq_n    ),
    .IORQ_n  ( iorq_n    ),
    .RD_n    ( rd_n      ),
    .WR_n    ( wr_n      ),
    .RFSH_n  ( rfsh_n    ),
    .HALT_n  ( halt_n    ),
    .BUSAK_n (           ),
    .OUT0    ( 1'b0      ),
    .A       ( z80_a     ),
    .DI      ( z80_di    ),
    .DO      ( z80_do    ),
    .R800_mode ( 1'b0    ),
    .REG     (           ),
    .DIRSet  ( 1'b0      ),
    .DIR     ( 212'd0    )
);

wire mem_cy = ~mreq_n & rfsh_n;
wire mem_rd = mem_cy & ~rd_n;
wire mem_wr = mem_cy & ~wr_n;
wire io_cy  = ~iorq_n & m1_n;
wire io_rd  = io_cy & ~rd_n;
wire io_wr  = io_cy & ~wr_n;

// ------------------------------------------------------------ memory decode
wire sel_rom   = (z80_a[15:14] != 2'b11);                  // 0000-bfff
wire sel_ram   = (z80_a[15:13] == 3'b110);                 // c000-dfff
// EMULATION_DERIVED T-SND-2: MAME decodes the latch at exactly e000 and maps
// nothing else above dfff.  The PCB's decoder is not dumped.  WRITES to e000
// and e001 are ignored, as MAME's commented-out nopw -- but the Z80 does write
// them: 86 and 11,408 times in 3000 frames (tools/golden/pi_sndbus.lua), e000
// echoing each command it received.  What they drive on the PCB is unknown.
wire sel_latch = (z80_a == 16'he000);

// Program ROM: 0xc000 bytes = 24,576 words.  The address is muxed to 0 outside
// the ROM so the array is read in range; the mux sits before the memory's
// address register and does not stop RAM inference.
reg [15:0] sndrom [0:24575];
reg [15:0] rom_q;
reg        rom_lo;
wire [14:0] rom_idx = sel_rom ? z80_a[15:1] : 15'd0;
always @(posedge clk) begin
    if (rom_we) sndrom[rom_wa] <= rom_wd;
    rom_q  <= sndrom[rom_idx];
    rom_lo <= z80_a[0];
end
wire [7:0] rom_byte = rom_lo ? rom_q[7:0] : rom_q[15:8];   // even byte is [15:8]

// Work RAM, 8 KB.
reg [7:0] wram [0:8191];
reg [7:0] wram_q;
always @(posedge clk) begin
    if (mem_wr && sel_ram) wram[z80_a[12:0]] <= z80_do;
    wram_q <= wram[z80_a[12:0]];
end

// Command latch.  One way: the 68000 never reads it back and nothing is
// cleared by the Z80's read (generic_latch_8, no ack wired).
reg [7:0] latch;
always @(posedge clk) begin
    if (rst)           latch <= 8'd0;
    else if (latch_we) latch <= latch_din;
end

// ----------------------------------------------------------------------- I/O
wire [7:0] port     = z80_a[7:0];                           // global_mask(0xff)
wire       ym_sel   = (port[7:1] == 7'b0000000);            // 00-01
wire       oki0_sel = (port == 8'h80);
wire       oki1_sel = (port == 8'h88);
wire       nmk_sel  = (port[7:3] == 5'b10010);              // 90-97

reg io_wr_d;
always @(posedge clk) io_wr_d <= io_wr;
wire io_wr_pulse = io_wr & ~io_wr_d;

reg       ym_act;
reg [7:0] ym_din_r;
reg       ym_addr_r;
always @(posedge clk) begin
    if (snd_rst) begin
        ym_act    <= 1'b0;
        ym_din_r  <= 8'd0;
        ym_addr_r <= 1'b0;
    end else begin
        ym_act <= 1'b0;                                     // one clock wide
        if (io_wr_pulse && ym_sel) begin
            ym_din_r  <= z80_do;
            ym_addr_r <= port[0];
            ym_act    <= 1'b1;
        end
    end
end
wire ym_addr = ym_act ? ym_addr_r : port[0];

// ---------------------------------------------------------------- YM2203
wire signed [15:0] ym_fm;
wire        [9:0]  ym_psg;
wire        [7:0]  ym_dout;

jt03 u_ym (
    .rst        ( snd_rst   ),
    .clk        ( clk       ),
    .cen        ( ym_cen    ),
    .din        ( ym_din_r  ),
    .addr       ( ym_addr   ),
    .cs_n       ( ~ym_act   ),
    .wr_n       ( ~ym_act   ),
    .dout       ( ym_dout   ),
    .irq_n      ( ym_irq_n  ),
    .IOA_in     ( 8'd0      ),
    .IOB_in     ( 8'd0      ),
    .IOA_out    (           ),
    .IOB_out    (           ),
    .IOA_oe     (           ),
    .IOB_oe     (           ),
    .psg_A      (           ),
    .psg_B      (           ),
    .psg_C      (           ),
    .fm_snd     ( ym_fm     ),
    .psg_snd    ( ym_psg    ),
    .snd        (           ),
    .snd_sample (           ),
    .debug_view (           )
);

// ---------------------------------------------------------- NMK112 + M6295
wire [17:0] oki0_a, oki1_a;
wire [7:0]  oki0_dout, oki1_dout;
wire signed [13:0] oki0_snd, oki1_snd;

pi_nmk112 u_nmk112 (
    .clk       ( clk                     ),
    .rst       ( snd_rst                 ),
    .wr        ( io_wr_pulse & nmk_sel   ),
    .offset    ( port[2:0]               ),
    .din       ( z80_do                  ),
    .oki0_addr ( oki0_a                  ),
    .oki1_addr ( oki1_a                  ),
    .oki0_rom  ( oki0_rom_addr           ),
    .oki1_rom  ( oki1_rom_addr           )
);

// ---- stopping the chip rather than feeding it a byte that is not there -----
//  jt6295 takes an ADPCM byte two cen32 slots after presenting the address and
//  never looks at rom_ok for it (jt6295_rom.v).  Measured (docs/VALIDATION.md
//  V26): under the load of a fight, pi_okicache is late 3 times in 13.1 M
//  latches -- rare, but each late byte is a wrong sample, and ADPCM is
//  differential so one wrong nibble smears.  The only way to make that
//  structurally zero is to hold the CHIP while its byte is not resident, which
//  is the shape the other NMK16 core verified on hardware (its docs, NMK-15).
//  The cost is that the chip loses those clock enables and runs a hair slow;
//  tb_board's `+okilog` audit counts the suppressed enables so the size of that
//  cost is measured, not assumed.
wire oki0_cen = oki_cen & oki0_rom_ok;
wire oki1_cen = oki_cen & oki1_rom_ok;

// The write strobe is the I/O cycle's own WR, several clocks wide with the
// data stable, as Stadium Hero drives jt6295 (sh_snd.sv).  INTERPOL stays 0:
// it would pull in a jtframe file that is not vendored (sf_sound.sv header).
jt6295 #(.INTERPOL(0)) u_oki0 (
    .rst      ( snd_rst                 ),
    .clk      ( clk                     ),
    .cen      ( oki0_cen                ),      // held while the byte is not resident
    .ss       ( 1'b0                    ),      // PIN7_LOW, nmk16.cpp:5767
    .wrn      ( ~(io_wr & oki0_sel)     ),
    .din      ( z80_do                  ),
    .dout     ( oki0_dout               ),
    .rom_addr ( oki0_a                  ),
    .rom_data ( oki0_rom_data           ),
    .rom_ok   ( oki0_rom_ok             ),
    .sound    ( oki0_snd                ),
    .sample   (                         )
);

jt6295 #(.INTERPOL(0)) u_oki1 (
    .rst      ( snd_rst                 ),
    .clk      ( clk                     ),
    .cen      ( oki1_cen                ),      // held while the byte is not resident
    .ss       ( 1'b0                    ),      // PIN7_LOW, nmk16.cpp:5771
    .wrn      ( ~(io_wr & oki1_sel)     ),
    .din      ( z80_do                  ),
    .dout     ( oki1_dout               ),
    .rom_addr ( oki1_a                  ),
    .rom_data ( oki1_rom_data           ),
    .rom_ok   ( oki1_rom_ok             ),
    .sound    ( oki1_snd                ),
    .sample   (                         )
);

// ------------------------------------------------------------- Z80 read mux
//  Unmapped reads return 0xff.  An interrupt acknowledge is neither a memory
//  nor an I/O cycle here and reads 0xff too (RST 38h in IM 0, ignored in IM 1).
always @* begin
    z80_di = 8'hff;
    if (mem_rd) begin
        if      (sel_rom)   z80_di = rom_byte;
        else if (sel_ram)   z80_di = wram_q;
        else if (sel_latch) z80_di = latch;
    end else if (io_rd) begin
        if      (ym_sel)    z80_di = ym_dout;
        else if (oki0_sel)  z80_di = oki0_dout;
        else if (oki1_sel)  z80_di = oki1_dout;
    end
end

// ---------------------------------------------------------------------- mix
//  EMULATION_DERIVED: MAME's routes, nmk16.cpp:5760 (YM2203 ALL_OUTPUTS 2.0)
//  and :5767 / :5771 (each M6295 0.15), mono.  MAME's gains act on streams in
//  each device model's own scale, and these cores have other scales, so every
//  source is put on one Q15 scale first -- as Stadium Hero's sh_mixer does for
//  the same two cores (projects/dataeast/stadium_hero/rtl/sound/sh_mixer.sv):
//    FM   jt03 fm_snd, signed 16 bits                     as is
//    SSG  jt03 psg_snd, three 8-bit channels summed, unsigned.  DC removed
//         (below), then x 40 (x 32 was 1.9 dB under MAME's balance -- V24)
//    PCM  jt6295 sound, four 12-bit voices summed         x 4, then x 3.97
//
//  ---- where x 3.97 comes from (docs/VALIDATION.md V24, 2026-09-16) ----------
//  Builds 7-10 used x 7.2, and that number was a LOWER BOUND borrowed from
//  Stadium Hero: with the M6295's attenuation forced to 0, jt6295 came out AT
//  LEAST 7x below MAME's okim6295 (its docs/DEBUG_LOG.md O4) -- a comparison
//  MAME's own side clipped, so it could only say "at least".
//  Measured properly once the simulation had a real Z80 (V23): MAME rendered
//  four times with the other sources muted, the simulation dumping each source
//  (tb_board +audiodump, tools/golden/pi_audiocmp.py), same 800-frame window of
//  the same coin/start run.  The FM matched MAME within 0.03 dB; the two M6295
//  sat 5.16 dB OVER MAME's balance and the SSG 1.9 dB under.
//      x 7.2 / 1.81 = x 3.97   ->  Q8 1104 -> 610
//      SSG x 32 -> x 40 (+1.9 dB)
//  Still APPROXIMATION (T-SND-3): the reference is MAME's balance, not the
//  PCB's resistors, op-amps and YM3014.
//  Builds 7-9 used SSG x 128 with no DC removal and no M6295 calibration: one
//  SSG channel at full volume came to 255 x 128 x 2.0 = 65,280, twice full
//  scale, so SSG notes clipped the whole mix, and on the board the music
//  drowned the voices (user, 2026-09-15).  cfg_ssg_level 2 (x 128, DC removed)
//  and cfg_oki_uncal bring those levels back for comparison by ear.
//  Gains in Q8: 2.0 = 512;  0.15 x 3.97 = 0.596 -> 152.5 a chip, 610 for the
//  summed pair;  0.15 alone -> 38 a chip, 152 for the pair (cfg_oki_uncal).
//  TODO(HARDWAREIZE) T-SND-3: the PCB mixes through a YM3014 DAC and op-amps
//  whose gains and filters are not known.

// DC blocker on the SSG -- the job of the PCB's output coupling capacitor
// (APPROXIMATION: its value is not known).  ssg_mean follows psg_snd with a
// 2^20-clock time constant: 22 ms at 48 MHz, a corner near 7 Hz.
reg  [29:0] ssg_acc;
wire [9:0]  ssg_mean = ssg_acc[29:20];
always @(posedge clk) begin
    if (snd_rst) ssg_acc <= 30'd0;
    else         ssg_acc <= ssg_acc + { 20'd0, ym_psg } - { 20'd0, ssg_mean };
end
wire signed [10:0] ssg_ac = $signed({ 1'b0, ym_psg }) - $signed({ 1'b0, ssg_mean });

reg signed [27:0] ssg_q15;
always @* begin
    case (cfg_ssg_level)
        // x 40 = x 32 + x 8, the level V24 measured against MAME (was x 32)
        2'd0:    ssg_q15 = $signed({ {12{ssg_ac[10]}}, ssg_ac, 5'd0 })
                         + $signed({ {14{ssg_ac[10]}}, ssg_ac, 3'd0 });
        2'd1:    ssg_q15 = $signed({ {11{ssg_ac[10]}}, ssg_ac, 6'd0 });     // x 64
        default: ssg_q15 = $signed({ {10{ssg_ac[10]}}, ssg_ac, 7'd0 });     // x 128, builds 7-9's level
    endcase
end

wire signed [27:0] mix_fm  = $signed(ym_fm) * 28'sd512;
wire signed [27:0] mix_ssg = ssg_q15 * 28'sd512;
wire signed [27:0] pcm_sum = $signed({ {14{oki0_snd[13]}}, oki0_snd }) + $signed({ {14{oki1_snd[13]}}, oki1_snd });
wire signed [27:0] mix_pcm = pcm_sum * (cfg_oki_uncal ? 28'sd152 : 28'sd610);      // 4 x 38 / calibrated (V24)
wire signed [27:0] mix     = mix_fm + mix_ssg + mix_pcm;
wire signed [19:0] mix_q15 = mix[27:8];

always @(posedge clk) begin
    if (snd_rst)                    snd <= 16'sd0;
    else if (mix_q15 >  20'sd32767) snd <= 16'sd32767;
    else if (mix_q15 < -20'sd32768) snd <= 16'sh8000;         // -32768; 16'sd32768 overflows
    else                            snd <= mix_q15[15:0];
end

endmodule

`default_nettype wire
