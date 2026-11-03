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
//
// PCM file: "MSU1", u32 loop point (in stereo frames), then 16-bit LE stereo samples.

module msu_audio
(
	input             reset,

	input             clk,
	input      [31:0] clk_rate,

	input      [7:0]  ctl_volume,
	input             ctl_repeat,
	input             ctl_play,
	input             ctl_resume,
	output reg        ctl_stop,

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

localparam [15:0] CHUNK_BYTES = 16'd8192;           // 2048 stereo frames
localparam [11:0] REFILL_LEVEL = 12'd2048;          // fetch when FIFO holds <= this many frames

localparam [3:0] S_IDLE   = 4'd0;
localparam [3:0] S_HDR    = 4'd1;
localparam [3:0] S_WAIT   = 4'd2;
localparam [3:0] S_SETTLE = 4'd3;
localparam [3:0] S_SPACE  = 4'd4;
localparam [3:0] S_DATA   = 4'd5;
localparam [3:0] S_END    = 4'd6;
localparam [3:0] S_DRAIN  = 4'd7;

wire        fifo_full;
wire [11:0] fifo_usedw;
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

initial begin
	fetch_tgl = 0;
	fetch_off = 0;
	fetch_len = 0;
	ctl_stop  = 0;
end

assign audio_sector = pos[31:10];

wire done_changed = (fetch_done_tgl != done_prev);

wire [31:0] remaining  = track_size - pos;
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
	end
	else begin
		case (state)
			S_IDLE:
				begin
					if (~track_processing & ctl_play & (hold == 0) & (|track_size)) begin
						if (resuming && resume_sector != 0) begin
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

			// Let the tail of the transfer trickle through data_loader
			S_SETTLE:
				begin
					settle <= settle + 1'd1;
					if (settle == 8'd255) begin
						if (!last_err) begin
							pos      <= pos + {16'b0, cur_len};
							skip_cnt <= 10'd0;
							retries  <= 0;
							state    <= S_SPACE;
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
				if (!pos_valid) state <= S_END;
				else if (fifo_usedw <= REFILL_LEVEL) state <= S_DATA;

			S_DATA:
				begin
					// Whole dwords only, at most one chunk
					cur_len   <= (remaining >= {16'b0, CHUNK_BYTES}) ? CHUNK_BYTES : {remaining[15:2], 2'b00};
					skip_cur  <= skip_cnt;
					first_cur <= (pos == 32'd0);
					fetch_off <= pos;
					fetch_len <= (remaining >= {16'b0, CHUNK_BYTES}) ? CHUNK_BYTES : {remaining[15:2], 2'b00};
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
	end
end

// ---------------------------------------------------------------------------
// Incoming 16-bit words -> 32-bit stereo frames -> FIFO
// ---------------------------------------------------------------------------
reg  [15:0] lo_word;
reg         wcnt = 0;
reg  [11:0] dcnt = 0;
reg         fifo_wr = 0;
reg  [31:0] fifo_din;

always @(posedge clk) begin
	fifo_wr <= 0;

	if (state != S_WAIT && state != S_SETTLE) begin
		wcnt <= 0;
		dcnt <= 0;
	end
	else if (pcm_wr) begin
		if (!wcnt) begin
			lo_word <= pcm_data;
			wcnt    <= 1;
		end
		else begin
			wcnt     <= 0;
			fifo_din <= {pcm_data, lo_word};
			if (first_cur && dcnt == 12'd1) loop_index <= {pcm_data, lo_word} + 32'd2;
			if (dcnt >= {2'b00, skip_cur}) fifo_wr <= 1;
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

wire        playing = ctl_play & ~track_processing & ~fifo_empty;
wire [15:0] sample_l;
wire [15:0] sample_r;

msu_fifo #(32,12) audio_fifo
(
	.aclr(track_processing),

	.wrclk(clk),
	.wrreq(fifo_wr & ~fifo_full),
	.data(fifo_din),
	.wrfull(fifo_full),
	.wrusedw(fifo_usedw),

	.rdclk(clk),
	.q({sample_r,sample_l}),
	.rdreq(sample_ce & playing),
	.rdempty(fifo_empty),
	.rdusedw()
);

wire [23:0] vol_mix_l = $signed(sample_l) * $signed({1'b0, ctl_volume});
wire [23:0] vol_mix_r = $signed(sample_r) * $signed({1'b0, ctl_volume});
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
