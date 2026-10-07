//============================================================================
//  Power Instinct -- 68000 wrapper around fx68k
//
//  From projects/dataeast/stadium_hero/rtl/cpu/sh_m68k.sv, which is from
//  Power Spikes and NA-1/NA-2 before it -- verified on hardware in four lanes
//  (root CLAUDE.md 1.3).  The two-phase enable, the DTACK handshake and the
//  din_hold are unchanged.
//
//  Different here:
//    * CLK_DIV = 4: 48 MHz / 4 = 12.000 MHz, XTAL(12'000'000) nmk16.cpp:5735.
//    * SLIP removed.  Stadium Hero needed it because its game reads the
//      raster as a random number; whether this game does is T-CLK-1.
//    * iack_stb is consumed: the board's interrupt-pending flip-flop clears on
//      the acknowledge cycle (HYPOTHESIS H-IRQ-1, docs/TODO_HARDWARE.md).
//
//  Every interrupt is autovectored (VPAn during IACK).  ROM_MEASURED: level 4
//  -> 0x0043B8, levels 1,2,3,5,6,7 -> 0x0001A0 which is RTE.
//
//  fx68k (third_party/cpu/fx68k) (c) 2018,2021 Jorge Cwik, GPLv3, carrying the
//  factory's additive dbg_d7 port.
//============================================================================
`default_nettype none

module pi_m68k #(
    parameter int CLK_DIV = 4
) (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high
    input  wire        cpu_rst,      // hold in reset (ROM download)
    input  wire        ce_en,        // pause / download stall

    output wire [23:1] addr,
    output wire [15:0] dout,
    input  wire [15:0] din,
    output wire        rd,
    output wire        wr,
    output wire        uds_n,
    output wire        lds_n,
    input  wire        ack,

    input  wire [2:0]  ipl_n,

    output wire [2:0]  fc,
    output wire        iack_stb,     // high for the whole IACK bus cycle
    output wire        halted_n,
    output wire        dbg_phi1
);

  // Widths by bit-select of an int parameter, the form sh_m68k's SLIP[12:0]
  // already put through Quartus 17.0.  A parameter-named size cast DW'(x) is
  // legal SystemVerilog but has not been through this Quartus here.
  localparam int DW     = $clog2(CLK_DIV);
  localparam int HALF_I = CLK_DIV / 2;
  localparam int LAST_I = CLK_DIV - 1;
  reg [DW-1:0] div;
  wire en_phi1 = ce_en && (div == {DW{1'b0}});
  wire en_phi2 = ce_en && (div == HALF_I[DW-1:0]);

  always @(posedge clk) begin
    if (rst)        div <= '0;
    else if (ce_en) div <= (div == LAST_I[DW-1:0]) ? '0 : div + 1'b1;
  end

  assign dbg_phi1 = en_phi1;

  wire        cpu_as_n, cpu_lds_n, cpu_uds_n, cpu_rw_n;
  wire [15:0] cpu_dout;
  wire [23:1] cpu_addr;
  wire        fc0, fc1, fc2;
  wire        vma_n, e_clk;
  wire [31:0] d7_unused;

  reg         dtack_n;
  reg  [15:0] din_hold;

  wire iack  = (fc2 & fc1 & fc0);
  wire vpa_n = ~(iack & ~cpu_as_n);

  fx68k u_fx68k (
      .clk       (clk),
      .HALTn     (1'b1),
      .extReset  (rst | cpu_rst),
      .pwrUp     (rst),
      .enPhi1    (en_phi1),
      .enPhi2    (en_phi2),

      .dbg_d7    (d7_unused),
      .eRWn      (cpu_rw_n),
      .ASn       (cpu_as_n),
      .LDSn      (cpu_lds_n),
      .UDSn      (cpu_uds_n),
      .E         (e_clk),
      .VMAn      (vma_n),

      .FC0       (fc0),
      .FC1       (fc1),
      .FC2       (fc2),
      .BGn       (),
      .oRESETn   (),
      .oHALTEDn  (halted_n),

      .DTACKn    (dtack_n),
      .VPAn      (vpa_n),
      .BERRn     (1'b1),
      .BRn       (1'b1),
      .BGACKn    (1'b1),

      .IPL0n     (ipl_n[0]),
      .IPL1n     (ipl_n[1]),
      .IPL2n     (ipl_n[2]),

      .iEdb      (din_hold),
      .oEdb      (cpu_dout),
      .eab       (cpu_addr)
  );

  wire cyc = ~cpu_as_n & ~(cpu_lds_n & cpu_uds_n) & ~iack;
  reg  done;

  // fx68k samples its data bus on a later enabled Phi2 edge than the one where
  // ack is high, so the acknowledged word is held until the next read.
  always @(posedge clk) begin
    if (rst | cpu_rst)  din_hold <= 16'hFFFF;
    else if (ack && rd) din_hold <= din;
  end

  always @(posedge clk) begin
    if (rst | cpu_rst) begin
      done    <= 1'b0;
      dtack_n <= 1'b1;
    end else if (!cyc) begin
      done    <= 1'b0;
      dtack_n <= 1'b1;
    end else if (ack) begin
      done    <= 1'b1;
      dtack_n <= 1'b0;
    end
  end

  assign rd       = cyc & ~done &  cpu_rw_n;
  assign wr       = cyc & ~done & ~cpu_rw_n;
  assign addr     = cpu_addr;
  assign dout     = cpu_dout;
  assign uds_n    = cpu_uds_n;
  assign lds_n    = cpu_lds_n;
  assign fc       = {fc2, fc1, fc0};
  assign iack_stb = iack & ~cpu_as_n;

endmodule

`default_nettype wire
