//============================================================================
//  Power Instinct -- SDRAM controller for the MiSTer SDRAM module
//
//  projects/dataeast/stadium_hero/rtl/memory/sh_sdram.sv with CLK_HZ and the
//  refresh interval changed for 48 MHz; the state machine is untouched (root
//  CLAUDE.md 1.3 / 1.5).  That file is itself from Power Spikes, running on
//  hardware.
//
//  Single port, one 16-bit word per transaction, auto-precharge, CAS latency 2.
//      req    held high until ack
//      ack    one clock, read data valid in the same clock
//      addr   WORD address
//
//  ---- timing at 48.000 MHz (tCK = 20.83 ns), -6A/-7 parts ----------------
//      tRCD >= 18 ns   ACTIVE registered in S_IDLE, READ in S_CMD: two clock
//                      periods between the sampling edges = 41.7 ns
//      tRC  >= 60 ns   the state machine is 7 clocks long
//      tREF = 64 ms / 8192 rows = 7.8 us = 375 clocks; 336 used (~10 % margin)
//      CL   = 2        read latched three states after S_CMD, see S_CL3
//
//  The CL latch argument below does not depend on the period as long as the
//  part's tAC is inside half a period, and SDRAM_CLK is shifted 180 degrees
//  (targets/mister/rtl/pll: outclk_1 -10417 ps, Super Slams' verified 48 MHz
//  PLL).  UNVERIFIED on this core's hardware until the first board run.
//
//  Byte writes are read-modify-write (the DE10-Nano does not honour DQM on
//  writes -- NA-1/NA-2 measured it).  Nothing on this board writes SDRAM after
//  the download, which writes whole words.
//============================================================================
`default_nettype none

module pi_sdram #(
    parameter int CLK_HZ      = 48_000_000,
    parameter int INIT_US     = 200,
    parameter int REFRESH_CLK = 336
) (
    input  wire        clk,
    input  wire        init,

    input  wire [24:0] addr,
    input  wire [15:0] din,
    output reg  [15:0] dout,
    input  wire        req,
    input  wire        we,
    input  wire [1:0]  ds,
    output reg         ack,

    output reg  [12:0] SDRAM_A,
    output reg  [1:0]  SDRAM_BA,
    inout  wire [15:0] SDRAM_DQ,
    output reg         SDRAM_DQML,
    output reg         SDRAM_DQMH,
    output wire        SDRAM_nCS,
    output reg         SDRAM_nWE,
    output reg         SDRAM_nRAS,
    output reg         SDRAM_nCAS,
    output reg         SDRAM_CKE
);

  localparam int INIT_CLKS = (CLK_HZ / 1_000_000) * INIT_US;

  localparam [2:0] CMD_NOP        = 3'b111,
                   CMD_ACTIVE     = 3'b011,
                   CMD_READ       = 3'b101,
                   CMD_WRITE      = 3'b100,
                   CMD_PRECHARGE  = 3'b010,
                   CMD_REFRESH    = 3'b001,
                   CMD_LOADMODE   = 3'b000;

  // burst length 1, sequential, CAS latency 2, single write
  localparam [12:0] MODE = 13'b000_0_00_010_0_000;

  assign SDRAM_nCS = 1'b0;

  reg        dq_oe;
  reg [15:0] dq_out;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

  wire [9:0]  a_col  = addr[9:0];
  wire [1:0]  a_bank = addr[11:10];
  wire [12:0] a_row  = addr[24:12];

  localparam S_INIT       = 4'd0,
             S_INIT_PRE   = 4'd1,
             S_INIT_REF1  = 4'd2,
             S_INIT_REF2  = 4'd3,
             S_INIT_MODE  = 4'd4,
             S_IDLE       = 4'd5,
             S_RCD        = 4'd7,
             S_CMD        = 4'd8,
             S_CL1        = 4'd9,
             S_CL2        = 4'd10,
             S_CL3        = 4'd11,
             S_REF_WAIT   = 4'd13;

  reg [3:0]  st;
  reg [15:0] timer;
  reg [9:0]  ref_cnt;
  reg        ref_due;
  reg        rd_pending;

  reg        rmw_rd;
  reg        rmw_wr;
  reg [15:0] rmw_data;

  wire       byte_wr = we & (ds != 2'b11);

  task automatic cmd(input [2:0] c);
    begin
      SDRAM_nRAS <= c[2];
      SDRAM_nCAS <= c[1];
      SDRAM_nWE  <= c[0];
    end
  endtask

  always @(posedge clk) begin
    cmd(CMD_NOP);
    ack   <= 1'b0;
    dq_oe <= 1'b0;

    if (ref_cnt == REFRESH_CLK[9:0]) begin
      ref_cnt <= 10'd0;
      ref_due <= 1'b1;
    end else
      ref_cnt <= ref_cnt + 10'd1;

    if (init) begin
      st         <= S_INIT;
      timer      <= INIT_CLKS[15:0];
      ref_cnt    <= 10'd0;
      ref_due    <= 1'b0;
      rd_pending <= 1'b0;
      rmw_rd     <= 1'b0;
      rmw_wr     <= 1'b0;
      SDRAM_CKE  <= 1'b1;
      SDRAM_DQML <= 1'b1;
      SDRAM_DQMH <= 1'b1;
      SDRAM_A    <= 13'd0;
      SDRAM_BA   <= 2'd0;
    end else begin
      case (st)
        S_INIT: begin
          if (timer == 0) st <= S_INIT_PRE;
          else            timer <= timer - 16'd1;
        end
        S_INIT_PRE: begin
          cmd(CMD_PRECHARGE);
          SDRAM_A[10] <= 1'b1;
          timer       <= 16'd4;
          st          <= S_INIT_REF1;
        end
        S_INIT_REF1: begin
          if (timer == 0) begin cmd(CMD_REFRESH); timer <= 16'd8; st <= S_INIT_REF2; end
          else timer <= timer - 16'd1;
        end
        S_INIT_REF2: begin
          if (timer == 0) begin cmd(CMD_REFRESH); timer <= 16'd8; st <= S_INIT_MODE; end
          else timer <= timer - 16'd1;
        end
        S_INIT_MODE: begin
          if (timer == 0) begin
            cmd(CMD_LOADMODE);
            SDRAM_A  <= MODE;
            SDRAM_BA <= 2'd0;
            timer    <= 16'd4;
            st       <= S_IDLE;
          end else timer <= timer - 16'd1;
        end

        S_IDLE: begin
          SDRAM_DQML <= 1'b1;
          SDRAM_DQMH <= 1'b1;
          if (timer != 0) begin
            timer <= timer - 16'd1;
          end else if (ref_due) begin
            ref_due <= 1'b0;
            cmd(CMD_REFRESH);
            timer   <= 16'd6;
            st      <= S_REF_WAIT;
          end else if (req) begin
            cmd(CMD_ACTIVE);
            SDRAM_A    <= a_row;
            SDRAM_BA   <= a_bank;
            rd_pending <= rmw_wr ? 1'b0 : (~we | byte_wr);
            rmw_rd     <= rmw_wr ? 1'b0 : byte_wr;
            st         <= S_RCD;
          end
        end

        S_REF_WAIT: begin
          if (timer == 0) st <= S_IDLE;
          else            timer <= timer - 16'd1;
        end

        S_RCD: st <= S_CMD;

        S_CMD: begin
          SDRAM_A <= {2'b00, 1'b1, a_col};
          if (rd_pending) begin
            cmd(CMD_READ);
            SDRAM_DQML <= 1'b0;
            SDRAM_DQMH <= 1'b0;
            st         <= S_CL1;
          end else begin
            cmd(CMD_WRITE);
            dq_oe      <= 1'b1;
            dq_out     <= rmw_wr ? rmw_data : din;
            SDRAM_DQML <= rmw_wr ? 1'b0 : ~ds[0];
            SDRAM_DQMH <= rmw_wr ? 1'b0 : ~ds[1];
            rmw_wr     <= 1'b0;
            ack        <= 1'b1;
            timer      <= 16'd2;
            st         <= S_IDLE;
          end
        end

        // READ registered at N, on the pins N..N+1, sampled by the part at
        // N+1.5 (180 degree SDRAM_CLK); CL=2 data from N+3.5+tAC to N+4.5+tOH;
        // the only core edge inside that window is N+4 = S_CL3.
        S_CL1: st <= S_CL2;
        S_CL2: st <= S_CL3;
        S_CL3: begin
          if (rmw_rd) begin
            rmw_data <= {ds[1] ? din[15:8] : SDRAM_DQ[15:8],
                         ds[0] ? din[7:0]  : SDRAM_DQ[7:0]};
            rmw_rd   <= 1'b0;
            rmw_wr   <= 1'b1;
          end else begin
            dout <= SDRAM_DQ;
            ack  <= 1'b1;
          end
          timer <= 16'd1;
          st    <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
