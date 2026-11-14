// MSU-1 stream cache (Analogue Pocket / openFPGA port).
//
// The SD card is read through ONE command channel whose every request has a large fixed latency.  Two streams
// (music + voice) that refill small FIFOs with small reads starve each other.  This cache sits between an
// msu_audio instance and msu_bridge: it reads the stream ahead in BIG pieces into a PSRAM ring buffer and answers the
// small fetches of the audio player from the PSRAM in microseconds.
//
//   bridge --(pcm words)--> write queue --> PSRAM ring        (prefetcher: FIRST_BYTES, then CHUNK_BYTES per request)
//   audio  <--(pcm words)-- PSRAM ring                          (demand reads)
//
// The ring holds the file bytes [rs, hi).  A demand outside it (a seek / loop jump) restarts the prefetch at the demanded offset.
// File offsets are the byte offsets msu_audio asks for.
//
module msu_scache #(
	parameter [21:0] PS_BASE     = 22'h100000,     // word address of the ring (must be aligned to the ring size in words)
	parameter        FIXED       = 0,              // 1: the whole stream fits the ring (size capped to the ring): no wrap, no restart, much less logic
	parameter        OW          = 26,             // bits of clip offsets / sizes
	parameter        RING_LOG2   = 21,             // ring size in bytes = 2^RING_LOG2
	parameter [31:0] FIRST_BYTES = 32'd16384,      // first read after a start / restart (short: playback starts quickly)
	parameter [31:0] CHUNK_BYTES = 32'd131072      // every following read
) (
	input             clk,
	input             reset,

	// stream select state (from MSU / msu_bridge)
	input             mounting,
	input             missing,
	input      [31:0] size,

	// audio side: the fetch handshake of msu_audio
	input             a_fetch_tgl,
	input      [31:0] a_off,
	input      [15:0] a_len,
	output reg        a_done_tgl,
	output reg        a_err,
	output reg        a_pcm_wr,
	output reg [15:0] a_pcm_data,

	// bridge side
	output reg        b_fetch_tgl,
	output reg [31:0] b_off,
	output reg [31:0] b_len,
	input             b_done_tgl,
	input             b_err,
	input             b_pcm_wr,
	input      [15:0] b_pcm_data,

	// PSRAM client port (see msu_pr_arb)
	output reg        pr_req,
	output reg        pr_we,
	output reg [21:0] pr_addr,
	output reg [15:0] pr_wdata,
	input             pr_done,
	input      [15:0] pr_rdata
);

localparam RW = RING_LOG2 - 1;                       // ring size in words = 2^RW
localparam [31:0] RING32 = 32'd1 << RING_LOG2;
localparam [OW:0] RING = {{OW{1'b0}},1'b1} << RING_LOG2;

initial begin
	a_done_tgl = 0; a_err = 0; a_pcm_wr = 0; a_pcm_data = 0;
	b_fetch_tgl = 0; b_off = 0; b_len = 0;
	pr_req = 0; pr_we = 0; pr_addr = 0; pr_wdata = 0;
end

// ---- stream bookkeeping ----
reg        mnt_q      = 0;
reg        clip_valid = 0;          // a stream is selected and its size is known
reg        new_pend   = 0;          // new stream selected: set it up when the prefetcher is idle
reg [OW-1:0] new_size   = 0;
reg [OW-1:0] size_eff   = 0;          // bytes of the stream (multiple of 4)
reg [OW-1:0] rs         = 0;          // ring holds the file bytes [rs, hi)
reg [OW-1:0] hi         = 0;
reg [OW-1:0] lo         = 0;          // consumption position (offset of the latest demand)
reg        restart_pend = 0;
reg [OW-1:0] restart_off  = 0;
reg        pfail      = 0;

// ---- prefetcher ----
localparam [2:0] P_IDLE = 3'd0, P_REQ = 3'd1, P_WAIT = 3'd2, P_SETTLE = 3'd3, P_DRAIN = 3'd4;
reg  [2:0] ps = P_IDLE;
reg  [1:0] retry = 0;
reg [15:0] settle = 0;
reg        b_done_prev = 0;
reg        perr = 0, q_ovf = 0;
reg [20:0] rxw = 0;
reg [RW-1:0] wa_off = 0;

wire [OW-1:0] rem  = size_eff - hi;
wire [OW-1:0] want = (hi == rs) ? FIRST_BYTES[OW-1:0] : CHUNK_BYTES[OW-1:0];
wire [OW-1:0] plen = (rem >= want) ? want : {rem[OW-1:2], 2'b00};
wire [OW:0] hi_chunk = {1'b0, hi} + CHUNK_BYTES[OW:0];
wire [OW:0] lo_ring  = {1'b0, lo} + RING;

(* ramstyle = "MLAB, no_rw_check" *) reg [15:0] wq [0:63];
reg  [5:0] wq_w = 0, wq_r = 0;
reg [15:0] wq_q = 0;
wire       q_empty = (wq_w == wq_r);
wire       q_full  = ((wq_w + 6'd1) == wq_r);

// ---- PSRAM access engine ----
localparam [2:0] M_IDLE = 3'd0, M_W1 = 3'd1, M_W = 3'd2, M_R = 3'd3;
reg  [2:0] ms = M_IDLE;
reg        rd_req = 0, rd_vld = 0;
reg [RW-1:0] rd_off = 0;
reg [15:0] rd_data = 0;

// ---- demand side ----
localparam [2:0] D_IDLE = 3'd0, D_CHK = 3'd1, D_RD0 = 3'd2, D_RD1 = 3'd3, D_FIN = 3'd4, D_ERR = 3'd5;
reg  [2:0] ds = D_IDLE;
reg        a_seen = 0;
reg [OW-1:0] d_off = 0;
reg [15:0] d_len = 0;
reg [14:0] d_idx = 0;
wire [OW:0] d_need = {1'b0, d_off} + {{(OW-15){1'b0}}, d_len};
// a chunk that is being read can overwrite up to CHUNK_BYTES behind the ring start once the ring is full: keep that band out of reach
wire [OW:0] used_now = {1'b0, hi} - {1'b0, rs};
wire [OW-1:0] rs_safe  = FIXED ? {OW{1'b0}} : ((used_now + CHUNK_BYTES[OW:0]) > RING) ? (rs + CHUNK_BYTES[OW-1:0]) : rs;
wire        d_inring = (d_off >= rs_safe) && (d_need <= {1'b0, hi});

always @(posedge clk) begin
	mnt_q    <= mounting;
	a_pcm_wr <= 1'b0;
	rd_vld   <= 1'b0;

	if (reset) begin
		clip_valid   <= 1'b0;
		new_pend     <= 1'b0;
		restart_pend <= 1'b0;
		pfail        <= 1'b0;
		ps           <= P_IDLE;
		ds           <= D_IDLE;
		ms           <= M_IDLE;
		pr_req       <= 1'b0;
		wq_w         <= 6'd0;
		wq_r         <= 6'd0;
		rd_req       <= 1'b0;
		b_done_prev  <= b_done_tgl;
		a_seen       <= a_fetch_tgl;
		rs <= 0; hi <= 0; lo <= 0; size_eff <= 0;
	end
	else begin

		// ---------------- words from the bridge -> queue ----------------
		if (b_pcm_wr && (ps == P_WAIT || ps == P_SETTLE)) begin
			rxw <= rxw + 1'd1;
			if (q_full) q_ovf <= 1'b1;
			else begin
				wq[wq_w] <= b_pcm_data;
				wq_w     <= wq_w + 1'd1;
			end
		end

		// ---------------- prefetcher ----------------
		case (ps)
			P_IDLE:
				begin
					if (new_pend) begin
						new_pend   <= 1'b0;
						size_eff   <= new_size;
						rs <= 32'd0; hi <= 32'd0; lo <= 32'd0;
						clip_valid <= 1'b1;
						pfail      <= 1'b0;
						retry      <= 2'd0;
						restart_pend <= 1'b0;
					end
					else if (restart_pend) begin
						restart_pend <= 1'b0;
						rs <= restart_off; hi <= restart_off; lo <= restart_off;
						pfail <= 1'b0;
						retry <= 2'd0;
					end
					else if (clip_valid && !pfail && (hi < size_eff) && (FIXED || (hi_chunk <= lo_ring))) ps <= P_REQ;
				end

			P_REQ:
				begin
					b_off       <= hi;
					b_len       <= plen;
					rxw         <= 21'd0;
					q_ovf       <= 1'b0;
					perr        <= 1'b0;
					wa_off      <= hi[RW:1];
					b_fetch_tgl <= ~b_fetch_tgl;
					ps          <= P_WAIT;
				end

			P_WAIT:
				if (b_done_tgl != b_done_prev) begin
					b_done_prev <= b_done_tgl;
					perr        <= b_err;
					settle      <= 16'd0;
					ps          <= P_SETTLE;
				end

			// let the tail of the transfer trickle through data_loader (all words in, at least 255 cycles, at most ~3 ms)
			P_SETTLE:
				begin
					settle <= settle + 1'd1;
					if ((settle >= 16'd255 && rxw == b_len[21:1]) || settle == 16'hFFFF) ps <= P_DRAIN;
				end

			// the queue is written out: evaluate the chunk
			P_DRAIN:
				if (q_empty && ms == M_IDLE) begin
					if (!clip_valid || new_pend || restart_pend) ps <= P_IDLE;      // chunk of a stream that was replaced meanwhile
					else if (!perr && !q_ovf && rxw == b_len[21:1]) begin
						hi    <= hi + b_len;
						if (!FIXED && (({1'b0, hi} + {1'b0, b_len} - {1'b0, rs}) > RING)) rs <= hi + b_len - RING[OW-1:0];
						retry <= 2'd0;
						ps    <= P_IDLE;
					end
					else if (retry != 2'd3) begin
						retry <= retry + 1'd1;
						ps    <= P_REQ;
					end
					else begin
						pfail <= 1'b1;
						ps    <= P_IDLE;
					end
				end

			default: ps <= P_IDLE;
		endcase

		// ---------------- demand side ----------------
		case (ds)
			D_IDLE:
				if (a_fetch_tgl != a_seen) begin
					a_seen <= a_fetch_tgl;
					d_off  <= a_off;
					d_len  <= a_len;
					ds     <= D_CHK;
				end

			D_CHK:
				begin
					if (new_pend) ;                                                  // the new stream is still being set up: wait
					else if (!clip_valid || d_need > {1'b0, size_eff}) ds <= D_ERR;
					else if (d_inring) begin
						lo    <= d_off;
						d_idx <= 15'd0;
						ds    <= (d_len == 16'd0) ? D_FIN : D_RD0;
					end
					else if (!FIXED && (d_off < rs_safe || d_off > hi)) begin                         // outside the ring: restart the prefetch there
						if (!restart_pend) begin restart_pend <= 1'b1; restart_off <= d_off; end
					end
					else begin                                                       // inside, the data is still coming
						lo <= d_off;
						if (pfail) ds <= D_ERR;
					end
				end

			D_RD0:
				begin
					rd_off <= d_off[RW:1] + {{(RW-15){1'b0}}, d_idx};
					rd_req <= 1'b1;
					ds     <= D_RD1;
				end

			D_RD1:
				if (rd_vld) begin
					a_pcm_wr   <= 1'b1;
					a_pcm_data <= rd_data;
					d_idx      <= d_idx + 1'd1;
					ds         <= ((d_idx + 15'd1) == d_len[15:1]) ? D_FIN : D_RD0;
				end

			D_FIN:
				begin
					a_err      <= 1'b0;
					a_done_tgl <= ~a_done_tgl;
					ds         <= D_IDLE;
				end

			D_ERR:
				begin
					a_err      <= 1'b1;
					a_done_tgl <= ~a_done_tgl;
					ds         <= D_IDLE;
				end

			default: ds <= D_IDLE;
		endcase

		// ---------------- PSRAM access engine (queued writes first, then demand reads) ----------------
		case (ms)
			M_IDLE:
				begin
					if (!q_empty) begin
						wq_q <= wq[wq_r];
						ms   <= M_W1;
					end
					else if (rd_req) begin
						rd_req  <= 1'b0;
						pr_we   <= 1'b0;
						pr_addr <= PS_BASE | {{(22-RW){1'b0}}, rd_off};
						pr_req  <= 1'b1;
						ms      <= M_R;
					end
				end

			M_W1:
				begin
					pr_we    <= 1'b1;
					pr_addr  <= PS_BASE | {{(22-RW){1'b0}}, wa_off};
					pr_wdata <= wq_q;
					pr_req   <= 1'b1;
					wa_off   <= wa_off + 1'd1;
					wq_r     <= wq_r + 1'd1;
					ms       <= M_W;
				end

			M_W: if (pr_done) begin pr_req <= 1'b0; ms <= M_IDLE; end

			M_R:
				if (pr_done) begin
					pr_req  <= 1'b0;
					rd_data <= pr_rdata;
					rd_vld  <= 1'b1;
					ms      <= M_IDLE;
				end

			default: ms <= M_IDLE;
		endcase

		// ---------------- select events (last: they win over the setup above) ----------------
		if (mounting && !mnt_q) begin                    // a new select starts: the old stream is gone
			clip_valid   <= 1'b0;
			new_pend     <= 1'b0;
			restart_pend <= 1'b0;
			pfail        <= 1'b0;
		end
		if (!mounting && mnt_q) begin                    // mounted: the size is known
			if (!missing && size[29:0] != 30'd0) begin
				new_pend <= 1'b1;
				new_size <= FIXED ? ((size[31:0] > RING32) ? RING[OW-1:0] : {size[OW-1:2], 2'b00}) : ((|size[29:OW]) ? {{(OW-2){1'b1}}, 2'b00} : {size[OW-1:2], 2'b00});
			end
		end
	end
end

endmodule
