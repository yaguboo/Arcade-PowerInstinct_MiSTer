//============================================================================
//  Power Instinct / Gouketsuji Ichizoku (Atlus 1993, NMK OS93095) for MiSTer
//
//  Wires rtl/pi_top.sv to the MiSTer framework: PLL, hps_io, download, SDRAM,
//  video.  hps_io / ioctl / MRA stay on this side (root CLAUDE.md 4).
//
//  Structure from projects/dataeast/stadium_hero/targets/mister/StadiumHero.sv
//  (running on hardware); the 48 MHz PLL from projects/vsystem/super_slams.
//
//  FIRST BUILD: 68000 + map + PROM timing + text + BG + 22.u81 mixer.  No
//  sprites and no sound yet (docs/PORTING_PLAN.md 9.2).  The expected first
//  picture is the boot RAM check screen.
//
//  Horizontal game (MAME ROT0), so no MISTER_FB.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE, DDRAM_RD} = 0;

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

assign VGA_F1         = 0;
assign VGA_SCALER     = 0;
assign VGA_DISABLE    = 0;
assign HDMI_FREEZE    = 0;
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

// Mono PCB (LA4460 amp, nmk16.cpp:5754).  Sound is the second build.
assign AUDIO_S   = 1;
assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download | pll_alive;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"PowerIns;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"DIP;",
	"-;",
	// docs/OSD_POLICY.md 2.1: `On` first, so status 0 is the default.
	"O[12],Pause when OSD open,On,Off;",
	// SYSTEM bit 2 (service coin) and bit 5 (test switch, PORT_SERVICE_NO_TOGGLE)
	// are cabinet switches, not DIPs: OSD items, never on the pad (OSD_POLICY 3).
	"O[13],Service,Off,On;",
	"O[15],Test switch,Off,On;",
	"-;",
	"P1,Debug;",
	"P1O[20],Background layer,On,Off;",
	"P1O[21],Text layer,On,Off;",
	"P1O[22],Sprite layer,On,Off;",
	"P1O[14],Pause CPU,Off,On;",
	// Sound mix (rtl/sound/pi_sound.sv).  First entry = the calibrated mix;
	// x128 / MAME gain only = builds 7-9, for comparison by ear.
	"P1O[17:16],SSG level,Calibrated x40,x64,x128;",
	"P1O[18],OKI level,Calibrated x4.0,MAME gain only;",
	"-;",
	"R[0],Reset;",
	// Four buttons a player, INPUT_PORTS_START(powerins) nmk16.cpp:3386-3403.
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause;",
	"jn,A,B,X,Y,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire [21:0]  gamma_bus;
wire [127:0] status;
wire  [1:0]  buttons;

wire         ioctl_download;
wire         ioctl_wr;
wire [26:0]  ioctl_addr;
wire  [7:0]  ioctl_dout;
wire [15:0]  ioctl_index;
wire         ioctl_wait;

wire [31:0]  joystick_0, joystick_1;
wire [10:0]  ps2_key;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(),
	.joystick_3(),

	.ps2_key(ps2_key),

	// hps_io inputs with no default float when left open (NA-1/NA-2 lost a
	// session to an open ioctl_wait).  Tie every one off.
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0),
	.ps2_kbd_clk_in(1'b0),
	.ps2_kbd_data_in(1'b0),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b0),
	.ps2_mouse_data_in(1'b0),
	.video_rotated(1'b0),
	.new_vmode(1'b0),
	.status_in({96'd0, mra_status[31:1], 1'b0}),
	.status_set(mra_status_set),
	.info_req(1'b0),
	.info(8'd0),
	.sd_lba('{default:32'd0}),
	.sd_blk_cnt('{default:6'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{default:8'd0}),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0)
);

/////////////////////   .MRA-SUPPLIED OSD DEFAULTS   ////////////////////
// <rom index="1"><part>hh mm ll [xx]</part></rom>: status[23:16] [15:8] [7:0]
// [31:24].  Mechanism from NA-1/NA-2 via Power Spikes / Stadium Hero.
reg [31:0] mra_status      = 32'd0;
reg        mra_status_seen = 1'b0;
reg        ioctl_dl_d      = 1'b0;
reg        mra_status_done = 1'b0;
reg        mra_status_set  = 1'b0;

always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd1) && !ioctl_addr[26:2]) begin
		case (ioctl_addr[1:0])
			2'd0: mra_status[23:16] <= ioctl_dout;
			2'd1: mra_status[15:8]  <= ioctl_dout;
			2'd2: begin mra_status[7:0] <= ioctl_dout; mra_status_seen <= 1'b1; end
			2'd3: mra_status[31:24] <= ioctl_dout;
		endcase
	end
end

always @(posedge clk_sys) begin
	ioctl_dl_d     <= ioctl_download;
	mra_status_set <= 1'b0;
	if (ioctl_dl_d && !ioctl_download && mra_status_seen && !mra_status_done) begin
		mra_status_set  <= 1'b1;
		mra_status_done <= 1'b1;
	end
end

///////////////////////   CLOCKS   ///////////////////////////////
// 48.000 MHz (rtl/pi_cen.sv).  outclk_1 = 48 MHz at -10417 ps (180 degrees)
// for SDRAM_CLK; outclk_2 = 100 MHz exists to keep the solver's VCO where
// Super Slams verified it, and is loaded by pll_alive so it is not deleted.
// build.sh runs tools/check_pll.py against the fitter's PROGRAMMED counters.
wire clk_sys, clk_sdram, clk_aux, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_aux),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

reg [26:0] aux_cnt = 27'd0;
always @(posedge clk_aux) aux_cnt <= aux_cnt + 27'd1;
reg [2:0] aux_sync = 3'd0;
always @(posedge clk_sys) aux_sync <= {aux_sync[1:0], aux_cnt[26]};
wire pll_alive = aux_sync[2];

wire rst_sys = RESET | status[0] | buttons[1] | ~pll_locked;
wire rst_mem = ~pll_locked;

///////////////////////   INPUT   ////////////////////////////////
// INPUT_PORTS_START(powerins), nmk16.cpp:3375-3464.  All active low.
// J1 bit order: 0 R  1 L  2 D  3 U  4 B1  5 B2  6 B3  7 B4  8 Start  9 Coin  10 Pause
// P1_P2 bit order is the same R L D U B1..B4, so a player byte is j[7:0].
wire [31:0] j1 = joystick_0;
wire [31:0] j2 = joystick_1;

wire [15:0] joy_in = ~{ j2[7:0], j1[7:0] };
wire [7:0]  sys_in = ~{ 2'b00,
                        status[15],   // 5 test switch
                        j2[8],        // 4 start 2
                        j1[8],        // 3 start 1
                        status[13],   // 2 service coin
                        j2[9],        // 1 coin 2
                        j1[9] };      // 0 coin 1

// Pause: pad toggle + OSD auto-pause.  Released on download (OSD_POLICY 2.2).
wire pause_btn = j1[10] | j2[10];
reg  pause_btn_d, pause_latch;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (ioctl_download)                pause_latch <= 1'b0;
	else if (~pause_btn_d & pause_btn) pause_latch <= ~pause_latch;
end
wire pause_core = status[14] | pause_latch | (OSD_STATUS & ~status[12]);

// { DSW2, DSW1 }.  Power-on value is the driver's defaults: DSW1 0xFF, DSW2 0xFB
// -- Demo Sounds ON is bit 2 CLEAR (nmk16.cpp:3448).  The .mra overrides.
reg [15:0] mra_dsw = 16'hFBFF;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1]) begin
		if (!ioctl_addr[0]) mra_dsw[7:0]  <= ioctl_dout;
		else                mra_dsw[15:8] <= ioctl_dout;
	end
end

///////////////////////   THE BOARD   ////////////////////////////

wire [24:0] mem_addr;
wire [15:0] mem_din, mem_dout;
wire        mem_req, mem_we, mem_ack;
wire  [1:0] mem_ds;

wire        dl_active, dl_req, dl_ack;
wire [24:0] dl_addr;
wire [15:0] dl_data;

wire [7:0]  vid_r, vid_g, vid_b;
wire        hs, vs, hblank, vblank, ce_pix;
wire signed [15:0] snd_l, snd_r;

pi_top u_board
(
	.clk            (clk_sys),
	.rst            (rst_sys),
	.mem_rst        (rst_mem),
	.pause          (pause_core),

	.mem_addr       (mem_addr),
	.mem_din        (mem_din),
	.mem_dout       (mem_dout),
	.mem_req        (mem_req),
	.mem_we         (mem_we),
	.mem_ds         (mem_ds),
	.mem_ack        (mem_ack),

	.dl_active      (dl_active),
	.dl_addr        (dl_addr),
	.dl_data        (dl_data),
	.dl_req         (dl_req),
	.dl_ack         (dl_ack),

	.sys_in         (sys_in),
	.joy_in         (joy_in),
	.dsw            (mra_dsw),
	.gfx_en         (~{status[22], status[21], status[20]}),
	.cfg_ssg_level  (status[17:16]),
	.cfg_oki_uncal  (status[18]),

	.red            (vid_r),
	.green          (vid_g),
	.blue           (vid_b),
	.hsync          (hs),
	.vsync          (vs),
	.hblank         (hblank),
	.vblank         (vblank),
	.ce_pix         (ce_pix),

	.snd_l          (snd_l),
	.snd_r          (snd_r),

	.dbg_halted_n   (),
	.dbg_late_tx    (),
	.dbg_late_bg    (),
	.dbg_late_spr   (),
	.dbg_cpu_waiting()
);

///////////////////////   DOWNLOAD   /////////////////////////////

pi_download u_download
(
	.clk            (clk_sys),
	.rst            (rst_mem),
	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_index    (ioctl_index),
	.ioctl_wait     (ioctl_wait),
	.dl_addr        (dl_addr),
	.dl_data        (dl_data),
	.dl_req         (dl_req),
	.dl_ack         (dl_ack),
	.dl_active      (dl_active)
);

///////////////////////   SDRAM   ////////////////////////////////

reg  [3:0] sdram_init_cnt = 0;
wire       sdram_init = ~sdram_init_cnt[3];
always @(posedge clk_sys) begin
	if (!pll_locked)     sdram_init_cnt <= 0;
	else if (sdram_init) sdram_init_cnt <= sdram_init_cnt + 1'd1;
end

pi_sdram #(.CLK_HZ(48_000_000), .REFRESH_CLK(336)) u_sdram
(
	.clk        (clk_sys),
	.init       (sdram_init),
	.addr       (mem_addr),
	.din        (mem_din),
	.dout       (mem_dout),
	.req        (mem_req),
	.we         (mem_we),
	.ds         (mem_ds),
	.ack        (mem_ack),
	.SDRAM_A    (SDRAM_A),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_nCS  (SDRAM_nCS),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_CKE  (SDRAM_CKE)
);

///////////////////////   VIDEO   ////////////////////////////////

wire [2:0] fx = status[4:2];

// 320 visible pixels (20.u54 entries 0x3E-0xDD).
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in({vid_r, vid_g, vid_b}),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),
	.fx(fx)
);

endmodule
