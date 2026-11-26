// MD+ (MegaSD style CD audio) for the Analogue Pocket Genesis core
//
// Everything here runs on clk_74a (same clock as the APF bridge).
//   * Finds "<rom name>.cue" next to the ROM, parses FILE / TRACK / REM LOOP / REM NOLOOP
//   * Opens each wav with target command 0x0192, finds its "data" chunk
//   * Caches the first 256 KB of up to 64 tracks in PSRAM 0 (instant start)
//   * Streams the rest through a 4 MB ring buffer in PSRAM 1
//   * Plays 44.1 kHz stereo 16-bit, resampled to 48 kHz, with fades and volume
//
// No block RAM is used: data read from the SD card (0x0180) is written by the bridge
// straight into PSRAM through a small FIFO. Cue text, wav headers and the track table
// also live in PSRAM 1.
//
// Bridge map (region 0x4xxxxxxx):
//   0x40000000-0x400001FF  parameter RAM (paths for 0x0190 / 0x0192)
//   0x41000000-0x410FFFFF  data window -> PSRAM (target set by the controller)
//
// PSRAM 1 map (bytes): 0x000000 ring (4 MB), 0x800000 wav header scratch,
//                      0x900000 cue text (64 KB max), 0xA00000 track table

module mdp_core (
    input  wire        clk,
    input  wire        reset_n,        // host core reset (clk_74a)
    input  wire        rom_loading,    // ROM data slot being loaded (clk_74a)
    input  wire        enable,         // MD+ menu switch (sampled at boot)
    input  wire  [1:0] user_vol,       // 0=100% 1=75% 2=50% 3=25%
    input  wire        in_menu,        // Pocket menu open: keep SD traffic to a minimum

    // APF bridge
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] bridge_rd_data,

    // target commands (to core_bridge_cmd)
    output reg         tc_req = 0,
    output reg  [15:0] tc_cmd = 0,
    output reg  [31:0] tc_p0 = 0,
    output reg  [31:0] tc_p1 = 0,
    output reg  [31:0] tc_p2 = 0,
    output reg  [31:0] tc_p3 = 0,
    input  wire        tc_done,
    input  wire [15:0] tc_result,

    // from the cartridge bus (clk_sys domain)
    input  wire        trig,           // toggles when the game first opens the MD+ window
    input  wire        cmd_tgl,
    input  wire [15:0] cmd_word,
    input  wire        sys_reset,
    output wire        playing,
    output wire        hold,           // MD+ armed or booting (the bus stalls the first command)
    output wire        active,         // MD+ ready (registers visible)

    // save states (Pocket Memories): APF handshake + bridge window 0x50000000
    input  wire        ss_start,
    output reg         ss_start_ack = 0,
    output reg         ss_start_busy = 0,
    output reg         ss_start_ok = 0,
    output reg         ss_start_err = 0,
    input  wire        ss_load,
    output reg         ss_load_ack = 0,
    output reg         ss_load_busy = 0,
    output reg         ss_load_ok = 0,
    output reg         ss_load_err = 0,
    // to / from the system (clk_sys): toggles + stream word port
    output reg         ss_save_tgl = 0,
    output reg         ss_load_tgl = 0,
    output reg         ss_cancel_tgl = 0,
    input  wire        ss_done_tgl,
    input  wire        ss_sreq_tgl,
    input  wire        ss_swe,
    input  wire [16:0] ss_saddr,
    input  wire [15:0] ss_swd,
    output reg         ss_sack_tgl = 0,
    output reg  [15:0] ss_srd = 0,
    // MD+ track / position at the moment a save starts, and the position to resume from
    output reg  [6:0]  ss_snap_trk = 0,
    output reg  [31:0] ss_snap_pos = 0,
    output reg         ss_snap_loop = 0,
    output reg         ss_snap_on = 0,
    input  wire [31:0] ss_seek_pos,
    input  wire        ss_act_in,          // system: save state handler running (clk_sys)
    input  wire        ss_pend_in,         // system: request waiting for vblank
    input  wire        ss_prog_tgl,        // system: handler progress mark
    input  wire        ss_dbg_iack,        // system: interrupt acknowledge seen while pending
    input  wire        ss_dbg_vec,         // system: read of $78 seen while pending

    // audio out (48 kHz, signed)
    output reg  [15:0] out_l = 0,
    output reg  [15:0] out_r = 0,
    output reg         out_tgl = 0,

    // PSRAM 0 (head cache)
    output wire [21:16] cram0_a,
    inout  wire [15:0]  cram0_dq,
    input  wire         cram0_wait,
    output wire         cram0_clk,
    output wire         cram0_adv_n,
    output wire         cram0_cre,
    output wire         cram0_ce0_n,
    output wire         cram0_ce1_n,
    output wire         cram0_oe_n,
    output wire         cram0_we_n,
    output wire         cram0_ub_n,
    output wire         cram0_lb_n,

    // PSRAM 1 (ring buffer, tables)
    output wire [21:16] cram1_a,
    inout  wire [15:0]  cram1_dq,
    input  wire         cram1_wait,
    output wire         cram1_clk,
    output wire         cram1_adv_n,
    output wire         cram1_cre,
    output wire         cram1_ce0_n,
    output wire         cram1_ce1_n,
    output wire         cram1_oe_n,
    output wire         cram1_we_n,
    output wire         cram1_ub_n,
    output wire         cram1_lb_n
);

localparam [31:0] BR_PARAM = 32'h40000000;
localparam [31:0] BR_DATA  = 32'h41000000;

localparam [15:0] SLOT_CUE = 16'd20;
localparam [15:0] SLOT_TRK = 16'd21;   // playback stream
localparam [15:0] SLOT_BG  = 16'd22;   // background cache loader

localparam [31:0] CACHE_BYTES = 32'd262144;   // per track (about 1.49 s)
localparam [31:0] CHUNK       = 32'd8192;     // one bridge read
localparam [31:0] RING_BYTES  = 32'd4194304;  // 4 MB ring

localparam [23:0] HS_BASE = 24'h800000;       // wav header scratch
localparam [23:0] CB_BASE = 24'h900000;       // cue text
localparam [23:0] TB_BASE = 24'hA00000;       // track table

wire win_param = bridge_addr[31:9]  == BR_PARAM[31:9];
wire win_data  = bridge_addr[31:20] == BR_DATA[31:20];

///////////////////////////////////////////////////////////////////////////////
// Parameter RAM: 4 single port byte lanes. The bridge owns it while a target
// command is running, the controller otherwise.
///////////////////////////////////////////////////////////////////////////////

reg        bridge_owns = 0;
reg  [8:0] pb_addr = 0;
reg        pb_we = 0;
reg  [7:0] pb_wd = 0;
reg  [1:0] pb_lane_r = 0;
wire [31:0] pq;

genvar gi;
generate
for (gi = 0; gi < 4; gi = gi + 1) begin : g_param
    (* ramstyle = "MLAB, no_rw_check" *) reg [7:0] lane [0:127];
    reg [7:0] q;
    wire [6:0] a  = bridge_owns ? bridge_addr[8:2] : pb_addr[8:2];
    wire       we = bridge_owns ? (bridge_wr & win_param) : (pb_we & (pb_addr[1:0] == gi));
    wire [7:0] d  = bridge_owns ? bridge_wr_data[31-8*gi -: 8] : pb_wd;
    always @(posedge clk) begin
        if (we) lane[a] <= d;
        q <= lane[a];
    end
    assign pq[31-8*gi -: 8] = q;
end
endgenerate

// Bridge reads: latch the word for the address given with bridge_rd and hold it
// until the next read (the host samples the data some cycles later, after the
// address may already have moved on).
reg        br_rd_pend = 0;
reg [31:0] br_rd_hold = 0;
always @(posedge clk) begin
    br_rd_pend <= bridge_rd & win_param;
    if (br_rd_pend) br_rd_hold <= pq;
end
wire [31:0] ss_br_data;
assign bridge_rd_data = (bridge_addr[31:28] == 4'h5) ? ss_br_data : br_rd_hold;
always @(posedge clk) pb_lane_r <= pb_addr[1:0];
wire [7:0] pb_q = pq[31 - 8*pb_lane_r -: 8];

///////////////////////////////////////////////////////////////////////////////
// PSRAM controllers. A = player, B = bridge writer, C = controller
///////////////////////////////////////////////////////////////////////////////

reg         p0a_req = 0;  reg [22:0] p0a_addr = 0;  wire p0a_ack;  wire [15:0] p0a_q;
reg         p1a_req = 0;  reg [22:0] p1a_addr = 0;  wire p1a_ack;  wire [15:0] p1a_q;
reg         p0b_req = 0;  reg [22:0] p0b_addr = 0;  wire p0b_ack;  reg [15:0] p0b_wd = 0;
reg         p1b_req = 0;  reg [22:0] p1b_addr = 0;  wire p1b_ack;  reg [15:0] p1b_wd = 0;
reg         p1c_req = 0;  reg [22:0] p1c_addr = 0;  wire p1c_ack;  reg [15:0] p1c_wd = 0;  reg p1c_we = 0;
wire [15:0] p1c_q;
wire [15:0] unused_q0b, unused_q1b, unused_q0c;
wire        unused_ack0c;

// PSRAM 0: A = save state engine, B = player (head cache), C = bridge writer.
// The last 256 KB slot (63) holds the save state; the head cache uses slots 0-62.
reg         ssp_req = 0;  reg ssp_we = 0;  reg [22:0] ssp_addr = 0;  reg [15:0] ssp_wd = 0;
wire        ssp_ack;      wire [15:0] ssp_q;

mdp_psram psram0 (
    .clk(clk), .reset(1'b0),
    .a_req(ssp_req), .a_we(ssp_we), .a_addr(ssp_addr), .a_wdata(ssp_wd), .a_ack(ssp_ack), .a_rdata(ssp_q),
    .b_req(p0a_req), .b_we(1'b0), .b_addr(p0a_addr), .b_wdata(16'd0), .b_ack(p0a_ack), .b_rdata(p0a_q),
    .c_req(p0b_req), .c_we(1'b1), .c_addr(p0b_addr), .c_wdata(p0b_wd), .c_ack(p0b_ack), .c_rdata(unused_q0b),
    .cram_a(cram0_a), .cram_dq(cram0_dq), .cram_wait(cram0_wait), .cram_clk(cram0_clk),
    .cram_adv_n(cram0_adv_n), .cram_cre(cram0_cre), .cram_ce0_n(cram0_ce0_n), .cram_ce1_n(cram0_ce1_n),
    .cram_oe_n(cram0_oe_n), .cram_we_n(cram0_we_n), .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n)
);

mdp_psram psram1 (
    .clk(clk), .reset(1'b0),
    .a_req(p1a_req), .a_we(1'b0),   .a_addr(p1a_addr), .a_wdata(16'd0),  .a_ack(p1a_ack), .a_rdata(p1a_q),
    .b_req(p1b_req), .b_we(1'b1),   .b_addr(p1b_addr), .b_wdata(p1b_wd), .b_ack(p1b_ack), .b_rdata(unused_q1b),
    .c_req(p1c_req), .c_we(p1c_we), .c_addr(p1c_addr), .c_wdata(p1c_wd), .c_ack(p1c_ack), .c_rdata(p1c_q),
    .cram_a(cram1_a), .cram_dq(cram1_dq), .cram_wait(cram1_wait), .cram_clk(cram1_clk),
    .cram_adv_n(cram1_adv_n), .cram_cre(cram1_cre), .cram_ce0_n(cram1_ce0_n), .cram_ce1_n(cram1_ce1_n),
    .cram_oe_n(cram1_oe_n), .cram_we_n(cram1_we_n), .cram_ub_n(cram1_ub_n), .cram_lb_n(cram1_lb_n)
);

///////////////////////////////////////////////////////////////////////////////
// Bridge data window -> PSRAM writer (8 entry FIFO)
///////////////////////////////////////////////////////////////////////////////

reg         w_chip = 0;           // 0 = PSRAM 0, 1 = PSRAM 1
reg  [23:0] w_base = 0;           // byte address of offset 0
reg         w_ring = 0;           // wrap inside the 4 MB ring

(* ramstyle = "MLAB, no_rw_check" *) reg [49:0] wq [0:7];
reg  [2:0]  wq_wp = 0, wq_rp = 0;
reg  [3:0]  wq_cnt = 0;
reg  [19:0] data_hi = 0;          // highest byte written + 4 (cue length)
reg         data_hi_clr = 0;
reg         wq_overflow = 0;

reg  [1:0]  ws = 0;
reg  [31:0] w_word = 0;
reg  [22:0] w_hw = 0;
wire        w_idle = (ws == 0) && (wq_cnt == 0);

always @(posedge clk) begin : writer
    reg push, pop;
    reg [23:0] ba;
    push = bridge_wr & win_data;
    pop  = (ws == 0) && (wq_cnt != 0);

    if (push) begin
        if (wq_cnt != 4'd8) begin
            wq[wq_wp] <= {bridge_addr[19:2], bridge_wr_data};
            wq_wp <= wq_wp + 1'd1;
        end else wq_overflow <= 1;
    end

    if (data_hi_clr) data_hi <= 0;
    else if (push && ({bridge_addr[19:2], 2'b00} + 20'd4) > data_hi) data_hi <= {bridge_addr[19:2], 2'b00} + 20'd4;

    case (ws)
    0: if (pop) begin
        ba = w_base + {4'd0, wq[wq_rp][49:32], 2'b00};
        if (w_ring) ba = {2'b00, ba[21:0]};
        w_hw   <= ba[23:1];
        w_word <= wq[wq_rp][31:0];
        wq_rp  <= wq_rp + 1'd1;
        ws <= 1;
    end
    1: begin
        // high half = first two bytes
        if (w_chip) begin p1b_addr <= w_hw; p1b_wd <= w_word[31:16]; p1b_req <= 1; end
        else        begin p0b_addr <= w_hw; p0b_wd <= w_word[31:16]; p0b_req <= 1; end
        if (w_chip ? p1b_ack : p0b_ack) begin
            p0b_req <= 0; p1b_req <= 0;
            ws <= 2;
        end
    end
    2: begin
        if (w_chip) begin p1b_addr <= w_hw + 1'd1; p1b_wd <= w_word[15:0]; p1b_req <= 1; end
        else        begin p0b_addr <= w_hw + 1'd1; p0b_wd <= w_word[15:0]; p0b_req <= 1; end
        if (w_chip ? p1b_ack : p0b_ack) begin
            p0b_req <= 0; p1b_req <= 0;
            ws <= 0;
        end
    end
    default: ws <= 0;
    endcase

    wq_cnt <= wq_cnt + (push && wq_cnt != 4'd8) - pop;
end

///////////////////////////////////////////////////////////////////////////////
// Commands from the cartridge bus (clk_sys -> clk_74a), 8 entry FIFO
///////////////////////////////////////////////////////////////////////////////

reg [2:0]  ctgl_s = 0;
(* ramstyle = "MLAB, no_rw_check" *) reg [15:0] cmdq [0:7];
reg [2:0]  cq_wp = 0, cq_rp = 0;
reg [3:0]  cq_cnt = 0;
reg        cq_pop = 0;
reg        cq_clr = 0;
reg        mdp_on = 0;       // controller ready, accept commands

always @(posedge clk) begin : cmd_fifo
    reg push;
    ctgl_s <= {ctgl_s[1:0], cmd_tgl};
    // commands sent while MD+ is still starting are queued and run when it is ready
    push = (ctgl_s[2] != ctgl_s[1]) && (mdp_on | hold) && (cq_cnt != 4'd8);
    if (cq_clr) begin
        cq_wp <= 0; cq_rp <= 0; cq_cnt <= 0;
    end else begin
        if (push) begin
            cmdq[cq_wp] <= cmd_word;
            cq_wp <= cq_wp + 1'd1;
        end
        if (cq_pop) cq_rp <= cq_rp + 1'd1;
        cq_cnt <= cq_cnt + push - cq_pop;
    end
end
wire [15:0] cq_head = cmdq[cq_rp];

reg [2:0] trig_s = 0;
always @(posedge clk) trig_s <= {trig_s[1:0], trig};

reg [2:0] sysrst_s = 0;
always @(posedge clk) sysrst_s <= {sysrst_s[1:0], sys_reset};
wire sysrst_rise = sysrst_s[1] & ~sysrst_s[2];

///////////////////////////////////////////////////////////////////////////////
// Player control interface (controller -> player)
///////////////////////////////////////////////////////////////////////////////

reg         pl_start = 0;
reg         pl_pause = 0;
reg         pl_resume = 0;
reg         pl_stop = 0;
reg  [7:0]  p_rate = 0;
reg  [31:0] p_len = 0;             // audio bytes
reg  [31:0] p_clen = 0;            // cached bytes (0 = not cached)
reg  [31:0] p_lstart = 0;          // loop start bytes
reg  [31:0] p_spos = 0;            // start position (save state resume)
reg         p_sring = 0;           // start position is past the head cache
reg  [6:0]  cur_trk = 0;           // track playing (for save states)
reg         ss_cur_loop = 0;
reg         c_seek = 0;            // play command carries a resume position
reg         p_loop = 0;
reg  [5:0]  p_slot = 0;
reg  [7:0]  md_vol = 8'hFF;

reg  [31:0] wr_count = 0;          // ring bytes written (controller)

// debug beeps (test builds): dbg_n beeps, 0 = one long beep; blips on play commands
reg         dbg_req = 0;
reg  [3:0]  dbg_n = 0;
reg  [3:0]  dbg_n2 = 0;        // second group (high pitch): host result code
reg         blip_req = 0;
reg         blip_hi = 0;
reg         dg_on = 0, dg_sq = 0;      // save state diagnostic tone (t7.5d)
reg  [6:0]  trk_ok = 0;
reg  [31:0] rd_count = 0;          // ring bytes consumed (player)
reg         fill_done = 1;
wire        pl_pending;

///////////////////////////////////////////////////////////////////////////////
// Controller
///////////////////////////////////////////////////////////////////////////////

localparam [6:0]
    S_WAIT      = 0,
    S_DISABLED  = 1,
    S_TC        = 2,
    S_TCW       = 3,
    S_RB        = 4,
    S_RB2       = 5,
    S_WW0       = 6,
    S_WW1       = 7,
    S_RW0       = 8,
    S_RW1       = 9,
    S_B_START   = 10,
    S_B_GN_RES  = 11,
    S_B_SCAN    = 12,
    S_B_SCAN1   = 13,
    S_B_SCAN2   = 14,
    S_B_EXT     = 15,
    S_B_WR      = 16,
    S_B_OC      = 17,
    S_B_OC_RES  = 18,
    S_B_RC_RES  = 19,
    S_B_CLR     = 20,
    S_P_RD      = 21,
    S_P_CH      = 22,
    S_P_COMMIT  = 23,
    S_P_COMMIT2 = 24,
    S_P_COMMIT3 = 25,
    S_L_NEXT    = 26,
    S_L_CHK     = 27,
    S_L_OPENED  = 28,
    S_L_HDR     = 29,
    S_H_BYTE    = 30,
    S_H_BYTE2   = 31,
    S_H_EVAL    = 32,
    S_L_CACHE   = 33,
    S_L_CRD     = 34,
    S_L_CRES    = 35,
    S_L_DONE    = 36,
    S_L_W1      = 37,
    S_L_W3      = 38,
    S_L_W3B     = 39,
    S_READY     = 40,
    S_C_CMD     = 41,
    S_C_T0      = 42,
    S_C_T1      = 43,
    S_C_T2      = 44,
    S_C_T3      = 45,
    S_C_START   = 46,
    S_C_OPENED  = 47,
    S_F_START   = 48,
    S_F_RES     = 49,
    S_O_START   = 50,
    S_O_CP      = 51,
    S_O_CP2     = 52,
    S_O_END     = 53,
    S_O_OPEN    = 54,
    S_O_RES     = 55,
    S_B_CLR2    = 56,
    S_ARMED     = 57,
    S_G_W0      = 58,
    S_G_W1      = 59,
    S_G_OPENED  = 60,
    S_G_FIN     = 61,
    S_G_FIN2    = 62,
    S_B_CLR1    = 63,
    S_H_START   = 64,
    S_C_RETRY   = 65,
    S_G_HDR     = 66;

reg [6:0]  st = S_WAIT;
reg [6:0]  ret_st = S_WAIT;        // return for S_TC
reg [6:0]  sub_ret = S_WAIT;       // return for byte / word access
reg [6:0]  o_ret = S_WAIT;         // return for path build / open
reg [15:0] res = 0;
reg [27:0] tc_timer = 0;
reg [3:0]  fail_code = 0;
reg [6:0]  st_r = 0;

reg        run_s = 0;
reg        run_r = 0;

// PSRAM 1 access helpers
reg [23:0] rb_addr = 0;
reg [7:0]  rb_byte = 0;
reg [22:0] rb_hw = 0;
reg [15:0] rb_data = 0;
reg        rb_v = 0;
reg [23:0] ww_addr = 0;
reg [31:0] ww_data = 0;
reg [31:0] rw_data = 0;

// boot
reg [8:0]  si = 0;
reg [8:0]  last_slash = 0;
reg [8:0]  last_dot = 0;
reg [8:0]  name_end = 0;
reg [8:0]  rom_dir_len = 0;
reg [8:0]  ext_pos = 0;
reg [3:0]  wr_idx = 0;

// parser
reg [16:0] cue_len = 0;
reg [16:0] pi = 0;
reg [3:0]  ps = 0;
reg [47:0] kw = 0;
reg [15:0] num = 0;
reg        num_has = 0;
reg        num_tgt = 0;           // 0 = TRACK, 1 = REM LOOP
reg [15:0] pend_off = 0;
reg [6:0]  pend_len = 0;
reg        pend_valid = 0;
reg        cur_valid = 0;
reg [6:0]  cur_track = 0;
reg [15:0] cur_off = 0;
reg [6:0]  cur_len = 0;
reg        cur_loop = 1;
reg [15:0] cur_loopsec = 0;
reg        commit_then_end = 0;

localparam PS_LS = 0, PS_KW = 1, PS_REM = 2, PS_KW2 = 3, PS_FQ = 4, PS_FN = 5, PS_NUM = 6, PS_EOL = 7;

// load / play
reg [6:0]  t = 0;
reg [6:0]  cache_next = 0;
reg [31:0] t_off = 0, t_len = 0, t_lstart = 0, t_w3 = 0;
// wav header parse (done the first time a track is played or cached)
reg [6:0]  h_t = 0;
reg [31:0] h_w3 = 0, h_off = 0, h_len = 0;
reg [15:0] h_slot = 0;
reg [6:0]  hdr_ret = 0;
reg [15:0] o_name_off = 0;
reg [6:0]  o_name_len = 0;
reg [6:0]  ok_k = 0;
reg        o_ok = 0;
reg [12:0] hpos = 0;
reg [63:0] hb = 0;
reg [3:0]  hk = 0;
reg [31:0] c_len = 0, c_off = 0, c_n = 0;
reg [7:0]  ccmd = 0, carg = 0;
reg        play_loop = 0;

// background cache loader
reg [6:0]  bg_t = 0;
reg        bg_open = 0;
reg        bg_done = 1;
reg [31:0] bg_off = 0, bg_clen = 0, g_off = 0, g_len = 0, g_w3 = 0;
reg [15:0] o_slot = 0;

// filler
reg        fill_active = 0;
reg [31:0] fill_pos = 0;

function [7:0] upcase(input [7:0] c);
    upcase = (c >= "a" && c <= "z") ? c - 8'd32 : c;
endfunction

function is_ws(input [7:0] c);
    is_ws = (c == " " || c == 8'h09 || c == 8'h0D || c == 8'h00);
endfunction

function [31:0] min32(input [31:0] a, input [31:0] b);
    min32 = (a < b) ? a : b;
endfunction

function [23:0] tb_addr(input [6:0] tr, input [1:0] w);
    tb_addr = TB_BASE + {13'd0, tr, w, 2'b00};
endfunction

wire [31:0] ring_used = wr_count - rd_count;

// SD traffic pacing: the Pocket OS serves every bridge command, so leave it room
// (gap after each command; background caching slower and paused in the menu)
reg  [21:0] tc_gap = 0;
reg  [1:0]  menu_s = 0;
always @(posedge clk) menu_s <= {menu_s[0], in_menu};
localparam [31:0] RING_TARGET = 32'd2097152;   // keep about 12 s buffered
localparam [31:0] RING_MENU   = 32'd524288;    // in the menu: refill only below 3 s
wire fill_ok = (tc_gap >= 22'd524288) &&                           // >= 7 ms since the last command
               (menu_s[1] ? (ring_used < RING_MENU) : (ring_used < RING_TARGET));
wire bg_ok   = (&tc_gap) && !menu_s[1];                             // >= 56 ms, not in the menu
wire        ring_room = (RING_BYTES - ring_used) >= CHUNK;

assign hold   = ~(st == S_DISABLED || mdp_on);
assign active = mdp_on;

always @(posedge clk) begin
    run_s <= reset_n & ~rom_loading;
    run_r <= run_s;

    pb_we <= 0;
    cq_pop <= 0;
    cq_clr <= 0;
    data_hi_clr <= 0;
    pl_start <= 0;
    pl_pause <= 0;
    pl_resume <= 0;
    pl_stop <= 0;
    if (~&tc_gap) tc_gap <= tc_gap + 1'd1;
    dbg_req <= 0;
    blip_req <= 0;
    bridge_owns <= (st == S_TC);
    st_r <= st;
    if (st == S_DISABLED && st_r != S_DISABLED && fail_code != 0) begin
        dbg_req <= 1;
        dbg_n <= fail_code;
        dbg_n2 <= (res > 16'd15) ? 4'd15 : res[3:0];
    end

    if (sysrst_rise && mdp_on) begin
        pl_stop <= 1;
        fill_active <= 0;
        fill_done <= 1;
    end

    if (~run_s) begin
        st <= S_WAIT;
        mdp_on <= 0;
        tc_req <= 0;
        p1c_req <= 0;
        fill_active <= 0;
        fill_done <= 1;
        cq_clr <= 1;
        if (mdp_on) pl_stop <= 1;
    end else begin
        case (st)

        S_WAIT: begin
            if (run_s & ~run_r) begin
                md_vol <= 8'hFF;
                    trk_ok <= 0;
                fail_code <= 0;
                if (enable) st <= S_B_START;    // t7.1: start right away, in the background
                else        st <= S_DISABLED;
            end
        end

        S_DISABLED: ;

        S_ARMED: begin
            if (trig_s[2] != trig_s[1]) st <= S_B_START;
        end

        //------------------------------------------------- target command call
        S_TC: begin
            tc_req <= 1;
            rb_v <= 0;
            tc_timer <= tc_timer + 1'd1;
            if (tc_done) begin
                tc_req <= 0;
                res <= tc_result;
                tc_timer <= 0;
                st <= S_TCW;
            end else if (&tc_timer) begin
                tc_req <= 0;            // host did not answer: give up on MD+
                mdp_on <= 0;
                fail_code <= 4'd4;
                st <= S_DISABLED;
            end
        end

        S_TCW: begin
            // let the bridge data reach PSRAM
            tc_timer <= tc_timer + 1'd1;
            tc_gap <= 0;
            if (w_idle && tc_timer[3]) st <= ret_st;
        end

        //------------------------------------------- PSRAM 1 byte / word access
        S_RB: begin
            if (rb_v && rb_hw == rb_addr[23:1]) begin
                rb_byte <= rb_addr[0] ? rb_data[7:0] : rb_data[15:8];
                st <= sub_ret;
            end else begin
                p1c_addr <= rb_addr[23:1];
                p1c_we <= 0;
                p1c_req <= 1;
                st <= S_RB2;
            end
        end

        S_RB2: begin
            if (p1c_ack) begin
                p1c_req <= 0;
                rb_hw <= p1c_addr;
                rb_data <= p1c_q;
                rb_v <= 1;
                rb_byte <= rb_addr[0] ? p1c_q[7:0] : p1c_q[15:8];
                st <= sub_ret;
            end
        end

        S_WW0: begin
            p1c_addr <= ww_addr[23:1]; p1c_wd <= ww_data[31:16]; p1c_we <= 1; p1c_req <= 1;
            if (p1c_ack) begin p1c_req <= 0; st <= S_WW1; end
        end

        S_WW1: begin
            p1c_addr <= ww_addr[23:1] + 1'd1; p1c_wd <= ww_data[15:0]; p1c_we <= 1; p1c_req <= 1;
            if (p1c_ack) begin p1c_req <= 0; rb_v <= 0; st <= sub_ret; end
        end

        S_RW0: begin
            p1c_addr <= ww_addr[23:1]; p1c_we <= 0; p1c_req <= 1;
            if (p1c_ack) begin p1c_req <= 0; rw_data[31:16] <= p1c_q; st <= S_RW1; end
        end

        S_RW1: begin
            p1c_addr <= ww_addr[23:1] + 1'd1; p1c_we <= 0; p1c_req <= 1;
            if (p1c_ack) begin p1c_req <= 0; rw_data[15:0] <= p1c_q; st <= sub_ret; end
        end

        //---------------------------------------------------------------- boot
        S_B_START: begin
            tc_cmd <= 16'h0190; tc_p0 <= 0; tc_p1 <= BR_PARAM;
            tc_timer <= 0; ret_st <= S_B_GN_RES; st <= S_TC;
        end

        S_B_GN_RES: begin
            if (res != 0) begin fail_code <= 4'd1; st <= S_DISABLED; end
            else begin
                si <= 0; last_slash <= 0; last_dot <= 0;
                st <= S_B_SCAN;
            end
        end

        S_B_SCAN: begin
            pb_addr <= si;
            st <= S_B_SCAN1;
        end

        S_B_SCAN1: st <= S_B_SCAN2;   // RAM latency

        S_B_SCAN2: begin
            if (pb_q == 8'h00 || si == 9'd255) begin
                name_end <= si;
                st <= S_B_EXT;
            end else begin
                if (pb_q == "/") begin last_slash <= si + 1'd1; last_dot <= 0; end
                if (pb_q == ".") last_dot <= si;
                si <= si + 1'd1;
                st <= S_B_SCAN;
            end
        end

        S_B_EXT: begin
            rom_dir_len <= last_slash;
            ext_pos <= (last_dot != 0) ? last_dot : name_end;
            wr_idx <= 0;
            st <= S_B_WR;
        end

        S_B_WR: begin
            // ".cue\0" at ext_pos, then zero the flags/size words at 0x100..0x107
            pb_we <= 1;
            case (wr_idx)
                0: begin pb_addr <= ext_pos;        pb_wd <= "."; end
                1: begin pb_addr <= ext_pos + 9'd1; pb_wd <= "c"; end
                2: begin pb_addr <= ext_pos + 9'd2; pb_wd <= "u"; end
                3: begin pb_addr <= ext_pos + 9'd3; pb_wd <= "e"; end
                4: begin pb_addr <= ext_pos + 9'd4; pb_wd <= 8'h00; end
                default: begin pb_addr <= 9'h100 + (wr_idx - 4'd5); pb_wd <= 8'h00; end
            endcase
            wr_idx <= wr_idx + 1'd1;
            if (wr_idx == 4'd12) begin
                if (ext_pos > 9'd250) begin fail_code <= 4'd1; st <= S_DISABLED; end
                else st <= S_B_OC;
            end
        end

        S_B_OC: begin
            tc_cmd <= 16'h0192; tc_p0 <= SLOT_CUE; tc_p1 <= BR_PARAM;
            tc_timer <= 0; ret_st <= S_B_OC_RES; st <= S_TC;
        end

        S_B_OC_RES: begin
            if (res > 1) begin fail_code <= 4'd2; st <= S_DISABLED; end   // no cue next to the ROM
            else begin
                data_hi_clr <= 1;
                w_chip <= 1; w_base <= CB_BASE; w_ring <= 0;
                tc_cmd <= 16'h0180; tc_p0 <= SLOT_CUE; tc_p1 <= 0; tc_p2 <= BR_DATA; tc_p3 <= 32'hFFFFFFFF;
                tc_timer <= 0; ret_st <= S_B_RC_RES; st <= S_TC;
            end
        end

        S_B_RC_RES: begin
            if (res != 0 || data_hi == 0) begin fail_code <= 4'd3; st <= S_DISABLED; end
            else begin
                cue_len <= (data_hi > 20'd65535) ? 17'd65535 : data_hi[16:0];
                t <= 0;
                st <= S_B_CLR;
            end
        end

        // clear the valid word of every table entry
        S_B_CLR: begin
            ww_addr <= tb_addr(t, 2'd3); ww_data <= 0;
            sub_ret <= S_B_CLR1; st <= S_WW0;
        end

        S_B_CLR1: begin
            ww_addr <= tb_addr(t, 2'd1); ww_data <= 0;     // length 0 = header not read yet
            sub_ret <= S_B_CLR2; st <= S_WW0;
        end

        S_B_CLR2: begin
            if (t == 7'd99) begin
                pi <= 0; ps <= PS_LS; kw <= 0;
                pend_valid <= 0; cur_valid <= 0;
                commit_then_end <= 0;
                st <= S_P_RD;
            end else begin
                t <= t + 1'd1;
                st <= S_B_CLR;
            end
        end

        //-------------------------------------------------------------- parser
        S_P_RD: begin
            if (pi >= cue_len) begin
                commit_then_end <= 1;
                st <= S_P_COMMIT;
            end else begin
                rb_addr <= CB_BASE + {7'd0, pi};
                sub_ret <= S_P_CH;
                st <= S_RB;
            end
        end

        S_P_CH: begin : parse_char
            reg [7:0] c;
            reg       nl;
            c  = rb_byte;
            nl = (c == 8'h0A);
            st <= S_P_RD;
            pi <= pi + 1'd1;

            case (ps)
            PS_LS: begin
                if (!is_ws(c) && !nl) begin
                    kw <= {40'd0, upcase(c)};
                    ps <= PS_KW;
                end
            end

            PS_KW, PS_KW2: begin
                if (is_ws(c) || nl) begin
                    if (ps == PS_KW && kw == {16'd0, "FILE"}) begin
                        ps <= nl ? PS_LS : PS_FQ;
                        if (cur_valid) st <= S_P_COMMIT;   // a new FILE closes the previous track
                    end
                    else if (ps == PS_KW && kw == {8'd0, "TRACK"}) begin
                        ps <= nl ? PS_LS : PS_NUM; num <= 0; num_has <= 0; num_tgt <= 0;
                    end
                    else if (ps == PS_KW && kw == {24'd0, "REM"}) begin
                        ps <= nl ? PS_LS : PS_REM;
                    end
                    else if (ps == PS_KW2 && kw == {16'd0, "LOOP"}) begin
                        if (nl) begin
                            cur_loop <= 1; cur_loopsec <= 0; ps <= PS_LS;
                        end else begin
                            ps <= PS_NUM; num <= 0; num_has <= 0; num_tgt <= 1;
                        end
                    end
                    else if (ps == PS_KW2 && kw == "NOLOOP") begin
                        cur_loop <= 0;
                        ps <= nl ? PS_LS : PS_EOL;
                    end
                    else ps <= nl ? PS_LS : PS_EOL;
                end else begin
                    kw <= {kw[39:0], upcase(c)};
                end
            end

            PS_REM: begin
                if (nl) ps <= PS_LS;
                else if (!is_ws(c)) begin
                    kw <= {40'd0, upcase(c)};
                    ps <= PS_KW2;
                end
            end

            PS_FQ: begin
                if (nl) ps <= PS_LS;
                else if (c == 8'h22) begin
                    pend_off <= pi[15:0] + 1'd1;
                    pend_len <= 0;
                    pend_valid <= 0;
                    ps <= PS_FN;
                end
            end

            PS_FN: begin
                if (nl) ps <= PS_LS;
                else if (c == 8'h22) begin
                    pend_valid <= (pend_len != 0) && (pend_len != 7'd127);
                    ps <= PS_EOL;
                end else begin
                    if (pend_len != 7'd127) pend_len <= pend_len + 1'd1;
                end
            end

            PS_NUM: begin
                if (c >= "0" && c <= "9") begin
                    num <= num * 16'd10 + (c - "0");
                    num_has <= 1;
                end else if (is_ws(c) && !num_has) begin
                    // leading blanks
                end else begin
                    if (num_tgt == 0) begin
                        if (num_has && num >= 1 && num <= 99 && pend_valid) begin
                            cur_valid   <= 1;
                            cur_track   <= num[6:0];
                            cur_off     <= pend_off;
                            cur_len     <= pend_len;
                            cur_loop    <= 1;
                            cur_loopsec <= 0;
                            pend_valid  <= 0;
                        end
                    end else begin
                        cur_loop    <= 1;
                        cur_loopsec <= num_has ? num : 16'd0;
                    end
                    ps <= nl ? PS_LS : PS_EOL;
                end
            end

            PS_EOL: begin
                if (nl) ps <= PS_LS;
            end

            default: ps <= PS_LS;
            endcase
        end

        S_P_COMMIT: begin
            if (cur_valid) begin
                ww_addr <= tb_addr(cur_track, 2'd2);
                ww_data <= cur_loopsec * 32'd2352;     // CD sectors -> bytes
                sub_ret <= S_P_COMMIT2;
                st <= S_WW0;
            end else begin
                t <= 7'd1;
                cache_next <= 0;
                st <= commit_then_end ? S_L_NEXT : S_P_RD;
            end
        end

        S_P_COMMIT2: begin
            ww_addr <= tb_addr(cur_track, 2'd3);
            ww_data <= {1'b1, cur_loop, 1'b0, 6'd0, cur_len, cur_off};
            sub_ret <= S_P_COMMIT3;
            st <= S_WW0;
        end

        S_P_COMMIT3: begin
            cur_valid <= 0;
            t <= 7'd1;
            cache_next <= 0;
            st <= commit_then_end ? S_L_NEXT : S_P_RD;
        end

        //------------------------------------------- open, measure, cache wavs
        S_L_NEXT: begin
            if (1'b1) begin   // headers are read when a track is first played / cached
                mdp_on <= 1;
                st <= S_READY;
                bg_t <= 7'd1; bg_open <= 0; bg_done <= 0; cache_next <= 0;
                dbg_req <= 1;
                dbg_n <= (trk_ok == 0) ? 4'd5 : 4'd0;
            end else begin
                ww_addr <= tb_addr(t, 2'd3);
                sub_ret <= S_L_CHK;
                st <= S_RW0;
            end
        end

        S_L_CHK: begin
            t_w3 <= rw_data;
            if (!rw_data[31]) begin
                t <= t + 1'd1;
                st <= S_L_NEXT;
            end else begin
                o_name_off <= rw_data[15:0];
                o_name_len <= rw_data[22:16];
                o_ret <= S_L_OPENED;
                o_slot <= SLOT_TRK;
                st <= S_O_START;
            end
        end

        // parse the wav header of track h_t (entry h_w3) through slot h_slot,
        // write w0/w1/w3 and return to hdr_ret
        S_H_START: begin
            o_name_off <= h_w3[15:0];
            o_name_len <= h_w3[22:16];
            o_ret <= S_L_OPENED;
            o_slot <= h_slot;
            st <= S_O_START;
        end

        S_L_OPENED: begin
            if (!o_ok) begin
                h_w3[31] <= 0;          // file missing: track disabled
                st <= S_L_W3;
            end else begin
                w_chip <= 1; w_base <= HS_BASE; w_ring <= 0;
                tc_cmd <= 16'h0180; tc_p0 <= h_slot; tc_p1 <= 0; tc_p2 <= BR_DATA; tc_p3 <= 32'd4096;
                tc_timer <= 0; ret_st <= S_L_HDR; st <= S_TC;
            end
        end

        S_L_HDR: begin
            if (res != 0) begin
                h_w3[31] <= 0;
                st <= S_L_W3;
            end else begin
                hpos <= 13'd12;
                hk <= 0;
                st <= S_H_BYTE;
            end
        end

        // read 8 bytes at hpos..hpos+7 into hb (chunk id + little endian size)
        S_H_BYTE: begin
            rb_addr <= HS_BASE + {11'd0, hpos};
            sub_ret <= S_H_BYTE2;
            st <= S_RB;
        end

        S_H_BYTE2: begin
            hb <= {hb[55:0], rb_byte};
            hpos <= hpos + 1'd1;
            if (hk == 4'd7) begin
                hk <= 0;
                st <= S_H_EVAL;
            end else begin
                hk <= hk + 1'd1;
                st <= S_H_BYTE;
            end
        end

        S_H_EVAL: begin : hdr_eval
            reg [31:0] csz;
            reg [31:0] npos;
            csz  = {hb[7:0], hb[15:8], hb[23:16], hb[31:24]};
            npos = {19'd0, hpos} + csz + csz[0];   // hpos already points past the chunk header
            if (hb[63:32] == "data") begin
                h_off <= {19'd0, hpos};
                h_len <= {csz[31:2], 2'b00};
                if (csz[31:2] == 0) h_w3[31] <= 0;
                st <= S_L_DONE;
            end else if (npos + 32'd8 > 32'd4096) begin
                h_w3[31] <= 0;
                st <= S_L_W3;
            end else begin
                hpos <= npos[12:0];
                st <= S_H_BYTE;
            end
        end

        //------------------------- background cache loader (one step per call)
        S_L_CACHE: begin
            if (bg_open) begin
                if (bg_off >= bg_clen) st <= S_G_FIN;
                else begin
                    c_n <= min32(bg_clen - bg_off, CHUNK);
                    w_chip <= 0; w_base <= {cache_next[5:0], 18'd0} + bg_off[23:0]; w_ring <= 0;
                    tc_cmd <= 16'h0180; tc_p0 <= SLOT_BG; tc_p1 <= g_off + bg_off; tc_p2 <= BR_DATA;
                    tc_p3 <= min32(bg_clen - bg_off, CHUNK);
                    tc_timer <= 0; ret_st <= S_L_CRES; st <= S_TC;
                end
            end else if (bg_t == 7'd100 || cache_next == 7'd63) begin
                bg_done <= 1;
                st <= S_READY;
            end else begin
                ww_addr <= tb_addr(bg_t, 2'd3);
                sub_ret <= S_L_CRD;
                st <= S_RW0;
            end
        end

        S_L_CRD: begin
            g_w3 <= rw_data;
            if (!rw_data[31] || rw_data[29]) begin
                bg_t <= bg_t + 1'd1;           // not valid or already cached
                st <= S_READY;
            end else begin
                ww_addr <= tb_addr(bg_t, 2'd0);
                sub_ret <= S_G_W0;
                st <= S_RW0;
            end
        end

        S_G_W0: begin
            g_off <= rw_data;
            ww_addr <= tb_addr(bg_t, 2'd1);
            sub_ret <= S_G_W1;
            st <= S_RW0;
        end

        S_G_W1: begin
            if (rw_data == 0) begin
                // header not read yet: read it, then this track is tried again
                h_t <= bg_t; h_w3 <= g_w3; h_slot <= SLOT_BG;
                hdr_ret <= S_READY;
                st <= S_H_START;
            end else st <= S_G_HDR;
        end

        S_G_HDR: begin
            g_len <= rw_data;
            bg_clen <= min32(rw_data, CACHE_BYTES) & 32'hFFFFFFFC;
            bg_off <= 0;
            o_name_off <= g_w3[15:0];
            o_name_len <= g_w3[22:16];
            o_slot <= SLOT_BG;
            o_ret <= S_G_OPENED;
            st <= S_O_START;
        end

        S_G_OPENED: begin
            if (o_ok) bg_open <= 1;
            else bg_t <= bg_t + 1'd1;
            st <= S_READY;
        end

        S_L_CRES: begin
            if (res != 0) begin
                bg_open <= 0;                   // could not cache: stream only
                bg_t <= bg_t + 1'd1;
            end else bg_off <= bg_off + c_n;
            st <= S_READY;
        end

        S_G_FIN: begin
            // mark the track as cached in the table
            ww_addr <= tb_addr(bg_t, 2'd3);
            ww_data <= {g_w3[31:30], 1'b1, cache_next[5:0], g_w3[22:0]};
            sub_ret <= S_G_FIN2;
            st <= S_WW0;
        end

        S_G_FIN2: begin
            cache_next <= cache_next + 1'd1;
            bg_open <= 0;
            bg_t <= bg_t + 1'd1;
            st <= S_READY;
        end

        S_L_DONE: begin
            trk_ok <= trk_ok + 1'd1;
            ww_addr <= tb_addr(h_t, 2'd0); ww_data <= h_off;
            sub_ret <= S_L_W1; st <= S_WW0;
        end

        S_L_W1: begin
            ww_addr <= tb_addr(h_t, 2'd1); ww_data <= h_len;
            sub_ret <= S_L_W3; st <= S_WW0;
        end

        S_L_W3: begin
            ww_addr <= tb_addr(h_t, 2'd3); ww_data <= h_w3;
            sub_ret <= S_L_W3B; st <= S_WW0;
        end

        S_L_W3B: begin
            st <= hdr_ret;
        end

        //---------------------------------------------------------- main loop
        S_READY: begin
            if (cq_cnt != 0) begin
                {ccmd, carg} <= cq_head;
                cq_pop <= 1;
                st <= S_C_CMD;
            end else if (fill_active && !fill_done && !pl_pending && ring_room && fill_ok) begin
                st <= S_F_START;
            end else if (!bg_done && bg_ok && !(fill_active && !fill_done && ring_used < RING_MENU)) begin
                st <= S_L_CACHE;
            end
        end

        S_C_CMD: begin
            case (ccmd)
            8'h11, 8'h12, 8'h1A, 8'h1B: begin
                // 1A / 1B: internal (save state load) = play once / loop from ss_seek_pos
                play_loop <= (ccmd == 8'h12 || ccmd == 8'h1B);
                c_seek <= ccmd[3];
                if (carg >= 8'd1 && carg <= 8'd99) begin
                    t <= carg[6:0];
                    ww_addr <= tb_addr(carg[6:0], 2'd3);
                    sub_ret <= S_C_T0;
                    st <= S_RW0;
                end else st <= S_READY;
            end
            8'h13: begin
                p_rate <= carg;
                pl_pause <= 1;
                st <= S_READY;
            end
            8'h14: begin
                pl_resume <= 1;
                st <= S_READY;
            end
            8'h15: begin
                md_vol <= carg;
                st <= S_READY;
            end
            default: st <= S_READY;
            endcase
        end

        // read the table entry of the requested track (w3 first)
        S_C_T0: begin
            t_w3 <= rw_data;
            blip_req <= 1;
            blip_hi <= rw_data[31];
            if (!rw_data[31]) st <= S_READY;       // unknown track: ignore
            else begin
                ww_addr <= tb_addr(t, 2'd0);
                sub_ret <= S_C_T1;
                st <= S_RW0;
            end
        end
        S_C_T1: begin
            t_off <= rw_data;
            ww_addr <= tb_addr(t, 2'd1);
            sub_ret <= S_C_T2;
            st <= S_RW0;
        end
        S_C_T2: begin
            t_len <= rw_data;
            if (rw_data == 0) begin
                h_t <= t; h_w3 <= t_w3; h_slot <= SLOT_TRK;
                hdr_ret <= S_C_RETRY;
                st <= S_H_START;
            end else begin
                ww_addr <= tb_addr(t, 2'd2);
                sub_ret <= S_C_T3;
                st <= S_RW0;
            end
        end

        S_C_RETRY: begin
            ww_addr <= tb_addr(t, 2'd3);
            sub_ret <= S_C_T0;
            st <= S_RW0;
        end
        S_C_T3: begin
            t_lstart <= rw_data;
            st <= S_C_START;
        end

        S_C_START: begin : c_start
            reg [31:0] clen;
            reg [31:0] ls;
            reg [31:0] sp;
            clen = t_w3[29] ? (min32(t_len, CACHE_BYTES) & 32'hFFFFFFFC) : 32'd0;
            ls   = (t_lstart < t_len) ? t_lstart : 32'd0;
            sp   = (c_seek && ss_seek_pos < t_len) ? {ss_seek_pos[31:2], 2'b00} : 32'd0;
            p_spos  <= sp;
            p_sring <= (sp >= clen) && (sp != 0);
            cur_trk <= t;
            ss_cur_loop <= play_loop;
            p_len    <= t_len;
            p_clen   <= clen;
            p_lstart <= ls;
            t_lstart <= ls;
            p_loop   <= play_loop & t_w3[30];
            p_slot   <= t_w3[28:23];
            pl_start <= 1;
            wr_count <= 0;
            fill_active <= 0;
            if (t_len > clen) begin
                fill_done  <= 0;
                fill_pos   <= (sp > clen) ? sp : clen;
                o_name_off <= t_w3[15:0];
                o_name_len <= t_w3[22:16];
                o_ret <= S_C_OPENED;
                o_slot <= SLOT_TRK;
                st <= S_O_START;
            end else begin
                fill_done <= 1;
                st <= S_READY;
            end
        end

        S_C_OPENED: begin
            if (o_ok) fill_active <= 1;
            else      fill_done <= 1;
            st <= S_READY;
        end

        //------------------------------------------------------ stream filler
        S_F_START: begin
            c_n <= min32(t_len - fill_pos, CHUNK);
            w_chip <= 1; w_base <= {2'b00, wr_count[21:0]}; w_ring <= 1;
            tc_cmd <= 16'h0180; tc_p0 <= SLOT_TRK; tc_p1 <= t_off + fill_pos; tc_p2 <= BR_DATA;
            tc_p3 <= min32(t_len - fill_pos, CHUNK);
            tc_timer <= 0; ret_st <= S_F_RES; st <= S_TC;
        end

        S_F_RES: begin
            if (res != 0) fill_done <= 1;
            else begin
                wr_count <= wr_count + c_n;
                if (fill_pos + c_n >= t_len) begin
                    if (p_loop) fill_pos <= t_lstart;
                    else begin
                        fill_pos  <= t_len;
                        fill_done <= 1;
                    end
                end else begin
                    fill_pos <= fill_pos + c_n;
                end
            end
            st <= S_READY;
        end

        //------------------------------- build "<rom dir>/<file name>" and open
        S_O_START: begin
            ok_k <= 0;
            if ({1'b0, rom_dir_len} + {3'b0, o_name_len} > 10'd254 || o_name_len == 0) begin
                o_ok <= 0;
                st <= o_ret;
            end else st <= S_O_CP;
        end

        S_O_CP: begin
            rb_addr <= CB_BASE + {8'd0, o_name_off} + {17'd0, ok_k};
            sub_ret <= S_O_CP2;
            st <= S_RB;
        end

        S_O_CP2: begin
            pb_we   <= 1;
            pb_addr <= rom_dir_len + ok_k;
            pb_wd   <= rb_byte;
            ok_k    <= ok_k + 1'd1;
            if (ok_k + 1'd1 == o_name_len) st <= S_O_END;
            else st <= S_O_CP;
        end

        S_O_END: begin
            pb_we   <= 1;                 // terminator after the name
            pb_addr <= rom_dir_len + ok_k;
            pb_wd   <= 8'h00;
            st <= S_O_OPEN;
        end

        S_O_OPEN: begin
            tc_cmd <= 16'h0192; tc_p0 <= o_slot; tc_p1 <= BR_PARAM;
            tc_timer <= 0; ret_st <= S_O_RES; st <= S_TC;
        end

        S_O_RES: begin
            o_ok <= (res <= 16'd1);
            st <= o_ret;
        end

        default: st <= S_WAIT;
        endcase
    end
end

///////////////////////////////////////////////////////////////////////////////
// Player
///////////////////////////////////////////////////////////////////////////////

reg         pl_on = 0;
reg         pl_paused = 0;
reg         pl_phase = 0;        // 0 = head cache, 1 = ring
reg         pl_ended = 0;
reg  [31:0] pos = 0;
reg  [31:0] abs_pos = 0;         // byte position in the track (save states)
reg  [31:0] r_len = 0, r_clen = 0, r_lstart = 0;
reg         r_loop = 0;
reg  [5:0]  r_slot = 0;

reg         pend_start = 0;
reg         fading_out = 0;
reg         fading_in = 0;
reg  [7:0]  fade_rate = 0;
reg  [7:0]  fade_cnt = 0;
reg         after_fade_pause = 0;
reg  [8:0]  gain = 0;

assign pl_pending = pend_start;

// debug beep generator (48 kHz ticks)
reg  [3:0]  bp_left = 0;       // beeps remaining
reg         bp_long = 0;
reg         bp_on = 0;         // tone phase of the current beep
reg  [15:0] bp_t = 0;
reg  [5:0]  bp_ph = 0;
reg  [5:0]  bp_half = 24;      // half period in ticks (24 = 1 kHz)
reg         bp_sq = 0;
reg         bp_active = 0;
reg  [3:0]  bp_second = 0;
assign playing = pl_on & ~pl_paused;

// frame FIFO (16 x stereo frame)
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] ff [0:15];
reg  [3:0]  ff_wp = 0, ff_rp = 0;
reg  [4:0]  ff_cnt = 0;
reg         ff_push = 0, ff_pop = 0, ff_clr = 0;
reg  [31:0] ff_in = 0;

always @(posedge clk) begin
    if (ff_clr) begin
        ff_wp <= 0; ff_rp <= 0; ff_cnt <= 0;
    end else begin
        if (ff_push) begin ff[ff_wp] <= ff_in; ff_wp <= ff_wp + 1'd1; end
        if (ff_pop) ff_rp <= ff_rp + 1'd1;
        ff_cnt <= ff_cnt + ff_push - ff_pop;
    end
end
wire [31:0] ff_head = ff[ff_rp];

// 48 kHz tick from 74.25 MHz: 74250000 / 48000 = 12375 / 8
reg  [13:0] tick_acc = 0;
reg         tick = 0;
always @(posedge clk) begin
    tick <= 0;
    if (tick_acc + 14'd8 >= 14'd12375) begin
        tick_acc <= tick_acc + 14'd8 - 14'd12375;
        tick <= 1;
    end else tick_acc <= tick_acc + 14'd8;
end

reg  [1:0]  fs = 0;
reg  [15:0] fhw0 = 0;
localparam F_IDLE = 0, F_R0 = 1, F_R1 = 2, F_PUSH = 3;

wire [31:0] ring_avail = wr_count - rd_count;
wire        want_fetch = pl_on & ~pl_paused & ~pl_ended & ~pend_start & (ff_cnt < 5'd12);

reg  [7:0]  ph = 0;              // 0..159
reg  [15:0] s0l = 0, s0r = 0, s1l = 0, s1r = 0;

reg  [2:0]  os = 0;
reg  signed [16:0] dl = 0, dr = 0;
reg  signed [34:0] ml = 0, mr = 0;
reg         [16:0] wq_i = 0;
reg  signed [15:0] il = 0, ir = 0;
reg  signed [25:0] gl = 0, gr = 0;

always @(posedge clk) begin
    ff_push <= 0;
    ff_pop  <= 0;
    ff_clr  <= 0;

    // -------------------------------------------------- control from ctrl
    if (pl_stop) begin
        pl_on <= 0; pl_paused <= 0; pend_start <= 0;
        fading_out <= 0; fading_in <= 0; gain <= 0;
        p0a_req <= 0; p1a_req <= 0; fs <= F_IDLE;
        ff_clr <= 1;
    end else begin
        if (pl_start) begin
            pend_start <= 1;
            fading_out <= 1; fading_in <= 0;
            fade_rate <= 8'd1; fade_cnt <= 0;
            after_fade_pause <= 0;
            if (!(pl_on && !pl_paused)) gain <= 0;
        end
        if (pl_pause && pl_on && !pend_start) begin
            fading_out <= 1; fading_in <= 0;
            fade_rate <= p_rate;
            fade_cnt <= 0;
            after_fade_pause <= 1;
        end
        if (pl_resume && pl_on && pl_paused) begin
            pl_paused <= 0;
            fading_out <= 0;
            fading_in <= 1;
        end
    end

    // ------------------------------------------------------------- fetcher
    if (!pl_stop) case (fs)
    F_IDLE: begin
        if (want_fetch && !ff_clr) begin
            if (pl_phase == 0) begin
                p0a_addr <= {r_slot, 17'd0} + {6'd0, pos[17:1]};
                p0a_req <= 1;
                fs <= F_R0;
            end else if (ring_avail >= 32'd4) begin
                p1a_addr <= {2'b00, rd_count[21:1]};
                p1a_req <= 1;
                fs <= F_R0;
            end else if (fill_done) begin
                pl_ended <= 1;
            end
        end
    end

    F_R0: begin
        if (pl_phase == 0 ? p0a_ack : p1a_ack) begin
            fhw0 <= (pl_phase == 0) ? p0a_q : p1a_q;
            if (pl_phase == 0) begin p0a_req <= 0; p0a_addr <= p0a_addr + 1'd1; end
            else               begin p1a_req <= 0; p1a_addr <= {2'b00, p1a_addr[20:0] + 21'd1}; end
            fs <= F_R1;
        end
    end

    F_R1: begin
        if (pl_phase == 0) p0a_req <= 1; else p1a_req <= 1;
        if (pl_phase == 0 ? p0a_ack : p1a_ack) begin
            p0a_req <= 0; p1a_req <= 0;
            // word bytes: L lo, L hi, R lo, R hi
            ff_in <= {fhw0, (pl_phase == 0) ? p0a_q : p1a_q};
            fs <= F_PUSH;
        end
    end

    F_PUSH: begin
        ff_push <= 1;
        fs <= F_IDLE;
        if (abs_pos + 32'd4 >= r_len) abs_pos <= r_loop ? r_lstart : r_len;
        else abs_pos <= abs_pos + 32'd4;
        if (pl_phase == 0) begin
            if (pos + 32'd4 >= r_clen) begin
                if (r_len > r_clen) begin
                    pl_phase <= 1;                      // continue from the ring
                    pos <= pos + 32'd4;
                end else if (r_loop) begin
                    pos <= r_lstart;                    // whole track is cached
                end else begin
                    pl_ended <= 1;
                end
            end else begin
                pos <= pos + 32'd4;
            end
        end else begin
            rd_count <= rd_count + 32'd4;
        end
    end
    endcase

    // ---------------------------------------------- debug beeps
    if (dbg_req) begin
        bp_active <= 1; bp_on <= 1; bp_t <= 0; bp_half <= 6'd24;
        bp_long <= (dbg_n == 0);
        bp_left <= (dbg_n == 0) ? 4'd1 : dbg_n;
        bp_second <= (dbg_n == 0) ? 4'd0 : dbg_n2;
    end else if (blip_req && !bp_active) begin
        bp_active <= 1; bp_on <= 1; bp_t <= 0; bp_long <= 0; bp_left <= 1;
        bp_half <= blip_hi ? 6'd12 : 6'd48;
    end else if (tick && bp_active) begin
        bp_ph <= bp_ph + 1'd1;
        if (bp_ph >= bp_half) begin bp_ph <= 0; bp_sq <= ~bp_sq; end
        bp_t <= bp_t + 1'd1;
        if (bp_on) begin
            if (bp_t == (bp_long ? 16'd28800 : (bp_half == 6'd48 ? 16'd2400 : 16'd7200))) begin
                bp_on <= 0; bp_t <= 0;
                if (bp_left == 1) begin
                    if (bp_second != 0) begin
                        // second group: host result code, high pitch, after a pause
                        bp_left <= bp_second; bp_second <= 0; bp_half <= 6'd12;
                        bp_t <= 0; bp_on <= 0;
                    end else begin
                        bp_active <= 0;
                        bp_left <= 0;
                    end
                end else bp_left <= bp_left - 1'd1;
            end
        end else if (bp_t == 16'd9600) begin
            bp_on <= 1; bp_t <= 0;
        end
    end

    // ---------------------------------------------- 48 kHz output section
    case (os)
    0: if (tick) begin
        if (fading_out) begin
            if (fade_cnt >= fade_rate) begin
                fade_cnt <= 0;
                if (gain != 0) gain <= gain - 1'd1;
                else begin
                    fading_out <= 0;
                    if (pend_start) begin
                        // start the new track now
                        pend_start <= 0;
                        pl_on <= 1; pl_paused <= 0; pl_ended <= 0;
                        r_len <= p_len; r_clen <= p_clen; r_lstart <= p_lstart;
                        r_loop <= p_loop; r_slot <= p_slot;
                        pos <= p_sring ? 32'd0 : p_spos;
                        abs_pos <= p_spos;
                        pl_phase <= (p_clen == 0) | p_sring;
                        rd_count <= 0;
                        ff_clr <= 1;
                        p0a_req <= 0; p1a_req <= 0; fs <= F_IDLE;
                        s0l <= 0; s0r <= 0; s1l <= 0; s1r <= 0; ph <= 0;
                        fading_in <= 1;
                    end else if (after_fade_pause) begin
                        pl_paused <= 1;
                        after_fade_pause <= 0;
                    end
                end
            end else fade_cnt <= fade_cnt + 1'd1;
        end else if (fading_in) begin
            if (gain >= 9'd256) fading_in <= 0;
            else gain <= gain + 1'd1;
        end

        // advance the source position (44100 / 48000 = 147 / 160)
        if (pl_on && !pl_paused && !pend_start) begin
            if ({1'b0, ph} + 9'd147 >= 9'd160) begin
                ph <= ph + 8'd147 - 8'd160;
                s0l <= s1l; s0r <= s1r;
                if (ff_cnt != 0 && !ff_clr) begin
                    s1l <= {ff_head[23:16], ff_head[31:24]};
                    s1r <= {ff_head[7:0],   ff_head[15:8]};
                    ff_pop <= 1;
                end else if (pl_ended) begin
                    s1l <= 0; s1r <= 0;     // track finished: drain to silence
                    if (s0l == 0 && s0r == 0 && s1l == 0 && s1r == 0) pl_on <= 0;
                end
            end else ph <= ph + 8'd147;
        end
        os <= 1;
    end

    1: begin
        dl <= $signed({s1l[15], s1l}) - $signed({s0l[15], s0l});
        dr <= $signed({s1r[15], s1r}) - $signed({s0r[15], s0r});
        wq_i <= ph * 17'd410;            // ph / 160 in 0.16 fixed point
        os <= 2;
    end

    2: begin
        ml <= dl * $signed({1'b0, wq_i});
        mr <= dr * $signed({1'b0, wq_i});
        os <= 3;
    end

    3: begin
        il <= $signed(s0l) + ml[31:16];
        ir <= $signed(s0r) + mr[31:16];
        os <= 4;
    end

    4: begin
        gl <= (il * $signed({1'b0, gain})) >>> 8;
        gr <= (ir * $signed({1'b0, gain})) >>> 8;
        os <= 5;
    end

    5: begin
        gl <= (gl * $signed({2'b00, md_vol} + 10'd1)) >>> 8;
        gr <= (gr * $signed({2'b00, md_vol} + 10'd1)) >>> 8;
        os <= 6;
    end

    6: begin : out_stage
        reg signed [25:0] vl, vr;
        case (user_vol)
            2'd0: begin vl = gl;                 vr = gr; end
            2'd1: begin vl = gl - (gl >>> 2);    vr = gr - (gr >>> 2); end
            2'd2: begin vl = gl >>> 1;           vr = gr >>> 1; end
            default: begin vl = gl >>> 2;        vr = gr >>> 2; end
        endcase
        if (!pl_on) begin vl = 0; vr = 0; end

        out_l <= vl[15:0];
        out_r <= vr[15:0];
        out_tgl <= ~out_tgl;
        os <= 0;
    end

    default: os <= 0;
    endcase

    if (pl_stop) begin
        rd_count <= 0;
        pl_ended <= 0;
    end
end


///////////////////////////////////////////////////////////////////////////////
// Save states
//   The 68000 handler (system.sv) streams 16-bit words into PSRAM 0 slot 63
//   through ss_sreq_tgl. The Pocket reads / writes the same area through the
//   bridge at 0x50000000 (big endian 32-bit words = two stream words).
///////////////////////////////////////////////////////////////////////////////

localparam [22:0] SS_BASE = 23'h7E0000;        // word address of slot 63
localparam [15:0] SS_MAGIC = 16'h4D53;         // info block word 0 (stream word 0x40)

wire win_ss = (bridge_addr[31:28] == 4'h5);

reg [2:0] ss_sreq_s = 0, ss_done_s = 0;
reg       ss_st_prev = 0, ss_ld_prev = 0;
always @(posedge clk) begin
    ss_sreq_s <= {ss_sreq_s[1:0], ss_sreq_tgl};
    ss_done_s <= {ss_done_s[1:0], ss_done_tgl};
end

// bridge write FIFO (load data), 8 entries in registers
(* ramstyle = "logic" *) reg [47:0] sbw_q [0:7];
reg  [2:0]  sbw_wp = 0, sbw_rp = 0;
reg  [3:0]  sbw_cnt = 0;
wire [47:0] sbw_head = sbw_q[sbw_rp];
localparam [15:0] SS_LAST = 16'h91FF;   // last 32-bit word of the 0x24800 byte blob
reg         ss_last_seen = 0;           // the host wrote the end of a blob
// read prefetch FIFO (save data), 4 x 32 bit
reg  [31:0] pf_q [0:3];
reg  [1:0]  pf_wp = 0, pf_rp = 0;
reg  [2:0]  pf_cnt = 0;
reg         pf_on = 0;
reg         pf_miss = 0;           // the host asked out of order: serve the next fetch directly
reg  [15:0] pf_fetch = 0;          // next 32-bit word to fetch
reg  [15:0] pf_want = 0;           // next 32-bit word the host should ask for
reg  [31:0] ss_br_hold = 0;
assign ss_br_data = ss_br_hold;

reg  [3:0]  se = 0;                // PSRAM engine state
reg  [31:0] se_word = 0;
reg  [22:0] se_addr = 0;
reg         se_kind = 0;           // 0 = stream access, 1 = other
reg  [2:0]  sm = 0;                // save / load control state
reg  [28:0] sm_tmo = 0;
reg         sm_chk = 0, sm_chk_done = 0;
reg  [15:0] sm_magic = 0;

localparam SE_IDLE = 0, SE_STR = 1, SE_BW0 = 2, SE_BW1 = 3, SE_PF0 = 4, SE_PF1 = 5, SE_CHK = 6;
localparam SM_IDLE = 0, SM_SAVE = 1, SM_PRIME = 2, SM_LWAIT = 3, SM_LCHK = 4, SM_LOAD = 5;

always @(posedge clk) begin : ss_engine
    reg push_bw, pop_bw, pop_pf, push_pf, pf_rst;
    push_bw = 0; pop_bw = 0; pop_pf = 0; push_pf = 0; pf_rst = 0;

    ss_st_prev <= ss_start;
    ss_ld_prev <= ss_load;

    // ---------------- bridge side ----------------
    if (bridge_wr && win_ss && bridge_addr[17:2] == SS_LAST) ss_last_seen <= 1;
    if (bridge_wr && win_ss && sbw_cnt != 4'd8) begin
        sbw_q[sbw_wp] <= {bridge_addr[17:2], bridge_wr_data};
        sbw_wp <= sbw_wp + 1'd1;
        push_bw = 1;
        pf_on <= 0;
    end
    if (bridge_rd && win_ss) begin
        if (pf_on && pf_cnt != 0 && bridge_addr[17:2] == pf_want) begin
            ss_br_hold <= pf_q[pf_rp];
            pf_rp <= pf_rp + 1'd1;
            pop_pf = 1;
            pf_want <= pf_want + 1'd1;
        end
        else if (pf_on && bridge_addr[17:2] == pf_want - 1'd1) begin
            // same word again: the hold register still has it
        end
        else if (pf_on && bridge_addr[17:2] != pf_want) begin
            // out of order read: restart the prefetch there (this word is lost)
            pf_fetch <= bridge_addr[17:2];
            pf_want <= bridge_addr[17:2];
            pf_rp <= pf_wp;
            pf_rst = 1;
            pf_miss <= 1;
        end
    end

    // ---------------- PSRAM engine ----------------
    case (se)
    SE_IDLE:
        if (ss_sreq_s[2] != ss_sack_tgl) begin
            ssp_addr <= SS_BASE + {6'd0, ss_saddr};
            ssp_we <= ss_swe;
            ssp_wd <= ss_swd;
            ssp_req <= 1;
            se <= SE_STR;
        end
        else if (sbw_cnt != 0) begin
            se_addr <= SS_BASE + {6'd0, sbw_head[47:32], 1'b0};
            se_word <= sbw_head[31:0];
            sbw_rp <= sbw_rp + 1'd1;
            pop_bw = 1;
            ssp_addr <= SS_BASE + {6'd0, sbw_head[47:32], 1'b0};
            ssp_wd <= sbw_head[31:16];
            ssp_we <= 1;
            ssp_req <= 1;
            se <= SE_BW0;
        end
        else if (sm_chk) begin
            ssp_addr <= SS_BASE + 23'h40;
            ssp_we <= 0;
            ssp_req <= 1;
            se <= SE_CHK;
        end
        else if (pf_on && pf_cnt < 3'd3) begin
            se_addr <= SS_BASE + {6'd0, pf_fetch, 1'b0};
            ssp_addr <= SS_BASE + {6'd0, pf_fetch, 1'b0};
            ssp_we <= 0;
            ssp_req <= 1;
            se <= SE_PF0;
        end
    SE_STR:
        if (ssp_ack) begin
            ssp_req <= 0;
            ss_srd <= ssp_q;
            ss_sack_tgl <= ss_sreq_s[2];
            se <= SE_IDLE;
        end
    SE_BW0:
        if (ssp_ack) begin
            ssp_addr <= se_addr + 1'd1;
            ssp_wd <= se_word[15:0];
            se <= SE_BW1;
        end
    SE_BW1:
        if (ssp_ack) begin
            ssp_req <= 0;
            se <= SE_IDLE;
        end
    SE_PF0:
        if (ssp_ack) begin
            se_word[31:16] <= ssp_q;
            ssp_addr <= se_addr + 1'd1;
            se <= SE_PF1;
        end
    SE_PF1:
        if (ssp_ack) begin
            ssp_req <= 0;
            if (pf_on && pf_fetch == se_addr[16:1]) begin
                if (pf_miss) begin
                    ss_br_hold <= {se_word[31:16], ssp_q};
                    pf_miss <= 0;
                    pf_want <= pf_fetch + 1'd1;
                end else begin
                    pf_q[pf_wp] <= {se_word[31:16], ssp_q};
                    pf_wp <= pf_wp + 1'd1;
                    push_pf = 1;
                end
                pf_fetch <= pf_fetch + 1'd1;
            end
            se <= SE_IDLE;
        end
    SE_CHK:
        if (ssp_ack) begin
            ssp_req <= 0;
            sm_magic <= ssp_q;
            sm_chk_done <= 1;
            se <= SE_IDLE;
        end
    default: se <= SE_IDLE;
    endcase

    sbw_cnt <= sbw_cnt + push_bw - pop_bw;
    if (pf_rst) pf_cnt <= 0;
    else pf_cnt <= pf_cnt + push_pf - pop_pf;

    // ---------------- APF handshake ----------------
    if (~ss_start) ss_start_ack <= 0;
    if (~ss_load)  ss_load_ack  <= 0;
    sm_tmo <= sm_tmo + 1'd1;

    case (sm)
    SM_IDLE: begin
        if (ss_start & ~ss_st_prev) begin
            ss_start_ack <= 1;
            ss_start_busy <= 1;
            ss_start_ok <= 0;
            ss_start_err <= 0;
            pf_on <= 0;
            ss_save_tgl <= ~ss_save_tgl;
            ss_last_seen <= 0;
            ss_snap_trk <= cur_trk;
            ss_snap_pos <= abs_pos;
            ss_snap_loop <= ss_cur_loop;
            ss_snap_on <= playing;
            sm_tmo <= 0;
            sm <= SM_SAVE;
        end
        else if (ss_load & ~ss_ld_prev) begin
            ss_load_ack <= 1;
            ss_load_busy <= 1;
            ss_load_ok <= 0;
            ss_load_err <= 0;
            pf_on <= 0;
            sm_tmo <= 0;
            sm <= SM_LWAIT;
        end
    end
    SM_SAVE: begin
        if (ss_done_s[2] != ss_done_s[1]) begin
            pf_on <= 1;
            pf_fetch <= 0;
            pf_want <= 0;
            pf_rp <= pf_wp;
            pf_cnt <= 0;
            sm_tmo <= 0;
            sm <= SM_PRIME;
        end
        else if (sm_tmo[28]) begin            // ~3.6 s without a vblank interrupt
            ss_cancel_tgl <= ~ss_cancel_tgl;
            ss_start_busy <= 0;
            ss_start_err <= 1;
            sm <= SM_IDLE;
        end
    end
    SM_PRIME:
        if (pf_cnt >= 3'd3 || sm_tmo[16]) begin
            ss_start_busy <= 0;
            ss_start_ok <= 1;
            sm <= SM_IDLE;
        end
    SM_LWAIT:
        // the host may write the blob before or after the load command: wait for
        // its last word (or ~1.8 s), let the writes land, then check the magic word
        if ((ss_last_seen || sm_tmo[27]) && sbw_cnt == 0 && se == SE_IDLE && sm_tmo[10]) begin
            sm_chk <= 1;
            sm_chk_done <= 0;
            sm <= SM_LCHK;
        end
    SM_LCHK:
        if (sm_chk_done) begin
            sm_chk <= 0;
            sm_chk_done <= 0;
            sm_tmo <= 0;
            ss_last_seen <= 0;
            if (sm_magic == SS_MAGIC) begin
                ss_load_tgl <= ~ss_load_tgl;
                sm <= SM_LOAD;
            end
            else begin
                ss_load_busy <= 0;
                ss_load_err <= 1;
                sm <= SM_IDLE;
            end
        end
    SM_LOAD:
        if (ss_done_s[2] != ss_done_s[1]) begin
            ss_load_busy <= 0;
            ss_load_ok <= 1;
            sm <= SM_IDLE;
        end
        else if (sm_tmo[28] & sm_tmo[27]) begin   // ~5.4 s (MD+ may have to start first)
            ss_cancel_tgl <= ~ss_cancel_tgl;
            ss_load_busy <= 0;
            ss_load_err <= 1;
            sm <= SM_IDLE;
        end
    default: sm <= SM_IDLE;
    endcase

    if (~reset_n) begin
        sm <= SM_IDLE;
        ss_start_busy <= 0;
        ss_load_busy <= 0;
        pf_on <= 0;
    end
end


///////////////////////////////////////////////////////////////////////////////
// Save state diagnostic beeps (test build): one short high beep per step,
// a long low tone on an error.
//   save: request, handler started, handler done, ok
//   load: request, blob received, blob valid, handler started, handler done, ok
///////////////////////////////////////////////////////////////////////////////
reg  [2:0]  dg_act_s = 0;
reg  [2:0]  dg_pend_s = 0;
reg  [2:0]  dg_iack_s = 0, dg_vec_s = 0;
reg  [3:0]  dg_prog_s = 0;
reg  [4:0]  dg_mcnt = 0;           // handler progress beeps (lower pitch)
reg         dg_mid = 0;
reg         dg_st_p = 0, dg_ld_p = 0, dg_ok_p = 0, dg_err_p = 0, dg_lok_p = 0, dg_lerr_p = 0;
reg         dg_last_p = 0, dg_chk_p = 0;
reg  [2:0]  dg_done_p = 0;
reg  [4:0]  dg_cnt = 0;
reg         dg_err = 0;
reg         dg_busy = 0, dg_long = 0;
reg  [16:0] dg_t = 0;
reg  [5:0]  dg_ph = 0;
always @(posedge clk) begin : ss_diag
    reg [2:0] inc;
    reg       err;
    dg_act_s <= {dg_act_s[1:0], ss_act_in};
    dg_pend_s <= {dg_pend_s[1:0], ss_pend_in};
    dg_iack_s <= {dg_iack_s[1:0], ss_dbg_iack};
    dg_vec_s <= {dg_vec_s[1:0], ss_dbg_vec};
    dg_prog_s <= {dg_prog_s[2:0], ss_prog_tgl};
    dg_st_p <= ss_start;  dg_ld_p <= ss_load;
    dg_ok_p <= ss_start_ok; dg_err_p <= ss_start_err;
    dg_lok_p <= ss_load_ok; dg_lerr_p <= ss_load_err;
    dg_last_p <= ss_last_seen; dg_chk_p <= sm_chk_done;
    dg_done_p <= {dg_done_p[1:0], ss_done_s[2]};

    inc = 0; err = 0;
    if (ss_start & ~dg_st_p) inc = inc + 1'd1;
    if (ss_load & ~dg_ld_p) inc = inc + 1'd1;
    if (dg_act_s[1] & ~dg_act_s[2]) inc = inc + 1'd1;
    if (dg_pend_s[1] & ~dg_pend_s[2]) inc = inc + 1'd1;
    if (dg_iack_s[1] & ~dg_iack_s[2]) inc = inc + 1'd1;
    if (dg_vec_s[1] & ~dg_vec_s[2]) inc = inc + 1'd1;
    if (dg_done_p[2] != dg_done_p[1]) inc = inc + 1'd1;
    if (ss_start_ok & ~dg_ok_p) inc = inc + 1'd1;
    if (ss_load_ok & ~dg_lok_p) inc = inc + 1'd1;
    if (ss_last_seen & ~dg_last_p) inc = inc + 1'd1;
    if (sm_chk_done & ~dg_chk_p) begin
        if (sm_magic == SS_MAGIC) inc = inc + 1'd1; else err = 1;
    end
    if (ss_start_err & ~dg_err_p) err = 1;
    if (ss_load_err & ~dg_lerr_p) err = 1;

    dg_cnt <= dg_cnt + inc;
    if (err) dg_err <= 1;
    if (dg_prog_s[3] != dg_prog_s[2]) dg_mcnt <= dg_mcnt + 1'd1;

    if (!dg_busy) begin
        dg_on <= 0;
        if (dg_cnt != 0) begin
            dg_cnt <= dg_cnt + inc - 1'd1;
            dg_busy <= 1; dg_long <= 0; dg_mid <= 0; dg_t <= 0; dg_on <= 1;
        end
        else if (dg_mcnt != 0) begin
            dg_mcnt <= dg_mcnt - 1'd1 + (dg_prog_s[3] != dg_prog_s[2]);
            dg_busy <= 1; dg_long <= 0; dg_mid <= 1; dg_t <= 0; dg_on <= 1;
        end
        else if (dg_err) begin
            dg_err <= 0;
            dg_busy <= 1; dg_long <= 1; dg_mid <= 0; dg_t <= 0; dg_on <= 1;
        end
    end
    else if (tick) begin
        dg_t <= dg_t + 1'd1;
        dg_ph <= dg_ph + 1'd1;
        if (dg_ph >= (dg_long ? 6'd48 : dg_mid ? 6'd24 : 6'd12)) begin dg_ph <= 0; dg_sq <= ~dg_sq; end
        if (dg_t == (dg_long ? 17'd38400 : 17'd5760)) dg_on <= 0;          // 0.8 s / 0.12 s tone
        if (dg_t == (dg_long ? 17'd52800 : 17'd14400)) dg_busy <= 0;       // then silence
    end
end

endmodule
