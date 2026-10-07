//============================================================================
//  Power Instinct -- ioctl byte stream -> dl_* words
//
//  Platform transport: integration/, not rtl/ (root CLAUDE.md 4).
//  projects/dataeast/stadium_hero/integration/sh_download.sv, unchanged in
//  behaviour -- it is running on hardware, and before it Power Spikes' and
//  NA-1/NA-2's.
//
//      word W = { byte 2W, byte 2W+1 }     (rtl/pi_rommap.svh)
//
//  THE POWER-UP VALUE OF `busy` IS NOT OPTIONAL.  ioctl_wait reaches the HPS
//  as io_wait; a busy that powers up set wedges the HPS before the core does
//  anything (inherited from na2_membus).
//============================================================================
`default_nettype none

module pi_download (
    input  wire        clk,
    input  wire        rst,

    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    input  wire [15:0] ioctl_index,
    output wire        ioctl_wait,

    output reg  [24:0] dl_addr,
    output reg  [15:0] dl_data,
    output reg         dl_req = 1'b0,
    input  wire        dl_ack,
    output wire        dl_active
);

  // index 0 is the ROM image; 254 is the DIP block and must not reach it
  wire is_rom = (ioctl_index == 16'd0);

  reg [7:0] hold;
  reg       busy = 1'b0;

  assign ioctl_wait = busy;
  assign dl_active  = (ioctl_download & is_rom) | busy;

  always @(posedge clk) begin
    if (rst) begin
      dl_req <= 1'b0;
      busy   <= 1'b0;
      hold   <= 8'd0;
    end else begin
      if (dl_req && dl_ack) begin
        dl_req <= 1'b0;
        busy   <= 1'b0;
      end

      if (ioctl_wr && is_rom) begin
        if (!ioctl_addr[0]) begin
          hold <= ioctl_dout;
        end else begin
          dl_addr <= ioctl_addr[25:1];
          dl_data <= {hold, ioctl_dout};
          dl_req  <= 1'b1;
          busy    <= 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
