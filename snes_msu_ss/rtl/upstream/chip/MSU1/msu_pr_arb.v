// Two-client arbiter for the MSU PSRAM port (ARAM chip, toggle handshake).
// Each client holds req/we/addr/wd until it sees a one-cycle done pulse (read data valid with it).
// Writes are served before reads (the write queues of the stream caches must never overflow).
// A write may carry a second word (two = 1: wd at addr, wd2 at addr+1, one handshake): with word pairs the
// queues drain faster than the bridge fills them, so the gaps between pairs leave room for playback reads.
module msu_pr_arb (
	input             clk,
	input             reset,

	input             c0_req,
	input             c0_we,
	input      [21:0] c0_addr,
	input      [15:0] c0_wd,
	input             c0_two,
	input      [15:0] c0_wd2,
	output reg        c0_done,
	output reg [15:0] c0_rd,

	input             c1_req,
	input             c1_we,
	input      [21:0] c1_addr,
	input      [15:0] c1_wd,
	input             c1_two,
	input      [15:0] c1_wd2,
	output reg        c1_done,
	output reg [15:0] c1_rd,

	output reg        pr_req_tgl,
	output reg        pr_we,
	output reg [21:0] pr_addr,
	output reg [15:0] pr_wdata,
	output reg        pr_two,
	output reg [15:0] pr_wdata2,
	input             pr_ack_tgl,
	input      [15:0] pr_rdata
);

initial begin pr_req_tgl = 0; pr_we = 0; pr_addr = 0; pr_wdata = 0; pr_two = 0; pr_wdata2 = 0; c0_done = 0; c1_done = 0; c0_rd = 0; c1_rd = 0; end

localparam [1:0] A_SYNC = 2'd0, A_IDLE = 2'd1, A_BUSY = 2'd2, A_GAP = 2'd3;
reg [1:0] st = A_SYNC;
reg       ack1 = 0, ack2 = 0;
reg       g1 = 0;            // the client that owns the current access
reg       last1 = 0;         // round robin

wire pick1 = c1_req && (!c0_req || (c1_we && !c0_we) || ((c1_we == c0_we) && !last1));

always @(posedge clk) begin
	ack1    <= pr_ack_tgl;
	ack2    <= ack1;
	c0_done <= 1'b0;
	c1_done <= 1'b0;

	if (reset) st <= A_SYNC;
	else case (st)
		A_SYNC: if (ack2 == pr_req_tgl) st <= A_IDLE;

		A_IDLE:
			if (c0_req || c1_req) begin
				g1         <= pick1;
				last1      <= pick1;
				pr_we      <= pick1 ? c1_we   : c0_we;
				pr_addr    <= pick1 ? c1_addr : c0_addr;
				pr_wdata   <= pick1 ? c1_wd   : c0_wd;
				pr_two     <= pick1 ? (c1_we & c1_two) : (c0_we & c0_two);
				pr_wdata2  <= pick1 ? c1_wd2  : c0_wd2;
				pr_req_tgl <= ~pr_req_tgl;
				st         <= A_BUSY;
			end

		A_BUSY:
			if (ack2 == pr_req_tgl) begin
				if (g1) begin c1_rd <= pr_rdata; c1_done <= 1'b1; end
				else    begin c0_rd <= pr_rdata; c0_done <= 1'b1; end
				st <= A_GAP;
			end

		A_GAP: st <= A_IDLE;
	endcase
end

endmodule

// ---------------------------------------------------------------------------
// Three-client arbiter for the ARAM-chip PSRAM port: c0 music ring, c1 voice ring (bank 0),
// c2 MSU data store (own bank).  Same handshake as msu_pr_arb.  Writes first, then round robin.
// ---------------------------------------------------------------------------
module msu_pr_arb3 (
	input             clk,
	input             reset,

	input             c0_req,
	input             c0_we,
	input      [21:0] c0_addr,
	input      [15:0] c0_wd,
	output reg        c0_done,
	output reg [15:0] c0_rd,

	input             c1_req,
	input             c1_we,
	input      [21:0] c1_addr,
	input      [15:0] c1_wd,
	output reg        c1_done,
	output reg [15:0] c1_rd,

	input             c2_req,
	input             c2_we,
	input             c2_bank,
	input      [21:0] c2_addr,
	input      [15:0] c2_wd,
	output reg        c2_done,
	output reg [15:0] c2_rd,

	output reg        pr_req_tgl,
	output reg        pr_we,
	output reg        pr_bank,
	output reg [21:0] pr_addr,
	output reg [15:0] pr_wdata,
	input             pr_ack_tgl,
	input      [15:0] pr_rdata
);

initial begin pr_req_tgl = 0; pr_we = 0; pr_bank = 0; pr_addr = 0; pr_wdata = 0;
	c0_done = 0; c1_done = 0; c2_done = 0; c0_rd = 0; c1_rd = 0; c2_rd = 0; end

localparam [1:0] A_SYNC = 2'd0, A_IDLE = 2'd1, A_BUSY = 2'd2, A_GAP = 2'd3;
reg [1:0] st = A_SYNC;
reg       ack1 = 0, ack2 = 0;
reg [1:0] g = 0;             // the client that owns the current access
reg [1:0] last = 0;          // round robin pointer (client served last)

// writes are served first: only the clients with a pending write compete when there is one
wire [2:0] req = {c2_req, c1_req, c0_req};
wire [2:0] wr  = {c2_req & c2_we, c1_req & c1_we, c0_req & c0_we};
wire [2:0] cand = (|wr) ? wr : req;
// round robin: first candidate after 'last'
reg [1:0] pick;
always @* begin
	case (last)
		2'd0:    pick = cand[1] ? 2'd1 : cand[2] ? 2'd2 : 2'd0;
		2'd1:    pick = cand[2] ? 2'd2 : cand[0] ? 2'd0 : 2'd1;
		default: pick = cand[0] ? 2'd0 : cand[1] ? 2'd1 : 2'd2;
	endcase
end

always @(posedge clk) begin
	ack1    <= pr_ack_tgl;
	ack2    <= ack1;
	c0_done <= 1'b0;
	c1_done <= 1'b0;
	c2_done <= 1'b0;

	if (reset) st <= A_SYNC;
	else case (st)
		A_SYNC: if (ack2 == pr_req_tgl) st <= A_IDLE;

		A_IDLE:
			if (|req) begin
				g     <= pick;
				last  <= pick;
				pr_we    <= (pick == 2'd2) ? c2_we   : (pick == 2'd1) ? c1_we   : c0_we;
				pr_bank  <= (pick == 2'd2) ? c2_bank : 1'b0;
				pr_addr  <= (pick == 2'd2) ? c2_addr : (pick == 2'd1) ? c1_addr : c0_addr;
				pr_wdata <= (pick == 2'd2) ? c2_wd   : (pick == 2'd1) ? c1_wd   : c0_wd;
				pr_req_tgl <= ~pr_req_tgl;
				st <= A_BUSY;
			end

		A_BUSY:
			if (ack2 == pr_req_tgl) begin
				case (g)
					2'd2:    begin c2_rd <= pr_rdata; c2_done <= 1'b1; end
					2'd1:    begin c1_rd <= pr_rdata; c1_done <= 1'b1; end
					default: begin c0_rd <= pr_rdata; c0_done <= 1'b1; end
				endcase
				st <= A_GAP;
			end

		A_GAP: st <= A_IDLE;
	endcase
end

endmodule

// ---------------------------------------------------------------------------
// Adapter: a toggle-handshake requester (the MSU data store) -> req/done client of msu_pr_arb3
// ---------------------------------------------------------------------------
module msu_tgl2req (
	input             clk,
	input             reset,
	input             req_tgl,
	output            req,
	output reg        ack_tgl,
	input             done,
	input      [15:0] done_rd,
	output reg [15:0] rd
);
initial begin ack_tgl = 0; rd = 0; end
reg busy = 0;                      // a grant is in flight: do not present the same toggle again
assign req = (req_tgl != ack_tgl) && !done;
always @(posedge clk) begin
	if (reset) begin ack_tgl <= req_tgl; end
	else if (done) begin rd <= done_rd; ack_tgl <= req_tgl; end
end
endmodule
