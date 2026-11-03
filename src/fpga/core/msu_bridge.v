//
// msu_bridge.v -- MSU-1 <-> Analogue APF glue (runs on clk_74a)
//
// Replaces MiSTer's hps_ext.v.  Responsibilities:
//  * After Pocket releases reset, find the ROM's path (target cmd 0190), derive
//    "<rom>.msu" from it (replace the extension) and open it into the MSU data slot
//    (target cmd 0192).  If the file exists, MSU-1 is enabled.  The SNES core is held
//    in reset (init_hold) until this is done, so games can detect MSU-1 at boot.
//  * Track requests ($2004/5): open "<rom>-<track>.pcm" into the PCM slot, report
//    missing / size, and drive track_mounting.
//  * Audio chunk reads and data-cache block reads -> target cmd 0180 (data slot read).
//    The host writes the bytes to bridge addresses 0x3xxxxxxx (PCM) and
//    0x4xxxxxxx (data cache); data_loader instances in core_top pick them up.
//
// The path string lives in a 512 byte buffer (pathbuf in core_top, bridge address
// 0x50000000) so that Pocket can write the ROM path into it and read the derived
// path out of it.  Byte 0 of the string is bits [31:24] of word 0 (big-endian bridge).
//
module msu_bridge #(
	parameter [15:0] SLOT_ROM = 16'd0,
	parameter [15:0] SLOT_MSU = 16'd20,
	parameter [15:0] SLOT_PCM = 16'd21,
	parameter  [7:0] IDX_MSU  = 8'd2,      // position of the slot in data.json
	parameter  [7:0] IDX_PCM  = 8'd3
) (
	input  wire        clk,                // clk_74a
	input  wire        clk_sys,
	input  wire        reset_n,            // Pocket released the core from reset

	// target command channel (core_bridge_cmd)
	output reg         tc_req,
	output reg  [15:0] tc_code,
	output reg  [31:0] tc_p0,
	output reg  [31:0] tc_p1,
	output reg  [31:0] tc_p2,
	output reg  [31:0] tc_p3,
	input  wire        tc_done,
	input  wire [15:0] tc_result,

	// data slot size table (read through core_top's datatable port A mux)
	output reg   [7:0] dt_addr,
	input  wire [31:0] dt_q,
	input  wire        dt_valid,

	// path buffer, port B (byte lanes: lane0 = bits [31:24])
	output reg   [6:0] pb_addr,
	output reg   [3:0] pb_we,
	output reg   [7:0] pb_din,
	input  wire [31:0] pb_q,

	// ---- clk_sys side ----
	input  wire        track_request,
	input  wire [15:0] track_num,
	output wire        msu_enable,
	output wire        track_mounting,
	output wire        track_missing,
	output wire [31:0] audio_size,
	output wire [31:0] data_size,
	output wire        init_hold,
	output wire  [3:0] diag_sys,      // debug: init result as beep count

	input  wire        a_fetch_tgl,
	input  wire [31:0] a_fetch_off,
	input  wire [15:0] a_fetch_len,
	output wire        a_done_tgl,
	output wire        a_err,

	input  wire        d_fill_tgl,
	input  wire [31:0] d_fill_off,
	input  wire [15:0] d_fill_len,
	input  wire  [1:0] d_fill_slot,
	output wire        d_done_tgl,
	output wire        d_err
);

localparam [31:0] PB_BASE  = 32'h5000_0000;
localparam [31:0] PCM_BASE = 32'h3000_0000;
localparam [31:0] DAT_BASE = 32'h4000_0000;

// ---------------------------------------------------------------------------
// Status registers (clk domain) and their clk_sys views
// ---------------------------------------------------------------------------
reg        enable_r = 0;
reg        mounting_r = 0;
reg        missing_r = 0;
reg [31:0] asize_r = 0;
reg [31:0] dsize_r = 0;
reg        hold_r = 0;
reg  [3:0] diag_r = 0;
synch_3 s_dg0 (.i(diag_r[0]), .o(diag_sys[0]), .clk(clk_sys), .rise(), .fall());
synch_3 s_dg1 (.i(diag_r[1]), .o(diag_sys[1]), .clk(clk_sys), .rise(), .fall());
synch_3 s_dg2 (.i(diag_r[2]), .o(diag_sys[2]), .clk(clk_sys), .rise(), .fall());
synch_3 s_dg3 (.i(diag_r[3]), .o(diag_sys[3]), .clk(clk_sys), .rise(), .fall());
reg        a_done_r = 0, a_err_r = 0;
reg        d_done_r = 0, d_err_r = 0;

synch_3 s_en   (.i(enable_r),   .o(msu_enable),     .clk(clk_sys), .rise(), .fall());
synch_3 s_mnt  (.i(mounting_r), .o(track_mounting), .clk(clk_sys), .rise(), .fall());
synch_3 s_mis  (.i(missing_r),  .o(track_missing),  .clk(clk_sys), .rise(), .fall());
synch_3 s_hold (.i(hold_r),     .o(init_hold),      .clk(clk_sys), .rise(), .fall());
synch_3 s_adn  (.i(a_done_r),   .o(a_done_tgl),     .clk(clk_sys), .rise(), .fall());
synch_3 s_ddn  (.i(d_done_r),   .o(d_done_tgl),     .clk(clk_sys), .rise(), .fall());

assign audio_size = asize_r;
assign data_size  = dsize_r;
assign a_err      = a_err_r;
assign d_err      = d_err_r;

wire req_s, a_s, d_s;
synch_3 s_req (.i(track_request), .o(req_s), .clk(clk), .rise(), .fall());
synch_3 s_atg (.i(a_fetch_tgl),   .o(a_s),   .clk(clk), .rise(), .fall());
synch_3 s_dtg (.i(d_fill_tgl),    .o(d_s),   .clk(clk), .rise(), .fall());

// ---------------------------------------------------------------------------
// Suffix generator ("-123.pcm" / ".msu")
// ---------------------------------------------------------------------------
// digits are produced by a registered pipeline (see sfx_pipe below), so no
// divider ends up in the clk_74a critical path.
function [7:0] sfx_char(input mode, input [3:0] nd, input [19:0] dg, input [3:0] j);
	reg [3:0] k;
	reg [3:0] e;
	begin
		sfx_char = 8'h00;
		if (mode) begin
			case (j)
				4'd0: sfx_char = ".";
				4'd1: sfx_char = "m";
				4'd2: sfx_char = "s";
				4'd3: sfx_char = "u";
				default: sfx_char = 8'h00;
			endcase
		end
		else if (j == 4'd0) begin
			sfx_char = "-";
		end
		else if (j <= nd) begin
			e = nd - j;                                  // j=1 -> most significant digit
			sfx_char = 8'h30 + {4'd0, dg[{e[2:0], 2'b00} +: 4]};
		end
		else begin
			k = j - nd;
			case (k)
				4'd1: sfx_char = ".";
				4'd2: sfx_char = "p";
				4'd3: sfx_char = "c";
				4'd4: sfx_char = "m";
				default: sfx_char = 8'h00;
			endcase
		end
	end
endfunction

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
localparam [5:0]
	ST_IDLE     = 6'd0,
	ST_CMD_GO   = 6'd1,
	ST_CMD_WAIT = 6'd2,
	ST_CMD_REL  = 6'd3,
	ST_DTW      = 6'd4,
	// init
	ST_I_NAME   = 6'd8,
	ST_SC_ADDR  = 6'd9,
	ST_SC_W     = 6'd10,
	ST_SC_EVAL  = 6'd11,
	ST_FL0      = 6'd12,
	ST_FL1      = 6'd13,
	ST_FL2      = 6'd14,
	ST_I_OPEN   = 6'd15,
	ST_I_SZ     = 6'd16,
	ST_I_SZ2    = 6'd17,
	ST_I_END    = 6'd18,
	// suffix writer
	ST_WR_START = 6'd20,
	ST_WR_CH    = 6'd21,
	ST_WR_COMMIT= 6'd22,
	// track
	ST_T_OPEN   = 6'd24,
	ST_T_SZ     = 6'd25,
	ST_T_SZ2    = 6'd26,
	ST_T_FIN    = 6'd27,
	// transfers
	ST_A_FIN    = 6'd28,
	ST_D_FIN    = 6'd29,
	// probe: open the unmodified ROM path first (diagnostics)
	ST_P_OPEN   = 6'd30,
	ST_P_RES    = 6'd31,
	// literal-path fallback probe
	ST_L_CH     = 6'd32,
	ST_L_COMMIT = 6'd33,
	ST_L_OPEN   = 6'd34,
	ST_L_RES    = 6'd35,
	// data slot table scan by slot id (as the reference core does)
	ST_SCN_S    = 6'd36,
	ST_SCN_C    = 6'd37,
	ST_SCN_D    = 6'd38;

initial begin
	tc_req = 0; tc_code = 0; tc_p0 = 0; tc_p1 = 0; tc_p2 = 0; tc_p3 = 0;
	dt_addr = 0; pb_addr = 0; pb_we = 0; pb_din = 0;
end

reg  [5:0] state = ST_IDLE;
reg  [5:0] ret_cmd = ST_IDLE;     // state after a command completes
reg  [5:0] ret_wr  = ST_IDLE;     // state after the suffix was written
reg  [5:0] ret_dt  = ST_IDLE;     // state after a size-table read
reg [15:0] res = 0;

reg        rn_d = 0;
reg        init_done = 0;
reg        path_ok = 0;
reg [27:0] init_to = 0;
reg        req_seen = 0;
reg        a_ack = 0, d_ack = 0;

reg  [7:0] scan_i = 0;
reg  [7:0] dot_pos = 0;
reg        dot_valid = 0;
reg  [7:0] dpos = 0;              // index where the suffix starts

reg        sfx_mode = 0;          // 0: track pcm, 1: data msu
reg [15:0] sfx_track = 0;
reg  [3:0] wr_j = 0;
reg  [3:0] sfx_nd = 4'd1;
reg [19:0] sfx_dg = 20'd0;
// 16-cycle shift-add-3 (double dabble) binary->BCD, restarted whenever sfx_track
// changes. Keeps the clk_74a critical path short (no divider).
function [19:0] dd_adj(input [19:0] b);
	integer i;
	begin
		for (i = 0; i < 5; i = i + 1)
			dd_adj[i*4 +: 4] = (b[i*4 +: 4] >= 4'd5) ? (b[i*4 +: 4] + 4'd3) : b[i*4 +: 4];
	end
endfunction
reg [15:0] dd_last = 16'hFFFF;
reg [15:0] dd_bin  = 0;
reg [19:0] dd_bcd  = 0;
reg  [4:0] dd_cnt  = 0;
reg        dd_run  = 0;
wire [19:0] dd_a   = dd_adj(dd_bcd);
wire [19:0] dd_nxt = {dd_a[18:0], dd_bin[15]};
always @(posedge clk) begin
	if (dd_last != sfx_track) begin
		dd_last <= sfx_track;
		dd_bin  <= sfx_track;
		dd_bcd  <= 20'd0;
		dd_cnt  <= 5'd0;
		dd_run  <= 1'b1;
	end
	else if (dd_run) begin
		dd_bcd <= dd_nxt;
		dd_bin <= {dd_bin[14:0], 1'b0};
		dd_cnt <= dd_cnt + 1'd1;
		if (dd_cnt == 5'd15) begin
			dd_run <= 1'b0;
			sfx_dg <= dd_nxt;
		end
	end
	sfx_nd <= (sfx_track >= 16'd10000) ? 4'd5 :
	          (sfx_track >= 16'd1000)  ? 4'd4 :
	          (sfx_track >= 16'd100)   ? 4'd3 :
	          (sfx_track >= 16'd10)    ? 4'd2 : 4'd1;
end
reg  [4:0] wr_wait = 0;
reg        wr_wait_run = 0;
wire [3:0] wr_jend = sfx_mode ? 4'd4 : (sfx_nd + 4'd5);
wire [8:0] wr_idx  = {1'b0, dpos} + {5'b0, wr_j};

reg  [7:0] wcnt = 0;
reg [31:0] dt_sz = 0;
reg [15:0] scan_id = 0;
reg  [5:0] scan_next = 0;
reg [31:0] scan_sz = 0;

reg [15:0] r2 = 16'hFFFF;
reg [15:0] r3 = 16'hFFFF;
reg [15:0] res_fin = 16'hFFFF;
reg  [5:0] lj = 0;
localparam [8*44-1:0] LIT = "/Assets/snes/common/FF6/FF6_Enhanced(ko).msu";
wire [7:0] lit_ch = (lj < 6'd44) ? LIT[8*(43-lj) +: 8] : 8'h00;
reg        retried = 0;
reg        ord_r = 0;      // 1: first path byte arrives in bits [7:0] (little endian)
wire       first_big = (pb_q[31:24] == 8'h2F);
wire       first_lit = (pb_q[7:0]   == 8'h2F);
wire       ord_eff   = (scan_i == 8'd0) ? (!first_big && first_lit) : ord_r;
reg  [7:0] ch;
always @(*) begin
	case (scan_i[1:0] ^ {2{ord_eff}})
		2'd0: ch = pb_q[31:24];
		2'd1: ch = pb_q[23:16];
		2'd2: ch = pb_q[15:8];
		default: ch = pb_q[7:0];
	endcase
end

always @(posedge clk) begin
	rn_d <= reset_n;
	if (dt_valid) dt_sz <= dt_q;

	if (hold_r) init_to <= init_to + 1'd1;
	else        init_to <= 0;

	if (!(req_s)) req_seen <= 0;

	if (!reset_n) begin
		// Pocket holds the core in reset: forget everything
		state      <= ST_IDLE;
		tc_req     <= 0;
		pb_we      <= 0;
		init_done  <= 0;
		path_ok    <= 0;
		hold_r     <= 0;
		enable_r   <= 0;
		diag_r     <= 0;
		retried    <= 0;
		mounting_r <= 0;
		missing_r  <= 0;
		asize_r    <= 0;
		dsize_r    <= 0;
		a_ack      <= a_s;
		d_ack      <= d_s;
	end
	else if (!rn_d) begin
		// reset just released: start initialisation and hold the SNES in reset
		hold_r    <= 1;
		init_done <= 0;
		state     <= ST_IDLE;
	end
	else if (hold_r && init_to == 28'h8F0_0000) begin
		// Pocket never answered: give up, run without MSU-1
		diag_r    <= 4'd7;
		hold_r    <= 0;
		init_done <= 1;
		enable_r  <= 0;
		tc_req    <= 0;
		pb_we     <= 0;
		state     <= ST_IDLE;
	end
	else begin
		case (state)
			ST_IDLE:
				begin
					if (!init_done) begin
						// 0190: get filename of the ROM slot
						tc_code <= 16'h0190;
						tc_p0   <= {16'b0, SLOT_ROM};
						tc_p1   <= PB_BASE;
						ret_cmd <= ST_I_NAME;
						state   <= ST_CMD_GO;
					end
					else if (req_s && !req_seen) begin
						req_seen   <= 1;
						mounting_r <= 1;
						missing_r  <= 0;
						asize_r    <= 0;
						wcnt       <= 0;
						if (!path_ok || !enable_r) begin
							missing_r <= 1;
							state     <= ST_T_FIN;
						end
						else begin
							diag_r    <= 4'd0;             // silent while mounting
							sfx_mode  <= 0;
							sfx_track <= track_num;
							ret_wr    <= ST_T_OPEN;
							state     <= ST_WR_START;
						end
					end
					else if (a_s != a_ack) begin
						a_ack   <= a_s;
						tc_code <= 16'h0180;
						tc_p0   <= {16'b0, SLOT_PCM};
						tc_p1   <= a_fetch_off;
						tc_p2   <= PCM_BASE;
						tc_p3   <= {16'b0, a_fetch_len};
						ret_cmd <= ST_A_FIN;
						state   <= ST_CMD_GO;
					end
					else if (d_s != d_ack) begin
						d_ack   <= d_s;
						tc_code <= 16'h0180;
						tc_p0   <= {16'b0, SLOT_MSU};
						tc_p1   <= d_fill_off;
						tc_p2   <= DAT_BASE | {18'b0, d_fill_slot, 12'b0};
						tc_p3   <= {16'b0, d_fill_len};
						ret_cmd <= ST_D_FIN;
						state   <= ST_CMD_GO;
					end
				end

			// ---- generic target command ----
			ST_CMD_GO:
				begin
					tc_req <= 1;
					state  <= ST_CMD_WAIT;
				end
			ST_CMD_WAIT:
				if (tc_done) begin
					res    <= tc_result;
					tc_req <= 0;
					state  <= ST_CMD_REL;
				end
			ST_CMD_REL:
				if (!tc_done) state <= ret_cmd;

			// ---- slot size table read: wait for the core_top mux to cycle ----
			ST_DTW:
				begin
					wcnt <= wcnt + 1'd1;
					if (wcnt == 8'd63) state <= ret_dt;
				end

			// ---- find the opened slot in the data slot table: [id, size] pairs ----
			ST_SCN_S:
				begin
					dt_addr <= 8'd0;
					wcnt    <= 0;
					scan_sz <= 32'd0;
					ret_dt  <= ST_SCN_C;
					state   <= ST_DTW;
				end
			ST_SCN_C:
				begin
					if (dt_sz[15:0] == scan_id) begin
						dt_addr <= dt_addr + 8'd1;   // size word follows the id
						wcnt    <= 0;
						ret_dt  <= ST_SCN_D;
						state   <= ST_DTW;
					end
					else if (dt_addr >= 8'd62) begin
						state <= scan_next;           // not found: size stays 0 (unknown)
					end
					else begin
						dt_addr <= dt_addr + 8'd2;
						wcnt    <= 0;
						ret_dt  <= ST_SCN_C;
						state   <= ST_DTW;
					end
				end
			ST_SCN_D:
				begin
					scan_sz <= dt_sz;
					state   <= scan_next;
				end

			// ---- init: ROM path received ----
			ST_I_NAME:
				begin
					if (res != 16'd0) begin
						diag_r <= 4'd1;
						state <= ST_I_END;           // no ROM path: MSU-1 stays off
					end
					else begin
						scan_i    <= 0;
						dot_valid <= 0;
						path_ok   <= 0;
						state     <= ST_SC_ADDR;
					end
				end

			ST_SC_ADDR:
				begin
					pb_addr <= scan_i[7:2];
					state   <= ST_SC_W;
				end
			ST_SC_W: state <= ST_SC_EVAL;
			ST_SC_EVAL:
				begin
					if (scan_i == 8'd0) ord_r <= ord_eff;
					if (ch == 8'h00) begin
						dpos  <= dot_valid ? dot_pos : scan_i;
						state <= ST_FL0;
						if ((dot_valid ? dot_pos : scan_i) > 8'd235) begin diag_r <= 4'd2; state <= ST_I_END; end  // path too long
					end
					else if (scan_i == 8'hFF) begin
						diag_r <= 4'd2;
						state <= ST_I_END;           // unterminated string
					end
					else begin
						if (ch == "/")      dot_valid <= 0;
						else if (ch == ".") begin dot_pos <= scan_i; dot_valid <= 1; end
						scan_i <= scan_i + 1'd1;
						state  <= ST_SC_ADDR;
					end
				end

			// zero the "operation flags" (0x100) and "size" (0x104) words of the struct
			ST_FL0:
				begin
					pb_addr <= 7'd64;
					pb_din  <= 8'h00;
					pb_we   <= 4'hF;
					state   <= ST_FL1;
				end
			ST_FL1:
				begin
					pb_addr <= 7'd65;
					state   <= ST_FL2;
				end
			ST_FL2:
				begin
					pb_we     <= 4'h0;
					path_ok   <= 1;
					sfx_mode  <= 1;                  // ".msu"
					sfx_track <= 16'd0;
					state     <= ST_P_OPEN;
				end

			ST_P_OPEN:
				begin
					tc_code <= 16'h0192;
					tc_p0   <= {16'b0, SLOT_MSU};
					tc_p1   <= PB_BASE;
					ret_cmd <= ST_P_RES;
					state   <= ST_CMD_GO;
				end
			ST_P_RES:
				begin
					r2     <= res;
					ret_wr <= ST_I_OPEN;
					state  <= ST_WR_START;
				end

			ST_I_OPEN:
				begin
					tc_code <= 16'h0192;
					tc_p0   <= {16'b0, SLOT_MSU};
					tc_p1   <= PB_BASE;
					ret_cmd <= ST_I_SZ;
					state   <= ST_CMD_GO;
				end
			ST_I_SZ:
				begin
					if (res == 16'd4 && !retried) begin
						// malformed path: retry once with the opposite byte lane order
						retried <= 1'b1;
						ord_r   <= ~ord_r;
						ret_wr  <= ST_I_OPEN;
						state   <= ST_WR_START;
					end
					else if (res > 16'd1) begin
						// derived path rejected: remember why, then probe a literal path
						res_fin <= res;
						lj      <= 6'd0;
						state   <= ST_L_CH;
					end
					else begin
						diag_r   <= 4'd0;                 // init OK: silent
						enable_r <= 1'b1;            // file opened: MSU-1 present
						scan_id   <= SLOT_MSU;
						scan_next <= ST_I_SZ2;
						state     <= ST_SCN_S;
					end
				end
			ST_L_CH:
				begin
					pb_addr <= {1'b0, lj[5:2]};
					pb_din  <= lit_ch;
					pb_we   <= 4'b0001 << lj[1:0];
					state   <= ST_L_COMMIT;
				end
			ST_L_COMMIT:
				begin
					pb_we <= 4'h0;
					if (lj == 6'd44) state <= ST_L_OPEN;
					else begin
						lj    <= lj + 1'd1;
						state <= ST_L_CH;
					end
				end
			ST_L_OPEN:
				begin
					tc_code <= 16'h0192;
					tc_p0   <= {16'b0, SLOT_MSU};
					tc_p1   <= PB_BASE;
					ret_cmd <= ST_L_RES;
					state   <= ST_CMD_GO;
				end
			ST_L_RES:
				begin
					r3 <= res;
					if (res <= 16'd1) begin
						// literal path works: use it (MSU-1 for this ROM)
						diag_r   <= 4'd0;
						enable_r <= 1'b1;
						dpos     <= 8'd40;
						scan_id   <= SLOT_MSU;
						scan_next <= ST_I_SZ2;
						state     <= ST_SCN_S;
					end
					else begin
						diag_r <= (res == 16'd4) ? 4'd14 : (res == 16'd3) ? 4'd13 : 4'd15;
						state  <= ST_I_END;
					end
				end
			ST_I_SZ2:
				begin
					// size table may not be refreshed by the open: fall back to "large"
					dsize_r  <= (scan_sz != 32'd0) ? scan_sz : 32'h0FFF_FFFF;
					state    <= ST_I_END;
				end
			ST_I_END:
				begin
					init_done <= 1;
					hold_r    <= 0;
					state     <= ST_IDLE;
				end

			// ---- write the suffix for the current mode at dpos ----
			ST_WR_START:
				begin
					// let the digit pipeline settle (5 stages) before writing
					if (!wr_wait_run) begin
						wr_wait_run <= 1;
						wr_wait     <= 5'd24;
					end
					else if (wr_wait != 0) wr_wait <= wr_wait - 1'd1;
					else begin
						wr_wait_run <= 0;
						wr_j  <= 0;
						state <= ST_WR_CH;
					end
				end
			ST_WR_CH:
				begin
					pb_addr <= wr_idx[8:2];
					pb_din  <= sfx_char(sfx_mode, sfx_nd, sfx_dg, wr_j);
					pb_we   <= 4'b0001 << (wr_idx[1:0] ^ {2{ord_r}});
					state   <= ST_WR_COMMIT;
				end
			ST_WR_COMMIT:
				begin
					pb_we <= 4'h0;
					if (wr_j == wr_jend) state <= ret_wr;
					else begin
						wr_j  <= wr_j + 1'd1;
						state <= ST_WR_CH;
					end
				end

			// ---- track mount ----
			ST_T_OPEN:
				begin
					tc_code <= 16'h0192;
					tc_p0   <= {16'b0, SLOT_PCM};
					tc_p1   <= PB_BASE;
					ret_cmd <= ST_T_SZ;
					state   <= ST_CMD_GO;
				end
			ST_T_SZ:
				begin
					if (res > 16'd1) begin
						diag_r    <= (res == 16'd3) ? 4'd5 : (res == 16'd4) ? 4'd8 : 4'd9;
						missing_r <= 1;
						wcnt      <= 0;
						state     <= ST_T_FIN;
					end
					else begin
						scan_id   <= SLOT_PCM;
						scan_next <= ST_T_SZ2;
						state     <= ST_SCN_S;
					end
				end
			ST_T_SZ2:
				begin
					asize_r <= (scan_sz != 32'd0) ? scan_sz : 32'h0FFF_FFFF;
					wcnt  <= 0;
					state <= ST_T_FIN;
				end
			ST_T_FIN:
				begin
					// keep "mounting" up long enough for clk_sys to see it
					wcnt <= wcnt + 1'd1;
					if (wcnt == 8'd255) begin
						mounting_r <= 0;
						state      <= ST_IDLE;
					end
				end

			// ---- transfer completions ----
			ST_A_FIN:
				begin
					diag_r   <= (res != 16'd0) ? 4'd4 : 4'd3;   // PCM data fetch result
					a_err_r  <= (res != 16'd0);
					a_done_r <= ~a_done_r;
					state    <= ST_IDLE;
				end
			ST_D_FIN:
				begin
					d_err_r  <= (res != 16'd0);
					d_done_r <= ~d_done_r;
					state    <= ST_IDLE;
				end

			default: state <= ST_IDLE;
		endcase
	end
end

endmodule
