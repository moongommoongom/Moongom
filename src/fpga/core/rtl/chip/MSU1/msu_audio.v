// MSU-1 audio player for the Analogue Pocket (openFPGA) port.
//
// Derived from the MiSTer SNES core msu_audio.v (GPL). Differences:
//  * No HPS pushing sectors. This module asks msu_bridge for chunks of the
//    track file with a toggle handshake (fetch_tgl / fetch_done_tgl); msu_bridge
//    executes an APF "[0180 Data slot read]" and the bytes arrive as little-endian
//    16-bit words on pcm_wr/pcm_data (through data_loader).
//  * Every track starts with an 8 byte header fetch ("MSU1" + loop point) which
//    is parsed but not played, then the audio data is fetched in CHUNK_BYTES chunks.
//  * audio_sector (1KB units) reports the current fetch position for MSU resume.
//  * Track heads (the first 128 KB = ~0.74 s of every track 1..127) are kept in the otherwise
//    unused part of the Pocket PSRAM, so a track starts instantly from there while the real
//    file is mounted in the background.  Heads are filled either by the boot preload
//    (msu_preload) or on the first play of a track.
//
// PCM file: "MSU1", u32 loop point (in stereo frames), then 16-bit LE stereo samples.

module msu_audio #(parameter FIFO_AW = 14)
(
	input             reset,

	input             clk,
	input      [31:0] clk_rate,

	input      [7:0]  ctl_volume,
	input             ctl_repeat,
	input             ctl_play,
	input             ctl_resume,
	output reg        ctl_stop,
	output            audio_ready,       // first data buffered (or nothing to buffer)

	// Track-head cache (PSRAM)
	input      [15:0] track_num,
	input             track_req,         // track select pending (from MSU or the boot preload)
	input             pre_mode,          // boot preload: bulk-load the heads file into the head cache, no playback
	output reg        head_hit,          // head of the requested track is already buffered
	input             cache_flush,       // forget all cached heads (new game / boot preload start)
	output reg        fill_ok,           // the head of the requested track has just been cached

	// PSRAM port (toggle handshake, see psram.sv)
	output reg        pr_req_tgl,
	output reg        pr_we,
	output reg        pr_bank,
	output reg [21:0] pr_addr,
	output reg [15:0] pr_wdata,
	input             pr_ack_tgl,
	input      [15:0] pr_rdata,

	// the old external SRAM cache is no longer used
	output     [16:0] sram_a,
	output     [15:0] sram_do,
	output            sram_oe,
	input      [15:0] sram_di,
	output            sram_we_n,
	output            sram_oe_n,

	input      [31:0] track_size,        // bytes, 0 = unknown/missing
	input             track_processing,

	// PCM words from the bridge (clk domain)
	input             pcm_wr,
	input      [15:0] pcm_data,

	// Chunk fetch handshake with msu_bridge
	output reg        fetch_tgl,
	output reg [31:0] fetch_off,
	output reg [15:0] fetch_len,
	input             fetch_done_tgl,    // synchronised to clk
	input             fetch_err,

	output     [21:0] audio_sector,
	input      [21:0] resume_sector,

	output     [15:0] audio_l,
	output     [15:0] audio_r,

	output reg  [4:0] dbg_code,          // beeper code (10..16), see below
	output reg  [2:0] dbg_lat,           // worst fetch latency class 0..4
	output reg  [3:0] dbg_reqs           // track requests since boot (saturating at 9)
);

assign sram_a = 17'd0;
assign sram_do = 16'd0;
assign sram_oe = 1'b0;
assign sram_we_n = 1'b1;
assign sram_oe_n = 1'b1;

localparam [15:0] CHUNK_BYTES  = (FIFO_AW == 14) ? 16'd32768 : 16'd8192;
localparam [15:0] FIRST_BYTES  = (FIFO_AW == 14) ? 16'd32768 : 16'd16384;
localparam [31:0] HEADB        = 32'd98304;                          // cached head bytes per track (96 KB, ~0.56 s)
localparam [13:0] REFILL_LEVEL = (FIFO_AW == 14) ? 14'd7936   : 14'd1984;   // fetch when FIFO holds <= this many frames
localparam [13:0] COPY_LIMIT   = (FIFO_AW == 14) ? 14'd16300  : 14'd4020;   // head copy pauses above this fill level

localparam [3:0] S_IDLE   = 4'd0;
localparam [3:0] S_HDR    = 4'd1;
localparam [3:0] S_WAIT   = 4'd2;
localparam [3:0] S_SETTLE = 4'd3;
localparam [3:0] S_SPACE  = 4'd4;
localparam [3:0] S_DATA   = 4'd5;
localparam [3:0] S_END    = 4'd6;
localparam [3:0] S_DRAIN  = 4'd7;
localparam [3:0] S_BHDR   = 4'd8;    // bulk head load: read the index of the heads file
localparam [3:0] S_BSCAN  = 4'd9;
localparam [3:0] S_BCH    = 4'd10;
localparam [3:0] S_BEND   = 4'd11;
localparam [3:0] S_TCH    = 4'd12;   // hit: fetch the data behind the cached head into a PSRAM tail buffer
localparam [22:0] STASH_BASE = 23'd6291456;    // word address of the tail buffer (128 * 0xC000), 1.94 MB used
localparam [20:0] TAILMAX    = 21'd2031616;

wire        fifo_full;
wire [FIFO_AW-1:0] fifo_usedw_r;
wire [13:0] fifo_usedw = {{(14-FIFO_AW){1'b0}}, fifo_usedw_r};
wire        fifo_empty;

reg  [3:0]  state = S_IDLE;
reg [31:0]  pos = 0;               // byte offset of the next data chunk (always 1KB aligned)
reg   [9:0] skip_cnt = 0;          // dwords to discard at the start of the next chunk
reg   [9:0] skip_cur = 0;          // ... latched for the transfer in flight
reg         first_cur = 0;         // transfer in flight starts at byte 0 (has the file header)
reg   [1:0] retries = 0;
reg [31:0]  loop_index = 0;        // loop point as frame index incl. 2 header dwords
reg         resuming = 0;
reg         hdr = 0;               // current fetch is the header
reg  [15:0] cur_len = 0;
reg         done_prev = 0;
reg   [7:0] settle = 0;
reg         last_err = 0;
reg   [3:0] hold = 0;
reg         pf_done = 0;           // prefetch already started for this track

// ---- track-head cache (PSRAM: 128 KB per track number 1..127) ----
localparam [1:0] H_IDLE = 2'd0, H_LK = 2'd1, H_WAIT = 2'd2, H_COPY = 2'd3;
reg   [1:0] hs = H_IDLE;
reg         use_head = 0, fill_pending = 0, fill_active = 0;
initial fill_ok = 0;
reg [127:0] valid = 0;
reg  [16:0] hwm [0:127];           // head length in words per track
reg  [16:0] hm_q = 0;
reg  [16:0] hw_cur = 0;
reg   [6:0] fill_tn = 0, cp_tn = 0;
reg  [22:0] fill_base = 0, cp_base = 0;   // word address of the track's head in the PSRAM (track * 0x16000)
function [22:0] tbase(input [6:0] t);
	tbase = {t, 15'b0} + {1'b0, t, 14'b0};          // t * 0xC000
endfunction
reg   [6:0] flush_cnt = 0;
reg         treq_q = 0;
reg         cp_go = 0;
wire        cp_fin;
wire        wr_busy;
reg   [3:0] cs = 0;
reg  [19:0] cp_w = 0;
reg  [15:0] cp_lo = 0;
reg  [13:0] cp_n = 0;
reg         cp_v = 0;
reg  [31:0] cp_din = 0;
reg         cp_fin_r = 0;
reg         cp_first = 0;
reg         cp_loop_v = 0;
reg  [31:0] cp_loop_d = 0;
wire        new_trk   = track_req & ~treq_q;
wire        head_busy = (hs != H_IDLE);
wire        tn_ok     = 1'b0;   // head cache disabled: the .msp pack file makes track changes fast, and track numbers go up to ~4000
reg         wq_ld_tgl = 0, wq_ld_q = 0;
reg  [19:0] wq_base = 0;
reg         tail = 0, tail_known = 0, tail_use = 0, tail_done = 0;
reg  [19:0] tail_wds = 0;
reg  [20:0] tail_bytes = 0;
reg   [1:0] t_retry = 0;
reg         cp_tail_ph = 0;
// bulk head load (heads file: 512 byte index of u32 head lengths per track, then the heads in track order)
reg         bulk = 0, b_hdr = 0, b_fill = 0, b_ph = 0;
reg   [7:0] b_tn = 0;
reg  [31:0] b_off = 0;
reg  [17:0] b_done = 0;
reg  [16:0] b_len = 0;                 // head length (words) of the track being loaded
reg  [15:0] b_clen = 0;
reg   [1:0] b_retry = 0;
reg  [16:0] hl [0:127];
reg  [16:0] hl_q = 0;
localparam HEADS = 0;   // head cache / heads file removed (pack file mode): frees the index RAM
always @(posedge clk) hl_q <= HEADS ? hl[b_tn[6:0]] : 17'd0;
reg  [15:0] wq [0:7];
reg   [3:0] wq_w = 0, wq_r = 0;
wire        wq_empty = (wq_w == wq_r);
reg        pm_busy = 0, pm_done = 0;
reg [15:0] pm_rd = 0;
reg        ack1 = 0, ack2 = 0;
reg [19:0] wa = 0;
wire [22:0] cp_b   = cp_tail_ph ? STASH_BASE : cp_base;
wire [22:0] pa_rd0 = cp_b + {3'b0, cp_w};
wire [22:0] pa_rd1 = cp_b + {3'b0, cp_w[19:1], 1'b1};
wire [22:0] pa_wr  = fill_base + {3'b0, wa};

initial begin
	fetch_tgl = 0;
	fetch_off = 0;
	fetch_len = 0;
	ctl_stop  = 0;
	pr_req_tgl = 0; pr_we = 0; pr_bank = 0; pr_addr = 0; pr_wdata = 0; head_hit = 0;
end

always @(posedge clk) hm_q <= hwm[track_num[6:0]];

assign audio_sector = pos[31:10];

assign audio_ready = (fifo_usedw >= 14'd3500) | (state == S_END) | (state == S_DRAIN) | (track_size == 32'd0);

wire done_changed = (fetch_done_tgl != done_prev);

wire [31:0] remaining  = track_size - pos;
wire [31:0] npos       = pos + {16'b0, cur_len};
// The first read of a track is a big one (the ~80 ms prebuffer is reached while it streams in); later reads are big for throughput.
wire [15:0] chunk_len  = (pos == 32'd0) ? FIRST_BYTES : CHUNK_BYTES;
wire        pos_valid  = (pos < track_size);
wire [31:0] loop_pos   = {loop_index[29:0], 2'b00};
wire        loop_valid = (loop_pos >= 32'd8) && (loop_pos < track_size);

always @(posedge clk) begin
	ctl_stop  <= 0;
	done_prev <= fetch_done_tgl;

	if (hold != 0) hold <= hold - 1'd1;
	if (ctl_resume) resuming <= 1;

	if (reset) begin
		state    <= S_IDLE;
		resuming <= 0;
		hold     <= 0;
		hs       <= H_IDLE;
		cp_go    <= 0;
		use_head <= 0; fill_pending <= 0; fill_active <= 0;
		bulk <= 0; b_hdr <= 0; b_fill <= 0;
		tail <= 0; tail_known <= 0; tail_use <= 0; tail_done <= 0;
	end
	else begin
		case (state)
			S_IDLE:
				begin
					if (~track_processing & ~head_busy & pre_mode & ~pf_done & (|track_size)) begin
						pf_done  <= 1;
						bulk     <= 1'b1;
						b_hdr    <= 1'b1;
						b_retry  <= 0;
						state    <= S_BHDR;
					end
					else if (~track_processing & use_head & ~pre_mode & ~pf_done & (|track_size)) begin
						// cached head: start fetching what follows it right away (into the PSRAM tail buffer),
						// independent of how full the audio FIFO is
						pf_done    <= 1;
						use_head   <= 1'b0;
						pos        <= {14'b0, hw_cur, 1'b0};
						skip_cnt   <= 10'd0;
						resuming   <= 0;
						last_err   <= 0;
						retries    <= 0;
						t_retry    <= 0;
						tail_bytes <= 0;
						tail_wds   <= 0;
						tail_done  <= 0;
						tail_known <= 1'b1;
						if ({14'b0, hw_cur, 1'b0} >= HEADB && ({14'b0, hw_cur, 1'b0} + 32'd4) <= track_size) begin
							tail     <= 1'b1;
							tail_use <= 1'b1;
							state    <= S_TCH;
						end
						else begin
							tail_use <= 1'b0;
							state    <= S_SPACE;
						end
					end
					else if (~track_processing & ~head_busy & ~use_head & ~pre_mode & (ctl_play | ~pf_done) & (hold == 0) & (|track_size)) begin
						pf_done  <= 1;
						use_head <= 1'b0;
						if (use_head) begin
							pos      <= {14'b0, hw_cur, 1'b0};   // the head came from the PSRAM cache
							skip_cnt <= 10'd0;
						end
						else if (resuming && resume_sector != 0) begin
							pos      <= {resume_sector, 10'b0};
							skip_cnt <= 10'd0;
						end
						else begin
							pos      <= 32'd0;
							skip_cnt <= 10'd2;           // the 8 header bytes
						end
						resuming <= 0;
						last_err <= 0;
						retries  <= 0;
						state    <= S_SPACE;
					end
				end

			// ---- bulk head load ----
			S_BHDR:
				begin
					skip_cur  <= 10'd0;
					first_cur <= 1'b0;
					cur_len   <= 16'd512;
					b_clen    <= 16'd512;
					fetch_off <= 32'd0;
					fetch_len <= 16'd512;
					fetch_tgl <= ~fetch_tgl;
					state     <= S_WAIT;
				end

			S_BSCAN:
				begin
					if (b_tn > 8'd127) state <= S_BEND;
					else if (!b_ph) b_ph <= 1'b1;               // let hl_q settle
					else begin
						b_ph <= 1'b0;
						if (hl_q == 17'd0) b_tn <= b_tn + 1'd1;
						else begin
							b_len   <= hl_q;
							b_done  <= 18'd0;
							fill_tn <= b_tn[6:0];
							fill_base <= tbase(b_tn[6:0]);
							state   <= S_BCH;
						end
					end
				end

			S_BCH:
				begin
					if ({b_len, 1'b0} == {1'b0, b_done}) begin
						hwm[fill_tn]   <= b_len;
						valid[fill_tn] <= 1'b1;
						b_tn           <= b_tn + 1'd1;
						b_retry        <= 0;
						state          <= S_BSCAN;
					end
					else begin
						b_fill    <= 1'b1;
						b_clen    <= (({b_len, 1'b0} - {1'b0, b_done}) >= 19'd32768) ? 16'd32768 : ({b_len, 1'b0} - {1'b0, b_done});
						fetch_off <= b_off;
						fetch_len <= (({b_len, 1'b0} - {1'b0, b_done}) >= 19'd32768) ? 16'd32768 : ({b_len, 1'b0} - {1'b0, b_done});
						wq_base   <= b_done[17:1];
						wq_ld_tgl <= ~wq_ld_tgl;
						fetch_tgl <= ~fetch_tgl;
						state     <= S_WAIT;
					end
				end

			S_TCH:
				begin
					if (tail_bytes >= TAILMAX || remaining < 32'd4) begin
						tail <= 1'b0; tail_done <= 1'b1; b_fill <= 1'b0;
						state <= S_SPACE;
					end
					else begin
						b_fill    <= 1'b1;
						b_clen    <= (remaining >= 32'd32768) ? 16'd32768 : {remaining[15:2], 2'b00};
						cur_len   <= (remaining >= 32'd32768) ? 16'd32768 : {remaining[15:2], 2'b00};
						skip_cur  <= 10'd0;
						first_cur <= 1'b0;
						fill_base <= STASH_BASE;
						wq_base   <= tail_bytes[20:1];
						wq_ld_tgl <= ~wq_ld_tgl;
						fetch_off <= pos;
						fetch_len <= (remaining >= 32'd32768) ? 16'd32768 : {remaining[15:2], 2'b00};
						fetch_tgl <= ~fetch_tgl;
						state     <= S_WAIT;
					end
				end

			S_BEND:
				begin
					bulk    <= 1'b0;
					b_fill  <= 1'b0;
					fill_ok <= 1'b1;
					pf_done <= 1'b1;
					state   <= S_IDLE;
				end

			// Header: bytes 0..7
			S_HDR:
				begin
					hdr       <= 1;
					cur_len   <= 16'd8;
					fetch_off <= 32'd0;
					fetch_len <= 16'd8;
					fetch_tgl <= ~fetch_tgl;
					state     <= S_WAIT;
				end

			S_WAIT:
				if (done_changed) begin
					last_err <= fetch_err;
					settle   <= 0;
					state    <= S_SETTLE;
				end

			// Let the tail of the transfer trickle through data_loader (and the head writer drain)
			S_SETTLE:
				begin
					if (settle != 8'd255) settle <= settle + 1'd1;
					else if (!(fill_active | b_fill) || (wq_empty && !pm_busy)) begin
						if (tail) begin
							if (!last_err) begin
								t_retry    <= 0;
								pos        <= npos;
								tail_bytes <= tail_bytes + {5'b0, b_clen};
								tail_wds   <= tail_wds + {5'b0, b_clen[15:1]};
								state      <= S_TCH;
							end
							else if (t_retry != 2'd3) begin
								t_retry  <= t_retry + 1'd1;
								last_err <= 1'b0;
								state    <= S_TCH;
							end
							else begin
								tail <= 1'b0; tail_done <= 1'b1; b_fill <= 1'b0;   // give up the tail: continue the normal way
								state <= S_SPACE;
							end
						end
						else if (bulk) begin
							if (!last_err) begin
								b_retry <= 0;
								if (b_hdr) begin b_hdr <= 1'b0; b_tn <= 8'd1; b_off <= 32'd512; b_ph <= 1'b0; state <= S_BSCAN; end
								else begin b_off <= b_off + {16'b0, b_clen}; b_done <= b_done + {2'b0, b_clen}; state <= S_BCH; end
							end
							else if (b_retry != 2'd3) begin
								b_retry <= b_retry + 1'd1;
								last_err <= 1'b0;
								state <= b_hdr ? S_BHDR : S_BCH;
							end
							else state <= S_BEND;                // give up: whatever is loaded stays valid
						end
						else if (!last_err) begin
							if (fill_active && (npos >= HEADB || (npos + 32'd4) > track_size)) begin
								hwm[fill_tn]   <= npos[17:1];    // whole head (or whole short track) is cached
								valid[fill_tn] <= 1'b1;
								fill_ok        <= 1'b1;
								fill_active    <= 1'b0;
							end
							pos      <= npos;
							skip_cnt <= 10'd0;
							retries  <= 0;
							state    <= S_SPACE;
							if (pre_mode && fill_active && (npos >= HEADB || (npos + 32'd4) > track_size)) begin
								pf_done <= 1'b1;               // preload: this track is done, don't fetch on
								state   <= S_IDLE;
							end
						end
						else if (retries != 2'd3) begin
							retries  <= retries + 1'd1;   // transient error: read the same chunk again
							last_err <= 0;
							state    <= S_DATA;
						end
						else begin
							state    <= S_END;
						end
					end
				end

			S_SPACE:
				if (head_busy) ;                         // the head / tail copy still owns the FIFO
				else if (!pos_valid) state <= S_END;
				else if (fifo_usedw <= REFILL_LEVEL) state <= S_DATA;

			S_DATA:
				begin
					// Whole dwords only, at most one chunk
					cur_len   <= (remaining >= {16'b0, chunk_len}) ? chunk_len : {remaining[15:2], 2'b00};
					skip_cur  <= skip_cnt;
					first_cur <= (pos == 32'd0);
					if (pos == 32'd0 && fill_pending) begin fill_active <= 1'b1; fill_pending <= 1'b0; end
					wq_base    <= pos[17:1];
					wq_ld_tgl  <= ~wq_ld_tgl;
					fetch_off <= pos;
					fetch_len <= (remaining >= {16'b0, chunk_len}) ? chunk_len : {remaining[15:2], 2'b00};
					if (remaining < 32'd4) begin
						state <= S_END;
					end
					else begin
						fetch_tgl <= ~fetch_tgl;
						state     <= S_WAIT;
					end
				end

			S_END:
				begin
					last_err <= 0;
					if (ctl_repeat && loop_valid) begin
						pos      <= {loop_pos[31:10], 10'b0};
						skip_cnt <= loop_pos[9:2];
						retries  <= 0;
						state    <= S_SPACE;
					end
					else begin
						state <= S_DRAIN;
					end
				end

			S_DRAIN:
				if (fifo_empty) begin
					ctl_stop <= 1;
					hold     <= 4'd15;
					state    <= S_IDLE;
				end

			default: state <= S_IDLE;
		endcase

		// New track requested: abandon everything, except while a transfer is
		// still landing (its data is discarded by the FIFO clear).
		if (track_processing && state != S_WAIT && state != S_SETTLE) state <= S_IDLE;
		if (bulk && !pre_mode) begin bulk <= 0; b_hdr <= 0; b_fill <= 0; state <= S_IDLE; end   // preload aborted
		if (track_processing) pf_done <= 0;

		// ---- track-head cache control ----
		if (flush_cnt != 0) flush_cnt <= flush_cnt - 1'd1;
		case (hs)
			H_LK:
				begin
					if (valid[track_num[6:0]]) begin
						hw_cur   <= hm_q;
						cp_tn    <= track_num[6:0];
						cp_base  <= tbase(track_num[6:0]);
						use_head <= 1'b1;
						hs       <= H_WAIT;
					end
					else begin
						fill_tn      <= track_num[6:0];
						fill_base    <= tbase(track_num[6:0]);
						// miss: cache this track's head while it is fetched
						fill_pending <= 1'b1;
						hs           <= H_IDLE;
					end
				end
			H_WAIT:
				if (flush_cnt == 0 && !wr_busy) begin
					cp_go <= 1'b1;
					hs    <= H_COPY;
				end
			H_COPY:
				if (cp_fin) begin
					cp_go <= 1'b0;
					hs    <= H_IDLE;
				end
			default: ;
		endcase
		if (new_trk) begin
			fill_ok      <= 1'b0;
			flush_cnt    <= 7'd40;
			use_head     <= 1'b0;
			fill_pending <= 1'b0;
			fill_active  <= 1'b0;
			cp_go        <= 1'b0;
			tail         <= 1'b0; tail_known <= 1'b0; tail_use <= 1'b0; tail_done <= 1'b0;
			if (!bulk) b_fill <= 1'b0;
			hs           <= ((ctl_resume | resuming) || !tn_ok) ? H_IDLE : H_LK;
		end
	end
	if (cache_flush) begin valid <= 128'd0; fill_pending <= 0; fill_active <= 0; fill_ok <= 0; end
	treq_q <= track_req;
end

// ---------------------------------------------------------------------------
// Incoming 16-bit words -> 32-bit stereo frames -> FIFO (and the head writer queue)
// ---------------------------------------------------------------------------
reg  [15:0] lo_word;
reg         wcnt = 0;
reg  [13:0] dcnt = 0;
reg         fifo_wr = 0;
reg  [31:0] fifo_din;
wire [16:0] widx = pos[17:1] + {2'b00, dcnt, wcnt};      // word index inside the head

always @(posedge clk) begin
	fifo_wr <= 0;
	if (cp_loop_v) loop_index <= cp_loop_d + 32'd2;

	if (state != S_WAIT && state != S_SETTLE) begin
		wcnt <= 0;
		dcnt <= 0;
	end
	else if (pcm_wr) begin
		if ((fill_active && widx < 17'd49152) || b_fill) begin
			wq[wq_w[2:0]] <= pcm_data;
			wq_w          <= wq_w + 1'd1;
		end
		if (!wcnt) begin
			lo_word <= pcm_data;
			wcnt    <= 1;
		end
		else begin
			wcnt     <= 0;
			fifo_din <= {pcm_data, lo_word};
			if (first_cur && dcnt == 14'd1) loop_index <= {pcm_data, lo_word} + 32'd2;
			if (HEADS && b_hdr && dcnt != 14'd0 && dcnt < 14'd128) hl[dcnt[6:0]] <= {pcm_data, lo_word} >> 1;   // head length in words
			if (dcnt >= {4'b0000, skip_cur}) fifo_wr <= 1;
			dcnt <= dcnt + 1'd1;
		end
	end
end

// ---------------------------------------------------------------------------
// 44.1kHz sample clock, FIFO, volume
// ---------------------------------------------------------------------------
wire sample_ce;
CEGen sample_clock
(
	.CLK(clk),
	.RST_N(~reset),
	.IN_CLK(clk_rate),
	.OUT_CLK(44100),
	.CE(sample_ce)
);

// Playback itself only starts once ~80 ms are buffered (and restarts after an underrun),
// independent of the early audio_ready the game sees.
reg started = 0;
always @(posedge clk) begin
	if (reset | ~ctl_play) started <= 1'b0;
	else if (fifo_usedw >= 14'd3500 || state == S_END || state == S_DRAIN) started <= 1'b1;
	else if (fifo_empty && state != S_IDLE) started <= 1'b0;
end

wire        playing = ctl_play & ~fifo_empty & started;
wire [15:0] sample_l;
wire [15:0] sample_r;

msu_fifo #(32,FIFO_AW) audio_fifo
(
	.aclr(flush_cnt > 7'd30),

	.wrclk(clk),
	.wrreq(((fifo_wr & ~track_processing & ~pre_mode & ~tail) | cp_v) & ~fifo_full),
	.data(cp_v ? cp_din : fifo_din),
	.wrfull(fifo_full),
	.wrusedw(fifo_usedw_r),

	.rdclk(clk),
	.q({sample_r,sample_l}),
	.rdreq(sample_ce & playing),
	.rdempty(fifo_empty),
	.rdusedw()
);

wire [23:0] vol_mix_l = $signed(sample_l) * $signed({1'b0, ctl_volume});
wire [23:0] vol_mix_r = $signed(sample_r) * $signed({1'b0, ctl_volume});

// ---------------------------------------------------------------------------
// PSRAM access engine: head writer (queue -> PSRAM) and head copy (PSRAM -> FIFO).
// One 16-bit access at a time through a toggle handshake with the memory clock domain.
// ---------------------------------------------------------------------------
assign cp_fin  = cp_fin_r;
assign wr_busy = !wq_empty | pm_busy;


always @(posedge clk) begin
	ack1 <= pr_ack_tgl;
	ack2 <= ack1;
	cp_v <= 0;
	cp_loop_v <= 0;
	pm_done <= 0;

	if (pm_busy && ack2 == pr_req_tgl) begin
		pm_busy <= 0;
		pm_done <= 1;
		pm_rd   <= pr_rdata;
	end
	if (wq_ld_tgl != wq_ld_q) begin wq_ld_q <= wq_ld_tgl; wa <= wq_base; end
	if (new_trk) wq_r <= wq_w;                 // drop whatever is still queued

	if (reset) begin
		cs <= 0; cp_fin_r <= 0; head_hit <= 0;
	end
	else begin
		if (cp_go) begin
			case (cs)
				4'd0: begin cp_tail_ph <= 1'b0; cp_w <= 20'd2; cp_first <= 1'b1; cp_n <= 14'd0; cs <= 4'd1; end   // dword 1 = loop point, then the audio
				4'd1: if (!pm_busy && (cp_first || fifo_usedw < COPY_LIMIT)) begin
						pr_we <= 1'b0; pr_bank <= pa_rd0[22]; pr_addr <= pa_rd0[21:0];
						pr_req_tgl <= ~pr_req_tgl; pm_busy <= 1'b1;
						cs <= 4'd2;
					end
				4'd2: if (pm_done) begin
						cp_lo <= pm_rd;
						pr_we <= 1'b0; pr_bank <= pa_rd1[22]; pr_addr <= pa_rd1[21:0];
						pr_req_tgl <= ~pr_req_tgl; pm_busy <= 1'b1;
						cs <= 4'd3;
					end
				4'd3: if (pm_done) begin
						cp_din   <= {pm_rd, cp_lo};
						cp_first <= 1'b0;
						if (cp_first) begin cp_loop_v <= 1'b1; cp_loop_d <= {pm_rd, cp_lo}; end
						else begin
							cp_v <= 1'b1;
							cp_n <= cp_n + 1'd1;
							if (cp_n >= 14'd3498) head_hit <= 1'b1;   // enough buffered: the game may start
						end
						cp_w <= cp_w + 20'd2;
						cs   <= ((cp_w + 20'd2) >= {3'b0, hw_cur}) ? 4'd4 : 4'd1;
					end
				4'd4: begin                                  // head copied; continue with the tail buffer if there is one
						if (tail_known && tail_use) begin cp_tail_ph <= 1'b1; cp_w <= 20'd0; cs <= 4'd5; end
						else if (tail_known || (!track_processing && track_size == 32'd0)) cs <= 4'd8;
					end
				4'd5: if (tail_done && cp_w >= tail_wds) cs <= 4'd8;
					else if (!pm_busy && (cp_w + 20'd2) <= tail_wds && fifo_usedw < COPY_LIMIT) begin
						pr_we <= 1'b0; pr_bank <= pa_rd0[22]; pr_addr <= pa_rd0[21:0];
						pr_req_tgl <= ~pr_req_tgl; pm_busy <= 1'b1;
						cs <= 4'd6;
					end
				4'd6: if (pm_done) begin
						cp_lo <= pm_rd;
						pr_we <= 1'b0; pr_bank <= pa_rd1[22]; pr_addr <= pa_rd1[21:0];
						pr_req_tgl <= ~pr_req_tgl; pm_busy <= 1'b1;
						cs <= 4'd7;
					end
				4'd7: if (pm_done) begin
						cp_din <= {pm_rd, cp_lo};
						cp_v   <= 1'b1;
						cp_w   <= cp_w + 20'd2;
						cs     <= 4'd5;
					end
				4'd8: begin cp_fin_r <= 1'b1; head_hit <= 1'b1; cs <= 4'd9; end
				default: ;
			endcase
		end
		else begin
			cs       <= 0;
			cp_fin_r <= 0;
			if (!wq_empty && !pm_busy) begin
				pr_we <= 1'b1; pr_bank <= pa_wr[22]; pr_addr <= pa_wr[21:0];
				pr_wdata <= wq[wq_r[2:0]];
				pr_req_tgl <= ~pr_req_tgl; pm_busy <= 1'b1;
				wa <= wa + 1'd1;
				wq_r <= wq_r + 1'd1;
			end
		end
		if (new_trk) head_hit <= 1'b0;
	end
end

// ---- diagnostics (beeper) ----
reg        d_words = 0, d_fifo = 0, d_play = 0, d_nz = 0, d_raw = 0, d_started = 0, d_under = 0;
reg        d_end = 0, d_err = 0, d_pdrop = 0, d_rst = 0, tp_d = 0;
reg [16:0] d_frames = 0;           // frames consumed (saturates)
reg [22:0] lat_cnt = 0;
reg        lat_run = 0;
reg  [2:0] lat_max = 0;
wire [2:0] lat_now = (lat_cnt < 23'd262144) ? 3'd1 : (lat_cnt < 23'd524288) ? 3'd2 : (lat_cnt < 23'd2097152) ? 3'd3 : 3'd4;
wire       fetching = (state == S_HDR) || (state == S_WAIT) || (state == S_SETTLE) || (state == S_SPACE) || (state == S_DATA);

always @(posedge clk) begin
	// fetch latency of data chunks (toggle -> done)
	if (done_changed) begin
		lat_run <= 0;
		if (lat_now > lat_max) lat_max <= lat_now;
	end
	else if (state == S_DATA) begin
		lat_run <= 1;
		lat_cnt <= 0;
	end
	else if (lat_run && lat_cnt != 23'h7FFFFF) lat_cnt <= lat_cnt + 1'd1;

	if (track_processing) begin
		d_words <= 0; d_fifo <= 0; d_play <= 0; d_nz <= 0; d_raw <= 0; d_started <= 0; d_under <= 0; d_frames <= 0;
		lat_max <= 0;
		d_end <= 0; d_err <= 0; d_pdrop <= 0; d_rst <= 0;
	end
	else begin
		if (reset) d_rst <= 1;
		if (state == S_END) d_end <= 1;
		if (last_err) d_err <= 1;
		if (d_started && !ctl_play) d_pdrop <= 1;
		if (pcm_wr) d_words <= 1;
		if (fifo_wr) d_fifo <= 1;
		if (playing && sample_ce) begin
			d_play <= 1; d_started <= 1;
			if (d_frames != 17'h1FFFF) d_frames <= d_frames + 1'd1;
		end
		if (playing && (|audio_l || |audio_r)) d_nz <= 1;
			if (playing && (|sample_l || |sample_r)) d_raw <= 1;
		if (d_started && fifo_empty && ctl_play && fetching) d_under <= 1;
	end

	// 10 no pcm words, 11 words but no fifo fill, 12 fifo filled but never played,
	// 13 played but output always 0, 14 output ok but < 1 s played, 15 output ok with underruns,
	// 16 output ok, >= 1 s played, no underrun
	tp_d <= track_processing;
	if (track_processing && !tp_d && dbg_reqs != 4'd9) dbg_reqs <= dbg_reqs + 1'd1;

	// 17 core reset hit, 18 fetch error ended it, 19 reached end of track early,
	// 20 game stopped playing (ctl_play dropped)
	dbg_code <= !d_words ? 5'd10 : !d_fifo ? 5'd11 : !d_play ? 5'd12 : !d_nz ? (d_raw ? 5'd21 : 5'd13) :
	            d_under ? 5'd15 :
	            (d_frames >= 17'd44100) ? 5'd16 :
	            d_rst ? 5'd17 : d_err ? 5'd18 : d_end ? 5'd19 : d_pdrop ? 5'd20 : 5'd14;
	dbg_lat  <= lat_max;
end
initial begin dbg_code = 0; dbg_lat = 0; dbg_reqs = 0; end

assign      audio_l = playing ? vol_mix_l[23:8] : 16'h0000;
assign      audio_r = playing ? vol_mix_r[23:8] : 16'h0000;

endmodule

// ---------------------------------------------------------------------------
// Boot preload: while the SNES is still held in reset, mount "<rom>.msh" (track number 0xFFFF)
// and let msu_audio bulk-load every track head from it into the PSRAM head cache.
// If the heads file does not exist the preload ends immediately and the game starts as usual.
// ---------------------------------------------------------------------------
module msu_preload
(
	input             clk,
	input             init_hold,        // msu_bridge is still initialising
	input             enable,           // MSU-1 data file found and the option is on
	input             mounting,
	input             missing,
	input             done,             // bulk load finished (fill_ok)

	output reg        req,
	output reg [15:0] num,
	output reg        flush,
	output            active,
	output            pre_mode
);

localparam [2:0] ST_IDLE = 3'd0, ST_REQ = 3'd1, ST_MEND = 3'd2, ST_DONE = 3'd3, ST_DROP = 3'd4;

reg        hold_q = 0;
reg  [2:0] st = ST_IDLE;
reg [30:0] tmo = 0;
reg  [8:0] gap = 0;

wire hold_fall = hold_q & ~init_hold & enable;
assign active   = (st != ST_IDLE) | hold_fall;
assign pre_mode = active;

initial begin req = 0; num = 0; flush = 0; end

always @(posedge clk) begin
	hold_q <= init_hold;
	flush  <= 1'b0;

	if (init_hold) begin
		st  <= ST_IDLE;
		req <= 1'b0;
	end
	else begin
		case (st)
			ST_IDLE:
				if (hold_fall) begin
					flush <= 1'b1;
					num   <= 16'hFFFF;
					req   <= 1'b1;
					tmo   <= 0;
					st    <= ST_REQ;
				end

			ST_REQ:                       // wait for the bridge to start mounting
				begin
					tmo <= tmo + 1'd1;
					if (mounting) begin tmo <= 0; st <= ST_MEND; end
					else if (tmo[24]) begin gap <= 0; st <= ST_DROP; end
				end

			ST_MEND:                      // wait for the mount to finish
				begin
					tmo <= tmo + 1'd1;
					if (!mounting) begin
						tmo <= 0; gap <= 0;
						if (missing) st <= ST_DROP;           // no heads file: nothing to preload
						else st <= ST_DONE;
					end
					else if (tmo[26]) begin gap <= 0; st <= ST_DROP; end
				end

			ST_DONE:                      // wait for the bulk load (ignore stale flags at first)
				begin
					tmo <= tmo + 1'd1;
					if (gap[8] == 1'b0) gap <= gap + 1'd1;
					if ((gap[8] && done) || tmo[30]) begin gap <= 0; st <= ST_DROP; end
				end

			ST_DROP:
				begin
					req <= 1'b0;
					gap <= gap + 1'd1;
					if (gap[7]) st <= ST_IDLE;
				end

			default: st <= ST_IDLE;
		endcase
	end
end

endmodule
