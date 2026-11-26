// MD+ for Analogue Pocket - asynchronous PSRAM controller (address/data muxed CellularRAM)
// One chip = two 64Mbit dies (ce0/ce1). Word address [22:0]: bit 22 selects the die.
// Three request ports, priority A > B > C. Requests are level: hold req until the ack pulse.
// Clocked by clk_74a (13.47 ns). Async mode timings: tAA 70 ns, tWP 45 ns.

module mdp_psram (
    input  wire        clk,
    input  wire        reset,

    input  wire        a_req,
    input  wire        a_we,
    input  wire [22:0] a_addr,
    input  wire [15:0] a_wdata,
    output reg         a_ack = 0,
    output reg  [15:0] a_rdata = 0,

    input  wire        b_req,
    input  wire        b_we,
    input  wire [22:0] b_addr,
    input  wire [15:0] b_wdata,
    output reg         b_ack = 0,
    output reg  [15:0] b_rdata = 0,

    input  wire        c_req,
    input  wire        c_we,
    input  wire [22:0] c_addr,
    input  wire [15:0] c_wdata,
    output reg         c_ack = 0,
    output reg  [15:0] c_rdata = 0,

    // chip pins
    output reg  [21:16] cram_a = 0,
    inout  wire [15:0]  cram_dq,
    input  wire         cram_wait,
    output wire         cram_clk,
    output reg          cram_adv_n = 1,
    output wire         cram_cre,
    output reg          cram_ce0_n = 1,
    output reg          cram_ce1_n = 1,
    output reg          cram_oe_n = 1,
    output reg          cram_we_n = 1,
    output wire         cram_ub_n,
    output wire         cram_lb_n
);

assign cram_clk  = 0;
assign cram_cre  = 0;
assign cram_ub_n = 0;
assign cram_lb_n = 0;

reg        dq_oe = 0;
reg [15:0] dq_out = 0;
assign cram_dq = dq_oe ? dq_out : 16'hZZZZ;

reg [15:0] dq_in;
always @(posedge clk) dq_in <= cram_dq;

localparam READ_WAIT  = 4'd7;   // cycles with OE low before sampling (>= 70 ns from ADV)
localparam WRITE_WAIT = 4'd5;   // cycles with WE low (>= 45 ns)

reg [3:0]  st = 0;
reg [3:0]  cnt = 0;
reg [1:0]  cur_port = 0;       // 0 = A, 1 = B, 2 = C
reg        cur_we = 0;
reg [15:0] cur_wdata = 0;

localparam S_IDLE  = 0,
           S_ADDR  = 1,
           S_HOLD  = 2,
           S_RWAIT = 3,
           S_RDONE = 4,
           S_WWAIT = 5,
           S_WEND  = 6,
           S_GAP   = 7;

wire [22:0] sel_addr = a_req ? a_addr : b_req ? b_addr : c_addr;

always @(posedge clk) begin
    a_ack <= 0;
    b_ack <= 0;
    c_ack <= 0;

    if (reset) begin
        st <= S_IDLE;
        cram_ce0_n <= 1;
        cram_ce1_n <= 1;
        cram_oe_n <= 1;
        cram_we_n <= 1;
        cram_adv_n <= 1;
        dq_oe <= 0;
    end else begin
        case (st)
        S_IDLE: begin
            if (a_req | b_req | c_req) begin
                cur_port  <= a_req ? 2'd0 : b_req ? 2'd1 : 2'd2;
                cur_we    <= a_req ? a_we : b_req ? b_we : c_we;
                cur_wdata <= a_req ? a_wdata : b_req ? b_wdata : c_wdata;
                cram_a     <= sel_addr[21:16];
                dq_out     <= sel_addr[15:0];
                dq_oe      <= 1;
                cram_ce0_n <= sel_addr[22];
                cram_ce1_n <= ~sel_addr[22];
                cram_adv_n <= 0;
                st <= S_ADDR;
            end
        end

        S_ADDR: begin
            cram_adv_n <= 1;          // address latched on ADV rising edge
            st <= S_HOLD;
        end

        S_HOLD: begin
            cnt <= 0;
            if (cur_we) begin
                dq_out <= cur_wdata;
                cram_we_n <= 0;
                st <= S_WWAIT;
            end else begin
                dq_oe <= 0;
                cram_oe_n <= 0;
                st <= S_RWAIT;
            end
        end

        S_RWAIT: begin
            cnt <= cnt + 1'd1;
            if (cnt == READ_WAIT) st <= S_RDONE;
        end

        S_RDONE: begin
            case (cur_port)
                2'd0: begin a_rdata <= dq_in; a_ack <= 1; end
                2'd1: begin b_rdata <= dq_in; b_ack <= 1; end
                default: begin c_rdata <= dq_in; c_ack <= 1; end
            endcase
            cram_oe_n  <= 1;
            cram_ce0_n <= 1;
            cram_ce1_n <= 1;
            st <= S_GAP;
        end

        S_WWAIT: begin
            cnt <= cnt + 1'd1;
            if (cnt == WRITE_WAIT) begin
                cram_we_n <= 1;
                st <= S_WEND;
            end
        end

        S_WEND: begin
            dq_oe <= 0;
            cram_ce0_n <= 1;
            cram_ce1_n <= 1;
            case (cur_port)
                2'd0: a_ack <= 1;
                2'd1: b_ack <= 1;
                default: c_ack <= 1;
            endcase
            st <= S_GAP;
        end

        S_GAP: st <= S_IDLE;

        default: st <= S_IDLE;
        endcase
    end
end

endmodule
