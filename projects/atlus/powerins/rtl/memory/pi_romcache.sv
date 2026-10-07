//============================================================================
//  Power Instinct -- direct-mapped word cache for the 68000's program ROM
//
//  projects/vsystem/super_slams/rtl/memory/ss_romcache.sv, behaviour unchanged
//  (running on hardware there, 16384 entries, IDX_BITS 14 AW 19 -- the same
//  1 MB program ROM shape as this board).  Root CLAUDE.md 1.2 box 3.
//
//  WHY, on this board (docs/VALIDATION.md V1, V3, V4):
//    * the program ROM is in SDRAM behind pi_romarb; in simulation a pending
//      ROM read covered about a third of all clocks
//    * the boot RAM check has NO interrupts (MAME frames 1-228, pi_wr.lua), so
//      its length is CPU speed, and the simulated sequence ran 124 frames late
//  On OS93095 the EPROMs answer with no wait state.  This cache is a platform
//  mitigation, not hardware: TODO(HARDWAREIZE) T-DTACK-1 stays open until the
//  measured delay is gone.
//
//  Contract (from ss_romcache):
//    CPU side   c_rd level held until c_ack; c_ack one clock with c_q
//    memory     m_rd level held until m_ack; m_q valid with m_ack
//    hit        2 clocks; miss adds the memory transaction
//  The 68000 cannot write this region and reset invalidates (a walker, one
//  entry a clock -- Quartus 17.0 refuses an unrolled loop past 5000).
//============================================================================
`default_nettype none

module pi_romcache #(
    parameter int IDX_BITS = 14,
    parameter int AW       = 19          // word-address width, [AW:1]
) (
    input  wire            clk,
    input  wire            rst,

    input  wire [AW:1]     c_a,
    input  wire            c_rd,
    output reg             c_ack,
    output reg  [15:0]     c_q,

    output reg  [AW:1]     m_a,
    output reg             m_rd,
    input  wire            m_ack,
    input  wire [15:0]     m_q
);

  localparam int TAG_BITS = AW - IDX_BITS;

  reg                     v   [0:(1<<IDX_BITS)-1];
  reg [TAG_BITS-1:0]      tag [0:(1<<IDX_BITS)-1];
  reg [15:0]              dat [0:(1<<IDX_BITS)-1];

  wire [IDX_BITS-1:0] idx    = c_a[IDX_BITS:1];
  wire [TAG_BITS-1:0] cur_tg = c_a[AW:IDX_BITS+1];

  localparam [1:0] S_IDLE = 2'd0, S_LOOK = 2'd1, S_FILL = 2'd2, S_DONE = 2'd3;
  reg [1:0] st;

  reg                le_v;
  reg [TAG_BITS-1:0] le_tag;
  reg [15:0]         le_dat;
  reg [IDX_BITS-1:0] le_idx;
  reg [TAG_BITS-1:0] le_cur;

  reg [IDX_BITS-1:0] inv_a;
  reg                inv_run;

  // tag and dat in the RAM template: one memory per block, no reset branch, no
  // other logic.  Inside the FSM block below Quartus 17.0 did not infer them at
  // elaboration; it built them later from raw logic and added read-during-write
  // pass-through (276020 on tag_rtl_0 / dat_rtl_0, builds 3-8).  A ramstyle
  // no_rw_check attribute on the declarations changed nothing (build 8: the same
  // two warnings, RBF bit-identical to build 7) -- raw-logic inference does not
  // see HDL attributes.  The enables are the FSM's own conditions, unchanged:
  // read in S_IDLE on c_rd, write in S_FILL on m_ack, neither in reset or while
  // the valid bits are being cleared.  Same registers, same clocks.
  wire tab_run = !rst && !inv_run;
  wire tab_rd  = tab_run && st == S_IDLE && c_rd;
  wire tab_wr  = tab_run && st == S_FILL && m_ack;

  always @(posedge clk) begin
    if (tab_wr) tag[le_idx] <= le_cur;
    if (tab_rd) le_tag <= tag[idx];
  end

  always @(posedge clk) begin
    if (tab_wr) dat[le_idx] <= m_q;
    if (tab_rd) le_dat <= dat[idx];
  end

  always @(posedge clk) begin
    if (rst) begin
      st         <= S_IDLE;
      c_ack      <= 1'b0;
      c_q        <= 16'h0000;
      m_rd       <= 1'b0;
      m_a        <= {AW{1'b0}};
      inv_run    <= 1'b1;
      inv_a      <= {IDX_BITS{1'b0}};
    end else if (inv_run) begin
      c_ack     <= 1'b0;
      v[inv_a]  <= 1'b0;
      if (inv_a == {IDX_BITS{1'b1}}) inv_run <= 1'b0;
      else                           inv_a   <= inv_a + 1'b1;
    end else begin
      c_ack <= 1'b0;

      case (st)
        S_IDLE: begin
          if (c_rd) begin                  // le_tag / le_dat: tab_rd, above
            le_v   <= v[idx];
            le_idx <= idx;
            le_cur <= cur_tg;
            m_a    <= c_a;
            st     <= S_LOOK;
          end
        end

        S_LOOK: begin
          if (le_v && le_tag == le_cur) begin
            c_q   <= le_dat;
            c_ack <= 1'b1;
            st    <= S_DONE;
          end else begin
            m_rd <= 1'b1;
            st   <= S_FILL;
          end
        end

        S_FILL: begin
          if (m_ack) begin                 // tag / dat: tab_wr, above
            m_rd        <= 1'b0;
            v  [le_idx] <= 1'b1;
            c_q         <= m_q;
            c_ack       <= 1'b1;
            st          <= S_DONE;
          end
        end

        // c_rd is held until the CPU sees its acknowledge: wait for it to drop
        // or one read is acknowledged twice.
        S_DONE: if (!c_rd) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
