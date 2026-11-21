// ARAM on the Pocket's async SRAM (0.8.5 chip builds).
// Same engine as the save state core's sram_ctrl/sram (agg23's openfpga-litex async SRAM controller, MIT License,
// Copyright (c) 2023 Adam Gastineau), with the data bus split into out/oe/in because core_top owns the sram_dq pins.
// Level interface like psram.sv: read_en / write_en are held; reads repeat and data_out follows the address.
module sram_ctrl_split #(
    parameter CLOCK_SPEED_MHZ = 85.9,
    parameter MIN_OP_CYCLE_TIME_NANO_SEC = 55
) (
    input wire clk,

    input wire [14:0] addr,

    input wire write_en,
    input wire [15:0] data_in,
    input wire write_high_byte,
    input wire write_low_byte,

    input wire read_en,
    output reg [15:0] data_out,

    // Async SRAM interface (core_top drives sram_dq = sram_doe ? sram_do : Z)
    output reg  [16:0] sram_a,
    output reg  [15:0] sram_do,
    output reg         sram_doe,
    input  wire [15:0] sram_di,
    output reg         sram_oe_n,
    output reg         sram_we_n,
    output reg         sram_ub_n,
    output reg         sram_lb_n
);
  function integer rtoi(input integer x);
    return x;
  endfunction

  `define SRAM_SPLIT_CEIL(x) ((rtoi(x) > x) ? rtoi(x) : rtoi(x) + 1)

  localparam CLOCK_PERIOD_NANO_SEC = 1000.0 / CLOCK_SPEED_MHZ;
  localparam CYCLES_PER_OP = `SRAM_SPLIT_CEIL(MIN_OP_CYCLE_TIME_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  initial begin
    data_out = 16'h0;
    sram_a = 17'h0;
    sram_do = 16'h0;
    sram_doe = 1'b0;
    sram_oe_n = 1'b1;
    sram_we_n = 1'b1;
    sram_ub_n = 1'b1;
    sram_lb_n = 1'b1;
  end

  reg [3:0] wait_counter = 0;
  reg state = 0;  // 0: idle (ready), 1: operation in progress

  wire [1:0] mask = write_en ? {write_high_byte, write_low_byte} : 2'b11;

  always @(posedge clk) begin
    case (state)
      1'b0: begin
        // standby: both byte lanes off
        sram_ub_n <= 1'b1;
        sram_lb_n <= 1'b1;

        if (write_en) begin
          state <= 1'b1;
          wait_counter <= CYCLES_PER_OP;
          sram_a <= {2'b0, addr};
          sram_do <= data_in;
          sram_doe <= 1'b1;
          sram_oe_n <= 1'b1;
          sram_we_n <= 1'b0;
          {sram_ub_n, sram_lb_n} <= ~mask;
        end else if (read_en) begin
          state <= 1'b1;
          wait_counter <= CYCLES_PER_OP;
          sram_a <= {2'b0, addr};
          sram_doe <= 1'b0;
          sram_oe_n <= 1'b0;
          sram_we_n <= 1'b1;
          {sram_ub_n, sram_lb_n} <= ~mask;
        end
      end
      1'b1: begin
        if (wait_counter > 0) begin
          wait_counter <= wait_counter - 4'h1;
        end else begin
          state <= 1'b0;
          if (~sram_doe) data_out <= sram_di;  // completed read
        end
      end
    endcase
  end

  `undef SRAM_SPLIT_CEIL
endmodule
