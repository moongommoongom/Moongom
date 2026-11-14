// This module is responsible for exposing MSU registers to the SNES for it to control

module MSU #(parameter MISTER_BUSY = 1'b0, parameter FAST_BUSY = 1'b0)   // FAST_BUSY: without a voice pack the game sees busy for ~1.5 ms only and a play write during the track open is kept (Area 88 style hooks that issue many track selects)
//   // 1 = test: exactly the MiSTer busy/play semantics (busy = track select only, play write always accepted, no watchdog)
(
	input             CLK,
	input             RST_N,
	input             ENABLE,

	input             RD_N,
	input             WR_N,
	input             SYSCLKF_CE,

	input      [23:0] ADDR,
	input       [7:0] DIN,
	output reg  [7:0] DOUT,
	output            MSU_SEL,

	output reg [15:0] track_num,
	output            track_request,
	input             track_mounting,

	// Audio player control
	output reg  [7:0] volume,
	output reg  [7:0] v_volume,           // volume of the voice stream (own register, the music volume stays untouched)
	input             status_track_missing,
	output reg        status_audio_repeat,
	output reg        status_audio_playing,
	input             audio_stop,
	input             AUDIO_READY,   // first PCM data of the mounted track is buffered
	input             HEAD_HIT,      // head of the selected track is already buffered (from the SRAM cache)
	output reg        audio_resume,
	// voice channel (tracks >= 1000 are played on a second stream, mixed over the music)
	input             v_en,
	output reg [15:0] v_track_num,
	output reg        v_track_request,
	input             v_mounting,
	input             v_not_ready,
	input             v_missing,
	output reg        v_play,
	input             v_audio_stop,       // the voice clip has ended
	input      [21:0] audio_sector,
	output reg [21:0] resume_sector,

	// Data track read
	output reg [31:0] data_addr,
	input       [7:0] data,
	input             data_ack,
	output reg        data_seek,
	output reg        data_req,

	output reg  [2:0] dbg_seen   // diagnostic: [0] $2002 read, [1] track select written, [2] play written
);


// Cached-track-head handling and the busy flag are declared first: they feed the status byte
reg        await_audio;
reg [25:0] await_to;
reg        hit_latch;
reg  [5:0] hit_wait;
reg  [5:0] v_wait;                // the voice stream has its OWN register window at $2010-$2017 (select/volume/play/status), independent of the music registers
reg [29:0] v_wd;
reg        v_mounting_old;
wire       v_busy_raw        = (v_wait != 0) | v_track_request | v_mounting | v_not_ready;
// watchdog: the game polls "busy" in a loop; never let a stuck stream hold it (black screen) for more than ~0.5 s
reg [23:0] v_bto;
reg        v_bto_hit;
wire       v_busy_eff        = v_busy_raw & ~v_bto_hit;
reg [23:0] t_bto;
wire       v_missing_eff     = v_en ? v_missing : 1'b1;      // no voice pack: every voice clip reads as missing at once
wire       status_audio_busy = (track_request | await_audio) & ~hit_latch;
reg [15:0] fb_cnt;
reg        rerq;          // FAST_BUSY: a track was selected while the previous one was still opening: open it right after
reg  [8:0] rq_gap;
wire       fb_on             = FAST_BUSY & ~v_en;
wire       status_audio_busy_vis = status_audio_busy & ~(fb_on & (fb_cnt[15:12] >= 4'd9));   // ~1.7 ms at 21.5 MHz
wire       track_missing_eff = status_track_missing & ~hit_latch;

// Read 'registers'
// MSU_STATUS - $2000
// Status bits
localparam [2:0] status_revision = 3'b010;
wire [7:0] MSU_STATUS = {
	status_data_busy,
	status_audio_busy_vis,
	status_audio_repeat,
	status_audio_playing,
	track_missing_eff,
	status_revision
};
// voice status ($2010): same layout, own flags
wire [7:0] V_STATUS = {1'b0, v_busy_eff, 1'b0, v_play, v_missing_eff, status_revision};

// Write register buffers excl MSB
reg [23:0] MSU_SEEK;   // $2000 - $2003
reg [ 7:0] MSU_TRACK;  // $2004 - $2005
reg [ 7:0] V_TRACK;    // $2014 - $2015

// banks 00-3F and 80-BF, address 2000-2007 (music) and 2010-2017 (voice)
wire   SEL   = ENABLE && !ADDR[22] && (ADDR[15:5] == 11'h100) && !ADDR[3];
// $2008-$200F: savestate shadow window. read: $2008/9 play position (1.5 s steps), $200C/D track, $200E volume, $200F flags
// write: $2008-A resume position, $200C/D/E = track select/commit/volume (same logic as $2004-$2006), $200F flags (direct)
wire   SHSEL = ENABLE && !ADDR[22] && (ADDR[15:3] == 13'h401);
assign MSU_SEL = SEL | SHSEL;
wire   MSU_VSEL = ADDR[4];

// Keep audio_busy asserted after a track select until the first PCM data has
// been prefetched (or a timeout), so the game's play command starts sound at once.
localparam [25:0] await_lim = 26'd21477000;  // wait at most ~1 s for the prebuffer
reg [15:0] resume_track_num;
reg        resume_valid;

reg status_data_busy;
reg data_ack_old;
reg track_mounting_old;

reg  data_rd_old;
wire data_rd = SEL && !MSU_VSEL && !RD_N && ADDR[2:0] == 1 && !status_data_busy;

always @(posedge CLK) begin
	if (~RST_N) begin
		data_addr <= 0;
		track_num <= 0;
		track_request <= 0;
		volume <= 0;
		v_volume <= 8'hFF;
		status_audio_playing <= 0;
		audio_resume <= 0;
		status_audio_repeat <= 0;
		status_data_busy <= 0;
		track_mounting_old <= 0;
		dbg_seen <= 3'd0;
		data_ack_old <= 0;
		data_rd_old <= 0;
		resume_valid <= 0;
		data_req <= 0;
		data_seek <= 0;
		await_audio <= 0;
		await_to <= 0;
		hit_latch <= 0;
		hit_wait <= 0;
		v_wait <= 0;
		v_wd <= 0;
		v_mounting_old <= 0;
		v_track_request <= 0;
		v_track_num <= 0;
		v_play <= 0;
		v_bto <= 0; v_bto_hit <= 0; t_bto <= 0; fb_cnt <= 16'hFFFF; rerq <= 0; rq_gap <= 0;
	end
	else begin

		// Set/reset pulsed signals
		data_req <= 0;
		audio_resume <= 0;
		if (audio_stop) status_audio_playing <= 0;
		if (v_audio_stop) v_play <= 1'b0;      // play the voice clip only once
		v_wd <= v_play ? (v_wd + 1'd1) : 30'd0;
		if (&v_wd) v_play <= 1'b0;             // safety: never stay in "playing" forever (about 50 s)

		// Rising edge of data busy
		data_ack_old <= data_ack;
		if (!data_ack_old && data_ack) begin
			status_data_busy <= 0;
			data_seek <= 0;
		end

		if (fb_cnt != 16'hFFFF) fb_cnt <= fb_cnt + 1'd1;

		// Cached track head: audio is ready at once, the file opens in the background
		if (hit_wait != 0) hit_wait <= hit_wait - 1'd1;
		else if (HEAD_HIT && track_request) hit_latch <= 1'b1;

		// Prefetch wait
		if (await_audio) begin
			await_to <= await_to + 1'd1;
			if (!track_request && !track_mounting && (AUDIO_READY || status_track_missing)) await_audio <= 0;
			else if (await_to >= await_lim) await_audio <= 0;
		end

		// busy watchdogs
		if (!v_busy_raw) begin v_bto <= 24'd0; v_bto_hit <= 1'b0; end
		else if (v_bto == 24'd10700000) v_bto_hit <= 1'b1;
		else v_bto <= v_bto + 1'd1;
		if (!track_request) t_bto <= 24'd0;
		else if (!MISTER_BUSY && t_bto == 24'd10700000) begin track_request <= 1'b0; await_audio <= 1'b0; t_bto <= 24'd0; end
		else t_bto <= t_bto + 1'd1;

		// voice stream bookkeeping
		if (v_wait != 0) v_wait <= v_wait - 1'd1;
		v_mounting_old <= v_mounting;
		if (v_mounting_old && !v_mounting) v_track_request <= 0;

		// Falling edge of track mounting
		track_mounting_old <= track_mounting;
		if (track_mounting_old && !track_mounting) begin
			track_request <= 0;
			if (rerq) begin rerq <= 1'b0; rq_gap <= 9'd400; end
		end
		if (rq_gap != 0) begin
			rq_gap <= rq_gap - 1'd1;
			if (rq_gap == 9'd1) begin track_request <= 1'b1; hit_latch <= 1'b0; end
		end

		// Register writes: music window
		if ((SEL | SHSEL) & ~MSU_VSEL & SYSCLKF_CE & ~WR_N) begin
			case (ADDR[2:0])
				0: if (!ADDR[3]) MSU_SEEK[7:0]   <= DIN;
				1: if (!ADDR[3]) MSU_SEEK[15:8]  <= DIN;
				2: if (!ADDR[3]) MSU_SEEK[23:16] <= DIN;
				3: if (!ADDR[3]) begin 
					data_addr <= {DIN, MSU_SEEK};
					data_seek <= 1;
					status_data_busy <= 1;
				end
				4: MSU_TRACK <= DIN;
				5: begin
					track_num <= {DIN, MSU_TRACK};
					track_request <= 1;
					if (fb_on && track_request) rerq <= 1'b1;
					rq_gap <= 9'd0;
					await_audio <= v_en & ~MISTER_BUSY;   // extended busy (wait for the first PCM data) only with a voice pack (.ms1, FF6); other games get MiSTer-style busy: only while the track file is opened
					await_to <= 0;
					hit_latch <= 0;
					hit_wait <= 6'd32;
					fb_cnt <= 16'd0;
					status_audio_playing <= 0;
					status_audio_repeat <= 0;
					if ((resume_valid && resume_track_num == {DIN, MSU_TRACK}) || SHSEL) begin
						audio_resume <= 1;
						resume_valid <= 0;
					end
				end
				6: volume <= DIN;
				7: if (SHSEL || MISTER_BUSY || fb_on || (!status_audio_busy && !track_missing_eff)) begin
					status_audio_repeat <= DIN[1];
					status_audio_playing <= DIN[0];
					if (DIN[2] && !DIN[0]) begin
						resume_track_num <= track_num;
						resume_sector <= audio_sector;
						resume_valid <= 1;
					end
				end
			endcase
		end

		if (SHSEL & SYSCLKF_CE & ~WR_N) case (ADDR[2:0])
			0: resume_sector[15:8]  <= DIN;
			1: begin resume_sector[21:16] <= DIN[5:0]; resume_sector[7:0] <= 8'd0; end
		endcase

		// Register writes: voice window ($2014/5 select, $2016 volume, $2017 play; a stop write is ignored: a clip plays to its end or until the next select)
		if (SEL & MSU_VSEL & SYSCLKF_CE & ~WR_N) begin
			case (ADDR[2:0])
				4: V_TRACK <= DIN;
				5: if (v_en) begin
					v_track_num     <= {DIN, V_TRACK};
					v_track_request <= 1'b1;
					v_wait          <= 6'd48;
					v_play          <= 1'b0;
				end
				6: v_volume <= DIN;
				7: if (!v_busy_eff && !v_missing_eff && DIN[0]) v_play <= 1'b1;
			endcase
		end

		if (SEL & ~MSU_VSEL & ~RD_N & ADDR[2:0] == 3'd2) dbg_seen[0] <= 1'b1;
		if (SEL & ~MSU_VSEL & SYSCLKF_CE & ~WR_N & ADDR[2:0] == 3'd5) dbg_seen[1] <= 1'b1;
		if (SEL & ~MSU_VSEL & SYSCLKF_CE & ~WR_N & ADDR[2:0] == 3'd7 & DIN[0]) dbg_seen[2] <= 1'b1;

		// Advance data pointer after read
		data_rd_old <= data_rd;
		if (data_rd_old & ~data_rd) begin
			data_addr <= data_addr + 1;
			data_req <= 1'b1;
		end

		if (ADDR[3]) case (ADDR[2:0])
			0: DOUT <= audio_sector[15:8];
			1: DOUT <= {2'd0, audio_sector[21:16]};
			4: DOUT <= track_num[7:0];
			5: DOUT <= track_num[15:8];
			6: DOUT <= volume;
			default: DOUT <= {6'd0, status_audio_repeat, status_audio_playing};
		endcase
		else case (ADDR[2:0])
			0: DOUT <= MSU_VSEL ? V_STATUS : MSU_STATUS;
			1: DOUT <= data;
			2: DOUT <= "S";
			3: DOUT <= "-";
			4: DOUT <= "M";
			5: DOUT <= "S";
			6: DOUT <= "U";
			7: DOUT <= "1";
		endcase
	end
end

endmodule
