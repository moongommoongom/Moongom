// Single-client shim from savestate's blob port to a stock psram controller
module psram_blob (
    input wire clk,

    input wire req,
    input wire we,
    input wire [21:0] addr,
    input wire [15:0] din,
    input wire ub,
    input wire lb,
    output reg [15:0] dout = 0,
    output reg done = 0,

    // MSU-1 ring port (clk toggle handshake), low priority, served by the psram controller when the blob port is idle
    input wire m_req_tgl,
    input wire m_we,
    input wire m_bank,
    input wire [21:0] m_addr,
    input wire [15:0] m_wdata,
    output wire m_ack_tgl,
    output wire [15:0] m_rdata,

    // PSRAM signals
    output wire [21:16] cram_a,
    inout wire [15:0] cram_dq,
    input wire cram_wait,
    output wire cram_clk,
    output wire cram_adv_n,
    output wire cram_cre,
    output wire cram_ce0_n,
    output wire cram_ce1_n,
    output wire cram_oe_n,
    output wire cram_we_n,
    output wire cram_ub_n,
    output wire cram_lb_n
);

  reg we_lat = 0;
  reg ub_lat = 1;
  reg lb_lat = 1;
  reg [21:0] addr_lat = 0;
  reg [15:0] din_lat = 0;

  reg write_en = 0;
  reg read_en = 0;
  wire busy;
  wire snes_acc;
  wire [15:0] data_out;

  localparam ST_IDLE = 2'd0;
  localparam ST_ACCEPT = 2'd1;
  localparam ST_WAIT = 2'd2;

  reg [1:0] state = ST_IDLE;

  always @(posedge clk) begin
    done <= 0;

    case (state)
      ST_IDLE: begin
        if (req) begin
          we_lat   <= we;
          addr_lat <= addr;
          din_lat  <= din;
          ub_lat   <= ub;
          lb_lat   <= lb;
          write_en <= we;
          read_en  <= ~we;
          state    <= ST_ACCEPT;
        end
      end

      ST_ACCEPT: begin
        // wait for the controller to take the request (busy alone may come from an MSU-1 ring access)
        if (snes_acc) begin
          write_en <= 0;
          read_en  <= 0;
          state    <= ST_WAIT;
        end
      end

      ST_WAIT: begin
        if (~busy) begin
          if (~we_lat) begin
            dout <= data_out;
          end
          done  <= 1;
          state <= ST_IDLE;
        end
      end

      default: state <= ST_IDLE;
    endcase
  end

  psram #(
      .CLOCK_SPEED(85.9),
      .MSU_FORCE_EN(0)
  ) ram (
      .clk(clk),

      .bank_sel(1'b0),
      .addr(addr_lat),

      .write_en(write_en),
      .data_in(din_lat),
      .write_high_byte(ub_lat),
      .write_low_byte(lb_lat),

      .read_en(read_en),
      .read_avail(),
      .data_out(data_out),

      .busy(busy),
      .snes_acc(snes_acc),

      .m_req_tgl(m_req_tgl),
      .m_we(m_we),
      .m_bank(m_bank),
      .m_addr(m_addr),
      .m_wdata(m_wdata),
      .m_ack_tgl(m_ack_tgl),
      .m_rdata(m_rdata),

      .cram_a(cram_a),
      .cram_dq(cram_dq),
      .cram_wait(cram_wait),
      .cram_clk(cram_clk),
      .cram_adv_n(cram_adv_n),
      .cram_cre(cram_cre),
      .cram_ce0_n(cram_ce0_n),
      .cram_ce1_n(cram_ce1_n),
      .cram_oe_n(cram_oe_n),
      .cram_we_n(cram_we_n),
      .cram_ub_n(cram_ub_n),
      .cram_lb_n(cram_lb_n)
  );

endmodule
