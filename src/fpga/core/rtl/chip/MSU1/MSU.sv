// This module is responsible for exposing MSU registers to the SNES for it to control

module MSU
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
	output reg        data_req
);


// Cached-track-head handling and the busy flag are declared first: they feed the status byte
reg        await_audio;
reg [25:0] await_to;
reg        hit_latch;
reg  [5:0] hit_wait;
reg        v_ctx;            // the last track select was a voice clip: status/play writes belong to the voice stream
reg  [5:0] v_wait;
reg [29:0] v_wd;
reg        v_mounting_old;
wire       v_busy_eff        = (v_wait != 0) | v_track_request | v_mounting | v_not_ready;
wire       status_audio_busy = v_ctx ? v_busy_eff : ((track_request | await_audio) & ~hit_latch);
wire       track_missing_eff = v_ctx ? v_missing : (status_track_missing & ~hit_latch);

// Read 'registers'
// MSU_STATUS - $2000
// Status bits
localparam [2:0] status_revision = 3'b010;
wire [7:0] MSU_STATUS = {
	status_data_busy,
	status_audio_busy,
	status_audio_repeat,
	status_audio_playing | v_play,        // a playing voice clip also shows as "audio playing" (the game waits for it)
	track_missing_eff,
	status_revision
};

// Write register buffers excl MSB
reg [23:0] MSU_SEEK;   // $2000 - $2003
reg [ 7:0] MSU_TRACK;  // $2004 - $2005

// banks 00-3F and 80-BF, address 2000-2007
assign MSU_SEL = ENABLE && !ADDR[22] && (ADDR[15:4] == 'h200) && !ADDR[3];

// Keep audio_busy asserted after a track select until the first PCM data has
// been prefetched (or a timeout), so the game's play command starts sound at once.
localparam [25:0] await_lim = 26'd21477000;  // wait at most ~1 s for the prebuffer
reg [15:0] resume_track_num;
reg        resume_valid;

reg status_data_busy;
reg data_ack_old;
reg track_mounting_old;

reg  data_rd_old;
wire data_rd = MSU_SEL && !RD_N && ADDR[2:0] == 1 && !status_data_busy;

always @(posedge CLK) begin
	if (~RST_N) begin
		data_addr <= 0;
		track_num <= 0;
		track_request <= 0;
		volume <= 0;
		status_audio_playing <= 0;
		audio_resume <= 0;
		status_audio_repeat <= 0;
		status_data_busy <= 0;
		track_mounting_old <= 0;
		data_ack_old <= 0;
		data_rd_old <= 0;
		resume_valid <= 0;
		data_req <= 0;
		data_seek <= 0;
		await_audio <= 0;
		await_to <= 0;
		hit_latch <= 0;
		hit_wait <= 0;
		v_ctx <= 0;
		v_wait <= 0;
		v_wd <= 0;
		v_mounting_old <= 0;
		v_track_request <= 0;
		v_track_num <= 0;
		v_play <= 0;
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

		// Cached track head: audio is ready at once, the file opens in the background
		if (hit_wait != 0) hit_wait <= hit_wait - 1'd1;
		else if (HEAD_HIT && track_request) hit_latch <= 1'b1;

		// Prefetch wait
		if (await_audio) begin
			await_to <= await_to + 1'd1;
			if (!track_request && !track_mounting && (AUDIO_READY || status_track_missing)) await_audio <= 0;
			else if (await_to >= await_lim) await_audio <= 0;
		end

		// voice stream bookkeeping
		if (v_wait != 0) v_wait <= v_wait - 1'd1;
		v_mounting_old <= v_mounting;
		if (v_mounting_old && !v_mounting) v_track_request <= 0;

		// Falling edge of track mounting
		track_mounting_old <= track_mounting;
		if (track_mounting_old && !track_mounting) track_request <= 0;

		// Register writes
		if (MSU_SEL & SYSCLKF_CE & ~WR_N) begin
			case (ADDR[2:0])
				0: MSU_SEEK[7:0]   <= DIN;
				1: MSU_SEEK[15:8]  <= DIN;
				2: MSU_SEEK[23:16] <= DIN;
				3: begin 
					data_addr <= {DIN, MSU_SEEK};
					data_seek <= 1;
					status_data_busy <= 1;
				end
				4: MSU_TRACK <= DIN;
				5: if (v_en && {DIN, MSU_TRACK} >= 16'd1000) begin
					v_ctx           <= 1'b1;
					v_track_num     <= {DIN, MSU_TRACK};
					v_track_request <= 1'b1;
					v_wait          <= 6'd48;
					v_play          <= 1'b0;
				end
				else begin
					v_ctx <= 1'b0;
					track_num <= {DIN, MSU_TRACK};
					track_request <= 1;
					await_audio <= 1'b1;
					await_to <= 0;
					hit_latch <= 0;
					hit_wait <= 6'd32;
					status_audio_playing <= 0;
					status_audio_repeat <= 0;
					if (resume_valid && resume_track_num == {DIN, MSU_TRACK}) begin
						audio_resume <= 1;
						resume_valid <= 0;
					end
				end
				6: volume <= DIN;
				7: if (v_ctx) begin
					if (!v_busy_eff && !v_missing) v_play <= DIN[0];
					v_ctx <= 1'b0;                       // the play command ends the voice context
				end
				else begin
					if (!DIN[0]) v_play <= 1'b0;         // a stop command stops a playing voice clip too (one stream like real MSU-1)
					if (!status_audio_busy && !track_missing_eff) begin
						status_audio_repeat <= DIN[1];
						status_audio_playing <= DIN[0];
						if (DIN[2] && !DIN[0]) begin
							resume_track_num <= track_num;
							resume_sector <= audio_sector;
							resume_valid <= 1;
						end
					end
				end
			endcase
		end

		// Advance data pointer after read
		data_rd_old <= data_rd;
		if (data_rd_old & ~data_rd) begin
			data_addr <= data_addr + 1;
			data_req <= 1'b1;
		end

		case (ADDR[2:0])
			0: DOUT <= MSU_STATUS;
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
