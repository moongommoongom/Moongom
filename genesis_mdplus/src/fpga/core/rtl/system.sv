// Copyright (c) 2010 Gregory Estrade (greg@torlus.com)
// Copyright (c) 2018 Sorgelig
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// Redistributions in synthesized form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// Neither the name of the author nor the names of other contributors may
// be used to endorse or promote products derived from this software without
// specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Please report bugs to the author, but before you do so, please
// make sure that this is not a derivative work and that
// you have the latest version of this file.

module system
(
	input         RESET_N,
	input         MCLK,

	input   [1:0] LPF_MODE,
	input         ENABLE_FM,
	input         ENABLE_PSG,
	output [15:0] DAC_LDATA,
	output [15:0] DAC_RDATA,

	input         LOADING,
	input         PAL,
	input         EXPORT,
	input         FAST_FIFO,
	input         SRAM_QUIRK,
	input         SRAM00_QUIRK,
	input         EEPROM_QUIRK,
	input         NORAM_QUIRK,
	input         PIER_QUIRK,
	input         SVP_QUIRK, 
	input         FMBUSY_QUIRK,
	input         SCHAN_QUIRK,

	// MD+ (MegaSD style) command port at $3F7FA/$3F7FC/$3F7FE
	input         MDP_EN,
	input         MDP_BUSY,           // MD+ armed or booting
	output reg    MDP_TRIG = 0,       // toggles on the first CD54 write: start MD+
	output reg [15:0] MDP_CMD = 0,
	output reg    MDP_CMD_TGL = 0,
	input         MDP_PLAYING,

	// save states (Pocket Memories). Toggles come from clk_74a and are synchronized here.
	input         SS_SAVE_TGL,
	input         SS_LOAD_TGL,
	input         SS_CANCEL_TGL,
	output reg    SS_DONE_TGL = 0,
	output reg    SS_SREQ_TGL = 0,     // stream word access (PSRAM, clk_74a side)
	output reg    SS_SWE = 0,
	output reg [16:0] SS_SADDR = 0,
	output reg [15:0] SS_SWD = 0,
	input         SS_SACK_TGL,
	input  [15:0] SS_SRD,
	input   [6:0] SS_MDP_TRK,         // MD+ track / byte position when the save started
	input  [31:0] SS_MDP_POS,
	input         SS_MDP_LOOP,
	input         SS_MDP_ON,
	output reg [31:0] SS_SEEK_POS = 0, // MD+ resume position on load
	output        SS_ACT,              // save state handler running (diagnostics)
	output        SS_PEND,             // save state request waiting for vblank (diagnostics)
	output reg    SS_DBG_IACK = 0,     // an interrupt acknowledge was seen while pending
	output reg    SS_DBG_VEC = 0,      // a read of $78 was seen while pending
	output reg    SS_PROG_TGL = 0,     // handler progress mark (diagnostics)

	input   [1:0] TURBO,

	input         GG_RESET,
	input         GG_EN,
	input [128:0] GG_CODE,
	output        GG_AVAILABLE,

	input  [14:0] BRAM_A,
	input  [15:0] BRAM_DI,
	output [15:0] BRAM_DO,
	input         BRAM_WE,
	output        BRAM_CHANGE,

	output  [3:0] RED,
	output  [3:0] GREEN,
	output  [3:0] BLUE,
	output        VS,
	output        HS,
	output        HBL,
	output        VBL,
	output        CE_PIX,
	input         BORDER,
	input         CRAM_DOTS,

	output        INTERLACE,
	output        FIELD,
	output  [1:0] RESOLUTION,

	input         J3BUT,
	input  [11:0] JOY_1,
	input  [11:0] JOY_2,
	input  [11:0] JOY_3,
	input  [11:0] JOY_4,
	input  [11:0] JOY_5,
	input   [2:0] MULTITAP,

	input  [24:0] MOUSE,
	input   [2:0] MOUSE_OPT,
	
	input         GUN_OPT,
	input         GUN_TYPE,
	input         GUN_SENSOR,
	input         GUN_A,
	input         GUN_B,
	input         GUN_C,
	input         GUN_START,

	input   [7:0] SERJOYSTICK_IN,
	output  [7:0] SERJOYSTICK_OUT,
	input   [1:0] SER_OPT,

	input  [24:1] ROMSZ,
	output [24:1] ROM_ADDR,
	input  [15:0] ROM_DATA,
	output [15:0] ROM_WDATA,
	output reg    ROM_WE,
	output  [1:0] ROM_BE,
	output reg    ROM_REQ,
	input         ROM_ACK,

	output [24:1] ROM_ADDR2,
	input  [15:0] ROM_DATA2,
	output        ROM_REQ2,
	input         ROM_ACK2, 
	
	input         EN_HIFI_PCM,
	input         LADDER,
	input         OBJ_LIMIT_HIGH,

	output		  TRANSP_DETECT,
	
	//debug
	input         PAUSE_EN,
	input         BGA_EN,
	input         BGB_EN,
	input         SPR_EN,
	output [23:0] DBG_M68K_A,
	output [23:0] DBG_VBUS_A
);

reg reset;
reg hard_reset;

//--------------------------------------------------------------
// SAVE STATES - shared declarations
//--------------------------------------------------------------
// The state is taken by the 68000 itself: on the next vblank interrupt the vector
// fetch is redirected to a small handler (ss_hrom, overlay at $5F0000) that streams
// registers, RAMs and VDP memories through a port into PSRAM. Write-only chip
// registers (VDP, PSG, YM2612) are shadowed here; the Z80 is stopped on an
// instruction boundary and its registers are read/written through T80 REG/DIR.
reg        ss_pend = 0, ss_mode_ld = 0, ss_vec = 0, ss_vec_tail = 0;
reg        ss_act = 0, ss_closing = 0;
reg        ss_iack = 0;
reg        ss_zfrz_req = 0, ss_apply_req = 0;
reg [16:0] ss_ptr = 0;
reg [223:0] ss_dir_ld = 0;
reg  [3:0] ss_zst_ld = 0;
reg [15:0] mdp_last_play = 0, mdp_last_vol = 0;
reg [15:0] mdp_ld_play = 0, mdp_ld_vol = 0;
reg        mdp_ld_playing = 0;
reg [15:0] mdp_ld_snap = 0;
wire       mdp_ld_on  = mdp_ld_snap[15] | (mdp_ld_playing && mdp_ld_play != 0);
wire [15:0] mdp_ld_cmd = mdp_ld_snap[15] ? {(mdp_ld_snap[14] ? 8'h1B : 8'h1A), 1'b0, mdp_ld_snap[6:0]} : mdp_ld_play;
reg        ss_iw = 0, ss_fw = 0, ss_bar_we = 0;
reg  [6:0] ss_iw_idx = 0;
reg  [7:0] ss_fw_idx = 0;
reg [15:0] ss_iw_d = 0, ss_fw_d = 0;
reg [15:0] ss_info_q;
wire [15:0] fmsh_q;
wire [15:0] hrom_q;
reg        ss_zfrozen = 0, ss_at_m1 = 0, ss_halted = 0;
reg        ss_apply_busy = 0, ss_zctl_we = 0, ss_dirset = 0, ss_zabort = 0;
reg        fm_ovr = 0, fm_we = 0;
reg  [1:0] fm_a = 0;
reg  [7:0] fm_d = 0;
reg  [8:0] ap_reg = 0;
reg        ss_mdp_cmd_req = 0, ss_mdp_trig_req = 0;
reg [15:0] ss_mdp_cmd_val = 0;
wire [211:0] Z80_REG;
wire       Z80_M1_N, Z80_HALT_N;
wire       ss_busy = ss_pend | ss_vec | ss_act;
assign     SS_ACT = ss_act;
assign     SS_PEND = ss_pend;
// Z80 registers to load: a halted Z80 restarts on its HALT opcode
wire [211:0] ss_dir = {ss_dir_ld[211:80], ss_dir_ld[79:64] - {15'd0, ss_zst_ld[3]}, ss_dir_ld[63:0]};
wire       ss_zfree = ss_zfrozen;
wire       PAUSE = PAUSE_EN & ~ss_busy;    // a save/load must be able to run in the menu

reg [2:0] ss_sv_s = 0, ss_ld_s = 0, ss_cn_s = 0, ss_ack_s = 0;
always @(posedge MCLK) begin
	ss_sv_s  <= {ss_sv_s[1:0],  SS_SAVE_TGL};
	ss_ld_s  <= {ss_ld_s[1:0],  SS_LOAD_TGL};
	ss_cn_s  <= {ss_cn_s[1:0],  SS_CANCEL_TGL};
	ss_ack_s <= {ss_ack_s[1:0], SS_SACK_TGL};
end
wire ss_sv_ev = ss_sv_s[2] ^ ss_sv_s[1];
wire ss_ld_ev = ss_ld_s[2] ^ ss_ld_s[1];
wire ss_cn_ev = ss_cn_s[2] ^ ss_cn_s[1];
always @(posedge MCLK) if(M68K_CLKENn) begin
	reset <= ~RESET_N | LOADING;
	hard_reset <= LOADING;
end

//--------------------------------------------------------------
// CLOCK ENABLERS
//--------------------------------------------------------------
wire M68K_CLKEN = M68K_CLKENp;
reg  M68K_CLKENp, M68K_CLKENn;
reg  Z80_CLKENp, Z80_CLKENn, PSG_CLKEN;
reg  FM_CLKEN;

always @(negedge MCLK) begin
	reg [3:0] FCLKCNT = 0;
	reg [3:0] VCLKCNT = 0;
	reg [3:0] ZCLKCNT = 0;
	reg [3:0] PCLKCNT = 0;
	reg [3:0] VCLKMAX = 0;
	reg [3:0] VCLKMID = 0;

	if(~RESET_N | LOADING) begin
		VCLKCNT <= 0;
		PCLKCNT <= 0;
		FCLKCNT <= 0;
		Z80_CLKENp <= 1;
		Z80_CLKENn <= 1;
		PSG_CLKEN <= 1;
		M68K_CLKENp <= 1;
		M68K_CLKENn <= 1;
		VCLKMAX = 6;
		VCLKMID = 3;
	end
	else begin
		Z80_CLKENn <= 0;
		ZCLKCNT <= ZCLKCNT + 1'b1;
		if (ZCLKCNT == 14) begin
			ZCLKCNT <= 0;
			Z80_CLKENn <= ~PAUSE;
		end
		
		Z80_CLKENp <= 0;
		if (ZCLKCNT == 7) begin
			Z80_CLKENp <= ~PAUSE;
		end

		PSG_CLKEN <= 0;
		PCLKCNT <= PCLKCNT + 1'b1;
		if (PCLKCNT == 14) begin
			PCLKCNT <= 0;
			PSG_CLKEN <= ~PAUSE;
		end

		M68K_CLKENp <= 0;
		VCLKCNT <= VCLKCNT + 1'b1;
		if (VCLKCNT == VCLKMAX) begin
			VCLKCNT <= 0;
			M68K_CLKENp <= ~PAUSE;
			VCLKMAX <= (TURBO == 2) ? 4'd1 : (TURBO == 1) ? 4'd3 : 4'd6;
			VCLKMID <= (TURBO == 2) ? 4'd0 : (TURBO == 1) ? 4'd1 : 4'd3;
		end

		M68K_CLKENn <= 0;
		if (VCLKCNT == VCLKMID) begin
			M68K_CLKENn <= ~PAUSE;
		end

		FM_CLKEN <= 0;
		FCLKCNT <= FCLKCNT + 1'b1;
		if (FCLKCNT == 6) begin
			FCLKCNT <= 0;
			FM_CLKEN <= ~PAUSE;
		end
	end
end

reg [16:1] ram_rst_a;
always @(posedge MCLK) ram_rst_a <= ram_rst_a + LOADING;


//--------------------------------------------------------------
// CPU 68000
//--------------------------------------------------------------
wire [23:1] M68K_A;
wire [15:0] M68K_DO;
wire        M68K_AS_N;
wire        M68K_UDS_N;
wire        M68K_LDS_N;
wire        M68K_RNW;
wire  [2:0] M68K_FC;
wire        M68K_BG_N;
wire        M68K_BR_N;
wire        M68K_BGACK_N;

reg   [2:0] M68K_IPL_N;
always @(posedge MCLK) begin
	reg       old_as;
	reg [1:0] scnt;
	
	if(reset) M68K_IPL_N <= 3'b111;
	else if (M68K_CLKEN) begin
		old_as <= M68K_AS_N;
		scnt <= scnt + 1'd1;
		if(~M68K_AS_N) scnt <= 0;
		if((~old_as & M68K_AS_N) || &scnt) begin
			if (M68K_VINT) M68K_IPL_N <= 3'b001;
			else if (M68K_HINT) M68K_IPL_N <= 3'b011;
			else if (M68K_EXINT) M68K_IPL_N <= 3'b101;
			else M68K_IPL_N <= 3'b111;
		end
	end
end

wire M68K_INTACK = &M68K_FC;

assign M68K_BR_N = VBUS_BR_N & Z80_BR_N;
assign M68K_BGACK_N = VBUS_BGACK_N & Z80_BGACK_N;

fx68k M68K
(
	.clk(MCLK),
	.extReset(reset),
	.pwrUp(hard_reset),
	.enPhi1(M68K_CLKENp),
	.enPhi2(M68K_CLKENn),

	.eRWn(M68K_RNW),
	.ASn(M68K_AS_N),
	.UDSn(M68K_UDS_N),
	.LDSn(M68K_LDS_N),

	.FC0(M68K_FC[0]),
	.FC1(M68K_FC[1]),
	.FC2(M68K_FC[2]),

	.BGn(M68K_BG_N),
	.BRn(M68K_BR_N),
	.BGACKn(M68K_BGACK_N),
	.HALTn(1),

	.DTACKn(M68K_MBUS_DTACK_N),
	.VPAn(~M68K_INTACK),
	.BERRn(1),
	.IPL0n(M68K_IPL_N[0]),
	.IPL1n(M68K_IPL_N[1]),
	.IPL2n(M68K_IPL_N[2]),
	.iEdb(genie_data),
	.oEdb(M68K_DO),
	.eab(M68K_A)
);


assign DBG_M68K_A = {M68K_A,1'b0};
assign DBG_VBUS_A = {VBUS_A,1'b0};

//--------------------------------------------------------------
// CHEAT CODES
//--------------------------------------------------------------

wire [15:0] genie_data;
CODES #(.ADDR_WIDTH(24), .DATA_WIDTH(16), .BIG_ENDIAN(1)) codes
(
	.clk(MCLK),
	.reset(LOADING | GG_RESET),
	.enable(~GG_EN),
	.code(GG_CODE),
	.available(GG_AVAILABLE),
	.addr_in({M68K_A[23:1], 1'b0}),
	.data_in(M68K_MBUS_D),
	.data_out(genie_data)
);


//--------------------------------------------------------------
// VDP + PSG
//--------------------------------------------------------------
reg         VDP_SEL;
wire [15:0] VDP_DO;
wire        VDP_DTACK_N;

wire [23:1] VBUS_A;
wire        VBUS_SEL;
wire        VBUS_BR_N;
wire        VBUS_BGACK_N;

wire        M68K_EXINT;
wire        M68K_HINT;
wire        M68K_VINT;
wire        Z80_VINT;

wire        vram_req;
wire        vram_we_u = vram_we & ~vram_u_n;
wire        vram_we_l = vram_we & ~vram_l_n;
wire        vram_we;
wire        vram_u_n;
wire        vram_l_n;
wire [15:1] vram_a;
wire [15:0] vram_d;
wire [15:0] vram_q1, vram_q2;

wire        vram32_req;
wire [15:1] vram32_a;
wire [31:0] vram32_q;

dpram #(14) vram_l1
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[7:0]),
	.wren_a(vram_we_l & (vram_ack ^ vram_req) & ~vram_a[1]),
	.q_a(vram_q1[7:0]),

	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.wren_b(LOADING),
	.q_b(vram32_q[7:0])
);

dpram #(14) vram_u1
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[15:8]),
	.wren_a(vram_we_u & (vram_ack ^ vram_req) & ~vram_a[1]),
	.q_a(vram_q1[15:8]),

	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.wren_b(LOADING),
	.q_b(vram32_q[15:8])
);

dpram #(14) vram_l2
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[7:0]),
	.wren_a(vram_we_l & (vram_ack ^ vram_req) & vram_a[1]),
	.q_a(vram_q2[7:0]),

	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.wren_b(LOADING),
	.q_b(vram32_q[23:16])
);

dpram #(14) vram_u2
(
	.clock(MCLK),
	.address_a(vram_a[15:2]),
	.data_a(vram_d[15:8]),
	.wren_a(vram_we_u & (vram_ack ^ vram_req) & vram_a[1]),
	.q_a(vram_q2[15:8]),

	.address_b(LOADING ? ram_rst_a[14:1] : vram32_a[15:2]),
	.wren_b(LOADING),
	.q_b(vram32_q[31:24])
);

reg vram_ack;
always @(posedge MCLK) vram_ack <= vram_req;

reg vram32_ack;
always @(posedge MCLK) vram32_ack <= vram32_req;

wire VDP_hs, VDP_vs;
assign HS = ~VDP_hs;
assign VS = ~VDP_vs;

wire HL;

vdp vdp
(
	.RST_n(~hard_reset),
	.CLK(MCLK),

	.SEL(VDP_SEL),
	.A({MBUS_A[4:1], 1'b0}),
	.RNW(MBUS_RNW),
	.DI(MBUS_DO),
	.DO(VDP_DO),
	.DTACK_n(VDP_DTACK_N),

	.VRAM_req(vram_req),
	.VRAM_ack(vram_ack),
	.VRAM_we(vram_we),
	.VRAM_u_n(vram_u_n),
	.VRAM_l_n(vram_l_n),
	.VRAM_a(vram_a),
	.VRAM_d(vram_d),
	.VRAM_q(vram_a[1] ? vram_q2 : vram_q1),

	.VRAM32_req(vram32_req),
	.VRAM32_ack(vram32_ack),
	.VRAM32_a(vram32_a),
	.VRAM32_q(vram32_q),
	
	.EXINT(M68K_EXINT),
	.HL(HL),
	
	.HINT(M68K_HINT),
	.VINT_TG68(M68K_VINT),
	.INTACK(M68K_INTACK),

	.VINT_T80(Z80_VINT),

	.VBUS_addr(VBUS_A),
	.VBUS_data(VDP_MBUS_D),
	.VBUS_sel(VBUS_SEL),
	.VBUS_dtack_n(VDP_MBUS_DTACK_N),

	.BG_N(M68K_BG_N),
	.BR_N(VBUS_BR_N),
	.BGACK_N(VBUS_BGACK_N),

	.VRAM_SPEED(~(FAST_FIFO|TURBO)),
	.VSCROLL_BUG(0),
	.BORDER_EN(BORDER),
	.CRAM_DOTS(CRAM_DOTS),
	.SVP_QUIRK(SVP_QUIRK),
	.OBJ_LIMIT_HIGH_EN(OBJ_LIMIT_HIGH),

	.FIELD_OUT(FIELD),
	.INTERLACE(INTERLACE),
	.RESOLUTION(RESOLUTION),

	.PAL(PAL),
	.R(RED),
	.G(GREEN),
	.B(BLUE),
	.HS(VDP_hs),
	.VS(VDP_vs),
	.CE_PIX(CE_PIX),
	.HBL(HBL),
	.VBL(VBL),

	.TRANSP_DETECT(TRANSP_DETECT),
	
	.BGA_EN(BGA_EN),
	.BGB_EN(BGB_EN),
	.SPR_EN(SPR_EN)
);

// PSG 0x10-0x17 in VDP space
wire signed [10:0] PSG_SND;
jt89 psg
(
	.rst(reset),
	.clk(MCLK),
	.clk_en(PSG_CLKEN),

	.wr_n(MBUS_RNW | ~VDP_SEL | ~MBUS_A[4] | MBUS_A[3]),
	.din(MBUS_DO[15:8]),

	.sound(PSG_SND)
);


//--------------------------------------------------------------
// Gamepads
//--------------------------------------------------------------
reg         IO_SEL;
wire  [7:0] IO_DO;
wire        IO_DTACK_N;

reg         JCART_SEL;
wire [15:0] JCART_DO;
wire        JCART_DTACK_N;

multitap multitap
(
	.RESET(hard_reset),
	.CLK(MCLK),
	.CE(M68K_CLKEN),

	.J3BUT(J3BUT),

	.P1_UP(~JOY_1[3]),
	.P1_DOWN(~JOY_1[2]),
	.P1_LEFT(~JOY_1[1]),
	.P1_RIGHT(~JOY_1[0]),
	.P1_A(~JOY_1[4]),
	.P1_B(~JOY_1[5]),
	.P1_C(~JOY_1[6]),
	.P1_START(~JOY_1[7]),
	.P1_MODE(~JOY_1[8]),
	.P1_X(~JOY_1[9]),
	.P1_Y(~JOY_1[10]),
	.P1_Z(~JOY_1[11]),

	.P2_UP(~JOY_2[3]),
	.P2_DOWN(~JOY_2[2]),
	.P2_LEFT(~JOY_2[1]),
	.P2_RIGHT(~JOY_2[0]),
	.P2_A(~JOY_2[4]),
	.P2_B(~JOY_2[5]),
	.P2_C(~JOY_2[6]),
	.P2_START(~JOY_2[7]),
	.P2_MODE(~JOY_2[8]),
	.P2_X(~JOY_2[9]),
	.P2_Y(~JOY_2[10]),
	.P2_Z(~JOY_2[11]),

	.P3_UP(~JOY_3[3]),
	.P3_DOWN(~JOY_3[2]),
	.P3_LEFT(~JOY_3[1]),
	.P3_RIGHT(~JOY_3[0]),
	.P3_A(~JOY_3[4]),
	.P3_B(~JOY_3[5]),
	.P3_C(~JOY_3[6]),
	.P3_START(~JOY_3[7]),
	.P3_MODE(~JOY_3[8]),
	.P3_X(~JOY_3[9]),
	.P3_Y(~JOY_3[10]),
	.P3_Z(~JOY_3[11]),

	.P4_UP(~JOY_4[3]),
	.P4_DOWN(~JOY_4[2]),
	.P4_LEFT(~JOY_4[1]),
	.P4_RIGHT(~JOY_4[0]),
	.P4_A(~JOY_4[4]),
	.P4_B(~JOY_4[5]),
	.P4_C(~JOY_4[6]),
	.P4_START(~JOY_4[7]),
	.P4_MODE(~JOY_4[8]),
	.P4_X(~JOY_4[9]),
	.P4_Y(~JOY_4[10]),
	.P4_Z(~JOY_4[11]),
	
	.P5_UP(~JOY_5[3]),
	.P5_DOWN(~JOY_5[2]),
	.P5_LEFT(~JOY_5[1]),
	.P5_RIGHT(~JOY_5[0]),
	.P5_A(~JOY_5[4]),
	.P5_B(~JOY_5[5]),
	.P5_C(~JOY_5[6]),
	.P5_START(~JOY_5[7]),
	.P5_MODE(~JOY_5[8]),
	.P5_X(~JOY_5[9]),
	.P5_Y(~JOY_5[10]),
	.P5_Z(~JOY_5[11]),

	.FOURWAY_EN(MULTITAP == 1),
	.TEAMPLAYER_EN({MULTITAP == 3,MULTITAP == 2}),

	.MOUSE(MOUSE),
	.MOUSE_OPT(MOUSE_OPT),
	
	.GUN_OPT(GUN_OPT),
	.GUN_TYPE(GUN_TYPE),
	.GUN_SENSOR(GUN_SENSOR),
	.GUN_A(GUN_A),
	.GUN_B(GUN_B),
	.GUN_C(GUN_C),
	.GUN_START(GUN_START),

	.SERJOYSTICK_IN(SERJOYSTICK_IN),
	.SERJOYSTICK_OUT(SERJOYSTICK_OUT),
	.SER_OPT(SER_OPT),

	.PAL(PAL),
	.EXPORT(EXPORT),

	.SEL(IO_SEL),
	.A(MBUS_A[4:1]),
	.RNW(MBUS_RNW),
	.DI(MBUS_DO[7:0]),
	.DO(IO_DO),
	.DTACK_N(IO_DTACK_N),
	.HL(HL),

	.JCART_SEL(JCART_SEL),
	.JCART_DO(JCART_DO),
	.JCART_DTACK_N(JCART_DTACK_N)
);


//-----------------------------------------------------------------------
// ROM
//-----------------------------------------------------------------------

assign ROM_ADDR = BANK_ROM ? {BANK_REG[MBUS_A[21:19]], MBUS_A[18:1]} : MBUS_A;
assign ROM_BE = ~{MBUS_UDS_N, MBUS_LDS_N};
assign ROM_WDATA = MBUS_DO;

//-----------------------------------------------------------------------
// 64KB SRAM / 128KB SVP DRAM
//-----------------------------------------------------------------------
reg SRAM_SEL;
wire [15:0] sram_addr;
wire [7:0] sram_di;
wire sram_wren;

always_comb begin
	if (PIER_QUIRK) begin
		sram_addr = {4'b0000, m95_addr};
		sram_di = m95_di;
		sram_wren = m95_rnw;
	end else begin
		sram_addr = MBUS_A[16:1];
		sram_di = MBUS_DO[7:0];
		sram_wren = SRAM_SEL & ~MBUS_RNW;
	end
end

dpram_dif #(17,8,16,16) sram
(
	.clock(MCLK),
	.address_a(sram_addr),
	.data_a(sram_di),
	.wren_a(sram_wren & ~SVP_QUIRK),
	.q_a(sram_q),

	.address_b(LOADING ? ram_rst_a : SVP_QUIRK ? SVP_DRAM_A : BRAM_A),
	// Initializes SRAM to 0x0 for Sonic 1 Remastered, all other games have SRAM initialized to 0xFF
	.data_b(LOADING ? (SRAM00_QUIRK ? 16'h0000 : 16'hFFFF) : SVP_QUIRK ? SVP_DRAM_DO : BRAM_DI),
	.wren_b(LOADING | SVP_DRAM_WE | BRAM_WE),
	.q_b(BRAM_DO)
);

wire [7:0] sram_q;
assign BRAM_CHANGE = sram_wren;

//-----------------------------------------------------------------------
// EEPROM Handling
//-----------------------------------------------------------------------
reg ep_si, m95_so, ep_sck, ep_hold, ep_cs;
wire [7:0] m95_di, m95_q;
wire [11:0] m95_addr;
wire m95_rnw;

STM95XXX pier_eeprom
(
	.clk(MCLK),
	.enable(PIER_QUIRK),
	.so(m95_so),
	.si(ep_si),
	.sck(ep_sck),
	.hold_n(ep_hold),
	.cs_n(ep_cs),
	.wp_n(1'b1),
	.ram_addr(m95_addr),
	.ram_q(sram_q),
	.ram_di(m95_di),
	.ram_RnW(m95_rnw)
);

//-----------------------------------------------------------------------
// SVP
//-----------------------------------------------------------------------
reg         SVP_SEL;
wire [15:0] SVP_DO;
wire        SVP_DTACK_N;

wire [15:0] SVP_DRAM_A;
wire [15:0] SVP_DRAM_DO;
wire        SVP_DRAM_WE;
wire [15:0] SVP_DRAM_DI = BRAM_DO;

reg SVP_CLKEN;
always @(posedge MCLK) SVP_CLKEN <= ~reset & ~SVP_CLKEN;

SVP svp
(
	.CLK(MCLK),
	.CE(SVP_CLKEN),
	.RST_N(~reset & SVP_QUIRK),
	.ENABLE(1),

	.BUS_A(MBUS_A[23:1]),
	.BUS_DO(SVP_DO),
	.BUS_DI(MBUS_DO),
	.BUS_SEL(SVP_SEL),
	.BUS_RNW(MBUS_RNW),
	.BUS_DTACK_N(SVP_DTACK_N),
	.DMA_ACTIVE(VBUS_SEL),

	.ROM_A(ROM_ADDR2),
	.ROM_DI(ROM_DATA2),
	.ROM_REQ(ROM_REQ2),
	.ROM_ACK(ROM_ACK2),

	.DRAM_A(SVP_DRAM_A),
	.DRAM_DI(SVP_DRAM_DI),
	.DRAM_DO(SVP_DRAM_DO),
	.DRAM_WE(SVP_DRAM_WE)
);


//-----------------------------------------------------------------------
// 68K RAM
//-----------------------------------------------------------------------
reg RAM_SEL;

dpram #(15) ram68k_u
(
	.clock(MCLK),
	.address_a(MBUS_A[15:1]),
	.data_a(MBUS_DO[15:8]),
	.wren_a(RAM_SEL & ~MBUS_RNW & ~MBUS_UDS_N),
	.q_a(ram68k_q[15:8]),

	.address_b(ram_rst_a[15:1]),
	.wren_b(LOADING)
);

dpram #(15) ram68k_l
(
	.clock(MCLK),
	.address_a(MBUS_A[15:1]),
	.data_a(MBUS_DO[7:0]),
	.wren_a(RAM_SEL & ~MBUS_RNW & ~MBUS_LDS_N),
	.q_a(ram68k_q[7:0]),

	.address_b(ram_rst_a[15:1]),
	.wren_b(LOADING)
);
wire [15:0] ram68k_q;

//-----------------------------------------------------------------------
// MBUS Handling
//-----------------------------------------------------------------------
reg        M68K_MBUS_DTACK_N;
reg        Z80_MBUS_DTACK_N;
reg        VDP_MBUS_DTACK_N;

reg [15:0] M68K_MBUS_D;
reg  [7:0] Z80_MBUS_D;
reg [15:0] VDP_MBUS_D;

reg [23:1] MBUS_A;
reg [15:0] MBUS_DO;
reg        MDP_WIN = 0;
reg  [3:0] mdp_wait_cnt = 0;

reg        MBUS_RNW;
reg        MBUS_UDS_N;
reg        MBUS_LDS_N;

reg [15:0] NO_DATA;

reg  [4:0] BANK_REG[0:7];
reg        BANK_ROM;
reg        BANK_SRAM;

reg  [4:0] mstate;
reg  [1:0] msrc;
	
localparam	MSRC_NONE = 0,
				MSRC_M68K = 1,
				MSRC_Z80  = 2,
				MSRC_VDP  = 3;

localparam 	MBUS_IDLE         = 0,
				MBUS_SELECT       = 1,
				MBUS_RAM_READ     = 2,
				MBUS_ROM_READ     = 3,
				MBUS_ROM_WRITE    = 4,
				MBUS_VDP_READ     = 5,
				MBUS_IO_READ      = 6,
				MBUS_JCRT_READ    = 7,
				MBUS_SRAM_READ    = 8,
				MBUS_ZBUS_PRE     = 9,
				MBUS_ZBUS_WS 	   = 10,
				MBUS_ZBUS_READ    = 11,
				MBUS_SVP_READ     = 12,
				MBUS_REFRESH      = 13,
				MBUS_FINISH       = 14,
				MBUS_Z80_PREREAD  = 15,
				MBUS_MDP_WAIT     = 16,
				MBUS_SS           = 17,
				MBUS_SS_WAIT      = 18,
				MBUS_SS_ROM       = 19,
				MBUS_SS_ROM2      = 20;

				
always @(posedge MCLK) begin
	reg [15:0] data;
	reg  [3:0] pier_count;
	reg [8:0] refresh_timer;
	reg rfs_pend;
	reg [1:0] rfs_wait;
	reg [1:0] cycle_cnt;

	if (reset) begin
		M68K_MBUS_DTACK_N <= 1;
		Z80_MBUS_DTACK_N  <= 1;
		VDP_MBUS_DTACK_N  <= 1;
		VDP_SEL <= 0;
		IO_SEL <= 0;
		SVP_SEL <= 0; 
		ZBUS_SEL <= 0;
		BANK_ROM <= 0;
		BANK_SRAM <= 0;
		MDP_WIN <= 0;
		ss_pend <= 0;
		ss_vec <= 0;
		ss_act <= 0;
		ss_closing <= 0;
		ss_zfrz_req <= 0;
		mstate <= MBUS_IDLE;
		pier_count <= 0;
		MBUS_RNW <= 1;
		NO_DATA <= 'h4E71;
		BANK_REG <= '{0,1,2,3,4,5,6,7};
	end
	else begin
	/*
		refresh_timer <= refresh_timer + 1'd1;
		if (refresh_timer == 'h17F) begin
			refresh_timer <= 0;
			rfs_pend <= 1;
		end
	*/	
		if (M68K_CLKENp) begin
			if (cycle_cnt) cycle_cnt = cycle_cnt - 1'd1;
		end

		if (M68K_AS_N) M68K_MBUS_DTACK_N <= 1;
		if (~Z80_IO)   Z80_MBUS_DTACK_N  <= 1;
		if (~VBUS_SEL) VDP_MBUS_DTACK_N  <= 1;
		if (ss_zabort) Z80_MBUS_DTACK_N  <= 1;

		// save states: requests from the Pocket
		ss_apply_req <= 0;
		ss_iw <= 0;
		ss_fw <= 0;
		ss_bar_we <= 0;
		if ((ss_sv_ev | ss_ld_ev) & ~ss_busy) begin
			SS_DBG_IACK <= 0;
			SS_DBG_VEC <= 0;
			ss_pend <= 1;
			ss_mode_ld <= ss_ld_ev;
		end
		if (ss_cn_ev & ss_pend & ~ss_act) ss_pend <= 0;
		if (ss_mdp_cmd_req) begin
			MDP_CMD <= ss_mdp_cmd_val;
			MDP_CMD_TGL <= ~MDP_CMD_TGL;
		end
		if (ss_mdp_trig_req) MDP_TRIG <= ~MDP_TRIG;

		case(mstate)
		MBUS_IDLE:
			begin
				CTRL_SEL <= 0;
				SRAM_SEL <= 0;
				RAM_SEL <= 0;
				MBUS_RNW <= 1;
				MBUS_UDS_N <= 1;
				MBUS_LDS_N <= 1;
				
				/*if (rfs_pend) begin
					rfs_pend <= 0;
					mstate <= MBUS_REFRESH;
				end
				else*/ if (!M68K_AS_N && M68K_MBUS_DTACK_N) begin
					// vblank interrupt: the read of vector $78 right after an interrupt
					// acknowledge cycle is redirected (level 6 autovector)
					if (ss_pend & &M68K_FC) SS_DBG_IACK <= 1;
					if (ss_pend & ~(&M68K_FC) & M68K_RNW & {M68K_A[23:2],2'b00} == 24'h000078) SS_DBG_VEC <= 1;
					// the 68000 stacks PC/SR between the acknowledge and the vector fetch,
					// so only reads end the window
					if (&M68K_FC) ss_iack <= 1;
					else if (M68K_RNW) begin
						ss_iack <= 0;
						if (ss_iack && {M68K_A[23:2],2'b00} == 24'h000078 && ~M68K_A[1]) begin
							if (ss_act & ~ss_closing) begin
								ss_vec <= 1;
								ss_vec_tail <= 1;
							end
							else if (ss_pend & ~ss_act) begin
								ss_vec <= 1;
								ss_vec_tail <= 0;
								ss_pend <= 0;
								ss_act <= 1;
							end
						end
					end
					// handler finished: leave the overlay on the first program fetch outside it
					if (ss_closing && M68K_FC[1:0] == 2'b10 && M68K_A[23:16] != 8'h5F) begin
						ss_act <= 0;
						ss_closing <= 0;
					end
					msrc <= MSRC_M68K;
					MBUS_A <= M68K_A[23:1];
					data <= NO_DATA;
					MBUS_DO <= M68K_DO;
					MBUS_RNW <= M68K_RNW;
					mstate <= MBUS_SELECT;
				end
				else if (VBUS_SEL && VDP_MBUS_DTACK_N) begin
					msrc <= MSRC_VDP;
					MBUS_A <= VBUS_A;
					data <= NO_DATA;
					MBUS_DO <= 0;
					mstate <=  MBUS_SELECT;
					//rfs_pend <= 0;
					//refresh_timer <= 0;
				end
				else if (Z80_IO && !Z80_ZBUS && Z80_MBUS_DTACK_N && !Z80_BGACK_N && Z80_BR_N) begin
					msrc <= MSRC_Z80;
					MBUS_A <= Z80_A[15] ? {BAR[23:15],Z80_A[14:1]} : {16'hC000, Z80_A[7:1]};
					data <= 16'hFFFF;
					MBUS_DO <= {Z80_DO,Z80_DO};
					MBUS_RNW <= Z80_WR_N;
					mstate <= MBUS_Z80_PREREAD;
					cycle_cnt <= 2'd1;
				end
			end
			
		MBUS_Z80_PREREAD:
			begin
				if (!cycle_cnt) begin
					mstate <= MBUS_SELECT;
					cycle_cnt <= 2'd1;
				end
			end

		MBUS_SELECT:
			begin
				//NO DEVICE (usually lockup on real HW)
				mstate <= MBUS_FINISH;

				if (MBUS_A[23:20]<'hA || (msrc == MSRC_Z80 && MBUS_A[23:20]<'hE && ROMSZ[24:20]>='hA)) begin
					//ROM: 000000-9FFFFF (A00000-DFFFFF)
					if (ss_vec && msrc == MSRC_M68K && MBUS_RNW && {MBUS_A[23:2],2'b00} == 24'h000078) begin
						// vector 30 (level 6 autovector) -> $5F0000 save / $5F01A0 load / $5F03D0 tail
						data <= MBUS_A[1] ? (ss_vec_tail ? 16'h03D0 : ss_mode_ld ? 16'h01A0 : 16'h0000) : 16'h005F;
						if (MBUS_A[1]) ss_vec <= 0;
						mstate <= MBUS_FINISH;
					end
					else if (ss_act && msrc == MSRC_M68K && MBUS_A[23:16] == 8'h5F) begin
						mstate <= MBUS_SS;
					end
					else if ((MDP_EN | MDP_BUSY) && msrc == MSRC_M68K && {MBUS_A,1'b0} == 24'h3F7FA && ~MBUS_RNW) begin
						// MD+ command window: CD54 opens, anything else closes
						MDP_WIN <= (MBUS_DO == 16'hCD54);
						// MD+ starts by itself after the ROM load; the game is never held
						mstate <= MBUS_FINISH;
					end
					else if ((MDP_EN | MDP_BUSY) && MDP_WIN && msrc == MSRC_M68K && {MBUS_A,1'b0} == 24'h3F7FE && ~MBUS_RNW) begin
						MDP_CMD <= MBUS_DO;
						MDP_CMD_TGL <= ~MDP_CMD_TGL;
						if (MBUS_DO[15:8] == 8'h11 || MBUS_DO[15:8] == 8'h12) mdp_last_play <= MBUS_DO;
						if (MBUS_DO[15:8] == 8'h15) mdp_last_vol <= MBUS_DO;
						mstate <= MBUS_FINISH;
					end
					else if ((MDP_EN | MDP_BUSY) && MDP_WIN && msrc == MSRC_M68K && {MBUS_A,1'b0} == 24'h3F7FC && MBUS_RNW) begin
						data <= {15'd0, MDP_PLAYING};
						mstate <= MBUS_FINISH;
					end
					// SRAM window limited to 200000-2FFFFF so code placed at 300000+
					// (MD+ patches on 4 MB ROMs) stays visible while SRAM is mapped
					else if (BANK_SRAM && MBUS_A[23:20] == 4'h2) begin
						// 200000-3FFFFF SRAM overrides ROM when bank is selected
						SRAM_SEL <= 1;
						mstate <= MBUS_SRAM_READ;
					end
					else if (PIER_QUIRK && ({MBUS_A,1'b0} == 'h0015E6 || {MBUS_A,1'b0} == 'h0015E8)) begin
						if (pier_count < 'h6) begin
							pier_count <= pier_count + 1'h1;
							data <= MBUS_A[1] ? 16'h0 : 16'h0010;
						end else begin
							data <= MBUS_A[1] ? 16'h0001 : 16'h8010;
						end
					end
					else if (EEPROM_QUIRK && {MBUS_A,1'b0} == 'h200000) begin
						data <= 0;
						mstate <= MBUS_FINISH;
					end
					else if ((SRAM_QUIRK | SRAM00_QUIRK) && {MBUS_A,1'b0} == 'h200000) begin
						SRAM_SEL <= 1;
						mstate <= MBUS_SRAM_READ;
					end
					else if(SVP_QUIRK && MBUS_A[23:20] == 3) begin
						// 300000-37FFFF (+mirrors) SVP DRAM
						// 390000-39FFFF SVP DRAM cell arrange 1
						// 3A0000-3AFFFF SVP DRAM cell arrange 2
						SVP_SEL <= 1;
						mstate <= MBUS_SVP_READ;
					end 
					else if (SCHAN_QUIRK && ~MBUS_RNW && (MBUS_A < 'h400000)) begin
						mstate <= MBUS_ROM_WRITE;
					end
					else if (MBUS_A < ROMSZ) begin
						if (SVP_QUIRK && msrc == MSRC_VDP) MBUS_A <= MBUS_A - 1'd1;
						ROM_WE <= 0;
						ROM_REQ <= ~ROM_ACK;
						mstate <= MBUS_ROM_READ;
					end
					else if ((MULTITAP == 4) && ({MBUS_A,1'b0} == 'h3FFFFE || {MBUS_A,1'b0} == 'h38FFFE)) begin
						JCART_SEL <= 1;
						mstate <= MBUS_JCRT_READ;
					end
					else if(MBUS_A[23:21] == 1 && ~&MBUS_A[20:19] && ~NORAM_QUIRK) begin
						// 200000-37FFFF
						SRAM_SEL <= 1;
						mstate <= MBUS_SRAM_READ;
					end
					else begin
						data <= 0;
						mstate <= MBUS_FINISH;
					end
				end

				//ZBUS: A00000-A07FFF (A08000-A0FFFF)
				else if(MBUS_A[23:16] == 'hA0) mstate <= (!Z80_BUSRQ_N | ss_zfree) ? MBUS_ZBUS_PRE : MBUS_FINISH;

				//I/O: A10000-A1001F (+mirrors)
				else if(MBUS_A[23:5] == {16'hA100, 3'b000}) begin
					IO_SEL <= 1;
					mstate <= MBUS_IO_READ;
				end

				//CTL: A11100, A11200
				else if(MBUS_A[23:12] == 12'hA11 && !MBUS_A[7:1]) begin
					CTRL_SEL <= 1;
					data <= CTRL_DO;
					mstate <= MBUS_FINISH;
				end

				// BANK Register A13XXX
				else if (MBUS_A[23:8] == 'hA130) begin
					if (~MBUS_RNW) begin
						if (ROMSZ > 'h200000) begin // SSF2/Pier Solar ROM banking
							if (MBUS_A[3:1]) begin
								BANK_ROM <= 1;
								if (~PIER_QUIRK) begin // SSF2
									BANK_REG[MBUS_A[3:1]] <= MBUS_DO[4:0];
								end
								else if (MBUS_A[3:1] == 4) begin // Pier EEPROM
									{ep_cs, ep_hold , ep_sck, ep_si} <= MBUS_DO[3:0];
								end
								else if (~MBUS_A[3]) begin // Pier Banks
									BANK_REG[{1'b1,MBUS_A[2:1]}] <= MBUS_DO[3:0];
								end
							end
							else if (~PIER_QUIRK) begin // SRAM control only in the first register on SSF2 mapper
							   BANK_SRAM <= {MBUS_DO[0]};
							end
						end else begin
							BANK_SRAM <= {MBUS_DO[0]};
						end
					end else if (PIER_QUIRK && MBUS_A[3:1] == 'h5) begin
						data <= {15'h7FFF, m95_so};
					end
					mstate <= MBUS_FINISH;
				end
				
				//SVP: A15000-A5000F 
				else if(MBUS_A[23:4] == 20'hA1500) begin
					SVP_SEL <= 1;
					mstate <= MBUS_SVP_READ;
				end 

				//VDP: C00000-C0001F (+mirrors)
				else if(MBUS_A[23:21] == 3'b110 && !MBUS_A[18:16] && !MBUS_A[7:5]) begin
					VDP_SEL <= 1;
					mstate <= MBUS_VDP_READ;
				end

				//RAM: E00000-FFFFFF
				else if(&MBUS_A[23:21]) begin
					RAM_SEL <= 1;
					mstate <= MBUS_RAM_READ;
				end
			end
			
		MBUS_ZBUS_PRE:
			case(msrc)
			MSRC_M68K:
				if(M68K_AS_N | (~M68K_UDS_N | ~M68K_LDS_N)) begin
					MBUS_UDS_N <= M68K_UDS_N;
					MBUS_LDS_N <= M68K_LDS_N;
					ZBUS_SEL <= 1;
					mstate <= MBUS_RNW ? MBUS_ZBUS_WS : MBUS_ZBUS_READ;
				end

			MSRC_Z80:
				begin
					MBUS_UDS_N <= Z80_A[0];
					MBUS_LDS_N <= ~Z80_A[0];
					ZBUS_SEL <= 1;
					mstate <= MBUS_ZBUS_READ;
				end

			MSRC_VDP:
				begin
					MBUS_UDS_N <= 0;
					MBUS_LDS_N <= 0;
					ZBUS_SEL <= 1;
					mstate <= MBUS_ZBUS_READ;
				end
			endcase

		MBUS_ZBUS_WS:
			begin
				if (M68K_CLKENp) begin
					mstate <= MBUS_ZBUS_READ;
				end
			end
			
		MBUS_ZBUS_READ:
			begin
				if(~MBUS_ZBUS_DTACK_N) begin
					ZBUS_SEL <= 0;
					data <= {MBUS_ZBUS_D, MBUS_ZBUS_D};
					mstate <= MBUS_FINISH;
				end
			end

		MBUS_RAM_READ:
			begin
				data <= ram68k_q;
				if(msrc == MSRC_M68K) NO_DATA <= ram68k_q;
				mstate <= MBUS_FINISH;
			end

		MBUS_ROM_WRITE:
			case(msrc)
			MSRC_M68K:
				if(M68K_AS_N | (~M68K_UDS_N | ~M68K_LDS_N)) begin
					MBUS_UDS_N <= M68K_UDS_N;
					MBUS_LDS_N <= M68K_LDS_N;
					ROM_WE <= 1;
					ROM_REQ <= ~ROM_ACK;
					mstate <= MBUS_ROM_READ;
				end

			MSRC_Z80:
				begin
					MBUS_UDS_N <= Z80_A[0];
					MBUS_LDS_N <= ~Z80_A[0];
					ROM_WE <= 1;
					ROM_REQ <= ~ROM_ACK;
					mstate <= MBUS_ROM_READ;
				end
			endcase

		MBUS_ROM_READ:
			if (ROM_REQ == ROM_ACK) begin
				data <= ROM_DATA;
				if(msrc == MSRC_M68K) NO_DATA <= ROM_DATA;
				if (msrc != MSRC_Z80 || !cycle_cnt)
					mstate <= MBUS_FINISH;
			end

		MBUS_SRAM_READ:
			begin
				data <= {sram_q,sram_q};
				if(msrc == MSRC_M68K) NO_DATA <= {sram_q,sram_q};
				SRAM_SEL <= 0;
				mstate <= MBUS_FINISH;
			end

		MBUS_VDP_READ:
			if (~VDP_DTACK_N) begin
				VDP_SEL <= 0;
				data <= VDP_DO;
				if(MBUS_A[4:2] == 1) data[15:10] <= NO_DATA[15:10]; //unused status bits
				else if(MBUS_A[4]) data <= NO_DATA; // PSG/debug registers
				mstate <= MBUS_FINISH;
			end

		MBUS_IO_READ:
			if(~IO_DTACK_N) begin
				IO_SEL <= 0;
				data <= {IO_DO, IO_DO};
				mstate <= MBUS_FINISH;
			end

		MBUS_JCRT_READ:
			if(~JCART_DTACK_N) begin
				JCART_SEL <= 0;
				data <= JCART_DO & 16'h3F7F;
				mstate <= MBUS_FINISH;
			end

		MBUS_SVP_READ:
			if(~SVP_DTACK_N) begin
				SVP_SEL <= 0;
				data <= SVP_DO;
				mstate <= MBUS_FINISH;
			end 

		MBUS_REFRESH:
			if (M68K_CLKENp) begin
				rfs_wait <= rfs_wait + 1'd1;
				if (rfs_wait == 1) begin
					rfs_wait <= 0;
					mstate <= MBUS_IDLE;
				end
			end

		// save state overlay $5F0000-$5FFFFF (only while the handler runs)
		MBUS_SS:
			begin
				mstate <= MBUS_FINISH;
				if (~MBUS_A[15]) begin
					// 5F0000-5F7FFF handler code (registered ROM)
					mstate <= MBUS_SS_ROM;
				end
				else if (MBUS_A[15:12] == 4'hE) begin
					// 5FE000-5FEFFF stream: one word per access, pointer increments
					SS_SWE <= ~MBUS_RNW;
					SS_SADDR <= ss_ptr;
					SS_SWD <= MBUS_DO;
					SS_SREQ_TGL <= ~SS_SREQ_TGL;
					mstate <= MBUS_SS_WAIT;
				end
				else if (MBUS_A[15:12] == 4'hF) begin
					if (MBUS_A[11:8] == 4'h0) begin
						case (MBUS_A[7:1])
						7'h01: if (~MBUS_RNW) ss_ptr <= 0;
						7'h03: if (~MBUS_RNW) ss_zfrz_req <= MBUS_DO[0]; else data <= {15'd0, ss_zfrozen};
						7'h04: if (~MBUS_RNW) ss_apply_req <= 1; else data <= {15'd0, ss_apply_busy};
						7'h05: if (~MBUS_RNW) begin ss_closing <= 1; SS_DONE_TGL <= ~SS_DONE_TGL; end
						7'h06: if (~MBUS_RNW) ss_ptr <= {1'b0, MBUS_DO};
						7'h07: if (~MBUS_RNW) SS_PROG_TGL <= ~SS_PROG_TGL;
						default: ;
						endcase
					end
					else if (MBUS_A[11:8] == 4'h1) begin
						// 5FF100-5FF1FF info block
						if (MBUS_RNW) data <= ss_info_q;
						else begin
							ss_iw <= 1;
							ss_iw_idx <= MBUS_A[7:1];
							ss_iw_d <= MBUS_DO;
							case (MBUS_A[7:1])
							7'd1:  ss_zst_ld <= MBUS_DO[3:0];
							7'd16: ss_bar_we <= 1;
							7'd17: {BANK_ROM, BANK_SRAM} <= MBUS_DO[1:0];
							7'd18: begin BANK_REG[0] <= MBUS_DO[4:0]; BANK_REG[1] <= MBUS_DO[12:8]; end
							7'd19: begin BANK_REG[2] <= MBUS_DO[4:0]; BANK_REG[3] <= MBUS_DO[12:8]; end
							7'd20: begin BANK_REG[4] <= MBUS_DO[4:0]; BANK_REG[5] <= MBUS_DO[12:8]; end
							7'd21: begin BANK_REG[6] <= MBUS_DO[4:0]; BANK_REG[7] <= MBUS_DO[12:8]; end
							7'd22: mdp_ld_play <= MBUS_DO;
							7'd23: mdp_ld_playing <= MBUS_DO[0];
							7'd24: mdp_ld_vol <= MBUS_DO;
							7'd27: mdp_ld_snap <= MBUS_DO;
							7'd28: SS_SEEK_POS[31:16] <= MBUS_DO;
							7'd29: SS_SEEK_POS[15:0] <= MBUS_DO;
							default: if (MBUS_A[7:1] >= 7'd2 && MBUS_A[7:1] <= 7'd15) ss_dir_ld[(MBUS_A[7:1] - 7'd2)*16 +: 16] <= MBUS_DO;
							endcase
						end
					end
					else if (MBUS_A[11:10] == 2'b01) begin
						// 5FF400-5FF7FF YM2612 register shadow (512 bytes)
						if (MBUS_RNW) mstate <= MBUS_SS_ROM;
						else begin
							ss_fw <= 1;
							ss_fw_idx <= MBUS_A[8:1];
							ss_fw_d <= MBUS_DO;
						end
					end
				end
			end

		MBUS_SS_ROM:
			mstate <= MBUS_SS_ROM2;

		MBUS_SS_ROM2:
			begin
				data <= MBUS_A[15] ? fmsh_q : hrom_q;
				mstate <= MBUS_FINISH;
			end

		MBUS_SS_WAIT:
			if (ss_ack_s[2] == SS_SREQ_TGL) begin
				data <= SS_SRD;
				ss_ptr <= ss_ptr + 1'd1;
				mstate <= MBUS_FINISH;
			end

		MBUS_MDP_WAIT:
			begin
				// wait for MD+ to finish booting (or give up)
				if (mdp_wait_cnt != 4'hF) mdp_wait_cnt <= mdp_wait_cnt + 1'd1;
				else if (~MDP_BUSY) mstate <= MBUS_FINISH;
			end

		MBUS_FINISH:
			begin
				case(msrc)
				MSRC_M68K:
					begin
						M68K_MBUS_D <= data;
						M68K_MBUS_DTACK_N <= 0;
						if((M68K_AS_N | MBUS_RNW | ~M68K_UDS_N | ~M68K_LDS_N)) begin
							MBUS_UDS_N <= M68K_UDS_N;
							MBUS_LDS_N <= M68K_LDS_N;
							mstate <= MBUS_IDLE;
						end
					end

				MSRC_Z80:
					begin
						if (Z80_CLKENp) begin
							Z80_MBUS_D <= Z80_A[0] ? data[7:0] : data[15:8];
							Z80_MBUS_DTACK_N <= 0;
							MBUS_UDS_N <= Z80_A[0];
							MBUS_LDS_N <= ~Z80_A[0];
							mstate <= MBUS_IDLE;
						end
					end

				MSRC_VDP:
					begin
						VDP_MBUS_D <= data;
						VDP_MBUS_DTACK_N <= 0;
						mstate <= MBUS_IDLE;
					end
				endcase
			end
		endcase
	end
end


//--------------------------------------------------------------
// CPU Z80
//--------------------------------------------------------------
reg         Z80_RESET_N;
reg         Z80_BUSRQ_N;
wire        Z80_BUSAK_N;
wire        Z80_MREQ_N;
wire        Z80_RD_N;
wire        Z80_WR_N;
wire [15:0] Z80_A;
wire  [7:0] Z80_DO;
wire        Z80_IO = ~Z80_MREQ_N & (~Z80_RD_N | ~Z80_WR_N);

T80s #(.T2Write(1)) Z80
//T80pa Z80
(
	.RESET_n(Z80_RESET_N),
	.CLK(MCLK),
//	.CEN_p(Z80_CLKENp),
//	.CEN_n(Z80_CLKENn),
	.CEN(Z80_CLKENn & ~ss_zfrozen),
	.BUSRQ_n(Z80_BUSRQ_N),
	.M1_n(Z80_M1_N),
	.HALT_n(Z80_HALT_N),
	.REG(Z80_REG),
	.DIRSet(ss_dirset),
	.DIR(ss_dir),
	.BUSAK_n(Z80_BUSAK_N),
	.WAIT_n(~Z80_MBUS_DTACK_N | ~Z80_ZBUS_DTACK_N | ~Z80_IO),
	.INT_n(~Z80_VINT),
	.MREQ_n(Z80_MREQ_N),
	.RD_n(Z80_RD_N),
	.WR_n(Z80_WR_N),
	.A(Z80_A),
	.DI((~Z80_MBUS_DTACK_N) ? Z80_MBUS_D : Z80_ZBUS_D),
	.DO(Z80_DO)
);


wire        CTRL_F  = (MBUS_A[11:8] == 1) ? Z80_BUSAK_N : (MBUS_A[11:8] == 2) ? Z80_RESET_N : NO_DATA[8];
wire [15:0] CTRL_DO = {NO_DATA[15:9], CTRL_F, NO_DATA[7:0]};
reg         CTRL_SEL;
always @(posedge MCLK) begin
	if (reset) begin
		Z80_BUSRQ_N <= 1;
		Z80_RESET_N <= 0;
	end
	else if (ss_zctl_we) begin
		Z80_RESET_N <= ss_zst_ld[0];
		Z80_BUSRQ_N <= ss_zst_ld[1];
	end
	else if(CTRL_SEL & ~MBUS_RNW & ~MBUS_UDS_N) begin
		if (MBUS_A[11:8] == 1) Z80_BUSRQ_N <= ~MBUS_DO[8];
		if (MBUS_A[11:8] == 2) Z80_RESET_N <=  MBUS_DO[8];
	end
end

//-----------------------------------------------------------------------
// ZBUS Handling
//-----------------------------------------------------------------------
// Z80:   0000-7EFF
// 68000: A00000-A07FFF (A08000-A0FFFF)

wire       Z80_ZBUS  = ~Z80_A[15] && ~&Z80_A[14:8];

wire       ZBUS_NO_BUSY = ZBUS_A[14] && ~|ZBUS_A[13:2] && |ZBUS_A[1:0] && FMBUSY_QUIRK;

reg        ZBUS_SEL;
reg [14:0] ZBUS_A;
reg        ZBUS_WE;
reg  [7:0] ZBUS_DO;
wire [7:0] ZBUS_DI = ZRAM_SEL ? ZRAM_DO : (FM_SEL ? (ZBUS_NO_BUSY ? {1'b0, FM_DO[6:0]} : FM_DO) : 8'hFF);

reg  [7:0] MBUS_ZBUS_D;
reg  [7:0] Z80_ZBUS_D;

reg        MBUS_ZBUS_DTACK_N;
reg        Z80_ZBUS_DTACK_N;

reg        Z80_BR_N;
reg        Z80_BGACK_N;

wire       Z80_ZBUS_SEL = Z80_ZBUS & Z80_IO;
wire       ZBUS_FREE = (~Z80_BUSRQ_N & Z80_RESET_N) | ss_zfree;

wire       Z80_MBUS_SEL = Z80_IO & ~Z80_ZBUS;

// RAM 0000-1FFF (2000-3FFF)
wire ZRAM_SEL = ~ZBUS_A[14];

wire  [7:0] ZRAM_DO;
dpram #(13) ramZ80
(
	.clock(MCLK),
	.address_a(ZBUS_A[12:0]),
	.data_a(ZBUS_DO),
	.wren_a(ZBUS_WE & ZRAM_SEL),
	.q_a(ZRAM_DO)
);

always @(posedge MCLK) begin
	reg [1:0] zstate;
	reg [1:0] zsrc;
	reg Z80_BGACK_DIS;

	localparam 	ZSRC_MBUS = 0,
					ZSRC_Z80  = 1;

	localparam	ZBUS_IDLE   = 0,
					ZBUS_READ   = 1,
					ZBUS_FINISH = 2;

	ZBUS_WE <= 0;
	
	if (reset) begin
		MBUS_ZBUS_DTACK_N <= 1;
		Z80_ZBUS_DTACK_N  <= 1;
		zstate <= ZBUS_IDLE;
		
		Z80_BR_N <= 1;
		Z80_BGACK_N <= 1;
		Z80_BGACK_DIS <= 0;
	end
	else begin
		if (~ZBUS_SEL)     MBUS_ZBUS_DTACK_N <= 1;
		if (~Z80_ZBUS_SEL) Z80_ZBUS_DTACK_N  <= 1;

		case (zstate)
		ZBUS_IDLE:
			begin
				if (Z80_RD_N)      Z80_ZBUS_D <= 8'hFF;

				if (ZBUS_SEL & MBUS_ZBUS_DTACK_N) begin
					ZBUS_A <= {MBUS_A[14:1], MBUS_UDS_N};
					ZBUS_DO <= (~MBUS_UDS_N) ? MBUS_DO[15:8] : MBUS_DO[7:0];
					ZBUS_WE <= ~MBUS_RNW & ZBUS_FREE;
					zsrc <= ZSRC_MBUS;
					zstate <= ZBUS_READ;
				end
				else if (Z80_ZBUS_SEL & Z80_ZBUS_DTACK_N) begin
					ZBUS_A <= Z80_A[14:0];
					ZBUS_DO <= Z80_DO;
					ZBUS_WE <= ~Z80_WR_N;
					zsrc <= ZSRC_Z80;
					zstate <= ZBUS_READ;
				end
			end

		ZBUS_READ:
			zstate <= ZBUS_FINISH;

		ZBUS_FINISH:
			begin
				case(zsrc)
				ZSRC_MBUS:
					begin
						MBUS_ZBUS_D <= ZBUS_FREE ? ZBUS_DI : 8'hFF;
						MBUS_ZBUS_DTACK_N <= 0;
					end

				ZSRC_Z80:
					begin
						Z80_ZBUS_D <= ZBUS_DI;
						Z80_ZBUS_DTACK_N <= 0;
					end
				endcase
				zstate <= ZBUS_IDLE;
			end
		endcase
		if (ss_zabort) Z80_ZBUS_DTACK_N <= 1;   // refetch after the Z80 registers were loaded
		
		if (Z80_MBUS_SEL && Z80_BR_N && Z80_BGACK_N && VBUS_BR_N && VBUS_BGACK_N && M68K_CLKENp) begin
			Z80_BR_N <= 0;
		end
		else if (!Z80_BR_N && !M68K_BG_N && M68K_AS_N && M68K_CLKENn) begin
			Z80_BGACK_N <= 0;
		end
		else if (!Z80_BGACK_N && !Z80_BR_N && !M68K_BG_N && M68K_CLKENp) begin
			Z80_BR_N <= 1;
		end
		else if (!Z80_BGACK_DIS && !Z80_BGACK_N && Z80_BR_N && !Z80_MBUS_SEL && M68K_CLKENn) begin
			Z80_BGACK_DIS <= 1;
		end
		else if (!Z80_BGACK_N && Z80_BGACK_DIS && M68K_CLKENn) begin
			Z80_BGACK_N <= 1;
			Z80_BGACK_DIS <= 0;
		end
	end
end


//-----------------------------------------------------------------------
// Z80 BANK REGISTER
//-----------------------------------------------------------------------
// 6000-60FF

wire BANK_SEL = ZBUS_A[14:8] == 7'h60;
reg [23:15] BAR;

always @(posedge MCLK) begin
	if (reset) BAR <= 0;
	else if (ss_bar_we) BAR <= ss_iw_d[8:0];
	else if (BANK_SEL & ZBUS_WE) BAR <= {ZBUS_DO[0], BAR[23:16]};
end


//--------------------------------------------------------------
// YM2612
//--------------------------------------------------------------
// 4000-4003 (4000-5FFF)

wire        FM_SEL = ZBUS_A[14:13] == 2'b10;
wire  [7:0] FM_DO;
wire signed [15:0] FM_right;
wire signed [15:0] FM_left;
wire signed [15:0] FM_LPF_right;
wire signed [15:0] FM_LPF_left;
wire signed [15:0] PRE_LPF_L;
wire signed [15:0] PRE_LPF_R;

jt12 fm
(
	.rst(~Z80_RESET_N),
	.clk(MCLK),
	.cen(FM_CLKEN),

	.cs_n(0),
	.addr(fm_ovr ? fm_a : ZBUS_A[1:0]),
	.wr_n(fm_ovr ? ~fm_we : ~(FM_SEL & ZBUS_WE)),
	.din(fm_ovr ? fm_d : ZBUS_DO),
	.dout(FM_DO),
	.en_hifi_pcm( EN_HIFI_PCM ),
	.ladder(LADDER),
	.snd_left(FM_left),
	.snd_right(FM_right)
);

wire signed [15:0] fm_adjust_l = (FM_left  << 4) + (FM_left  << 2) + (FM_left  << 1) + (FM_left  >>> 2);
wire signed [15:0] fm_adjust_r = (FM_right << 4) + (FM_right << 2) + (FM_right << 1) + (FM_right >>> 2);

genesis_fm_lpf fm_lpf_l
(
	.clk(MCLK),
	.reset(reset),
	.in(fm_adjust_l),
	.out(FM_LPF_left)
);

genesis_fm_lpf fm_lpf_r
(
	.clk(MCLK),
	.reset(reset),
	.in(fm_adjust_r),
	.out(FM_LPF_right)
);

wire signed [15:0] fm_select_l = ((LPF_MODE == 2'b01) ? FM_LPF_left : fm_adjust_l);
wire signed [15:0] fm_select_r = ((LPF_MODE == 2'b01) ? FM_LPF_right : fm_adjust_r);

wire signed [10:0] psg_adjust = PSG_SND - (PSG_SND >>> 5);

jt12_genmix genmix
(
	.rst(reset),
	.clk(MCLK),
	.fm_left(fm_select_l),
	.fm_right(fm_select_r),
	.psg_snd(psg_adjust),
	.fm_en(ENABLE_FM),
	.psg_en(ENABLE_PSG),
	.snd_left(PRE_LPF_L),
	.snd_right(PRE_LPF_R)
);

genesis_lpf lpf_right
(
	.clk(MCLK),
	.reset(reset),
	.lpf_mode(LPF_MODE[1:0]),
	.in(PRE_LPF_R),
	.out(DAC_RDATA)
);

genesis_lpf lpf_left
(
	.clk(MCLK),
	.reset(reset),
	.lpf_mode(LPF_MODE[1:0]),
	.in(PRE_LPF_L),
	.out(DAC_LDATA)
);


//--------------------------------------------------------------
// SAVE STATES - shadows, Z80 freeze, apply
//--------------------------------------------------------------

ss_hrom ss_hrom_i
(
	.clk(MCLK),
	.addr(MBUS_A[9:1]),
	.q(hrom_q)
);

// ---- Z80: stop on an instruction boundary (start of an M1 cycle) ----
reg        z80_old_m1 = 1;
reg  [6:0] z80_vint_q = 0;
reg [15:0] zf_tmo = 0;
always @(posedge MCLK) begin
	z80_old_m1 <= Z80_M1_N;
	if (Z80_VINT) z80_vint_q <= 0;
	else if (~&z80_vint_q) z80_vint_q <= z80_vint_q + 1'd1;

	if (reset | ~ss_zfrz_req) begin
		ss_zfrozen <= 0;
		zf_tmo <= 0;
	end
	else if (~ss_zfrozen) begin
		zf_tmo <= zf_tmo + 1'd1;
		if (~Z80_RESET_N | ~Z80_BUSRQ_N | ~Z80_BUSAK_N | &zf_tmo) begin
			ss_zfrozen <= 1;
			ss_at_m1 <= 0;
			ss_halted <= ~Z80_HALT_N;
		end
		// M1 just started and no interrupt can be in acknowledge (INT low for a while)
		else if (z80_old_m1 & ~Z80_M1_N & (&z80_vint_q)) begin
			ss_zfrozen <= 1;
			ss_at_m1 <= 1;
			ss_halted <= ~Z80_HALT_N;
		end
	end
end


// frequency MSB registers (A4-A6, AC-AE) are latched and take effect on the LSB write,
// so they are replayed first: A4..A7, A0..A3, AC..AF, A8..AB
wire [7:0] ap_r = (ap_reg[7:4] == 4'hA) ? (ap_reg[7:0] ^ 8'h04) : ap_reg[7:0];

// ---- YM2612 register shadow (512 x 8, two byte lanes) and key on state ----
reg        fm_part_l = 0;
reg  [7:0] fm_addr_l = 0;
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] fmsh_e [0:255];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] fmsh_o [0:255];
reg  [7:0] fmsh_qe, fmsh_qo;
reg  [3:0] fm_key [0:7];
wire       fm_tap   = FM_SEL & ZBUS_WE;
wire       fm_tap_d = fm_tap & ZBUS_A[0];
wire       fe_we = fm_tap_d ? ~fm_addr_l[0] : ss_fw;
wire       fo_we = fm_tap_d ?  fm_addr_l[0] : ss_fw;
wire [7:0] fw_a  = fm_tap_d ? {fm_part_l, fm_addr_l[7:1]} : ss_fw_idx;
wire [7:0] fe_d  = fm_tap_d ? ZBUS_DO : ss_fw_d[15:8];
wire [7:0] fo_d  = fm_tap_d ? ZBUS_DO : ss_fw_d[7:0];
wire [7:0] fr_a  = fm_ovr ? {ap_reg[8], ap_r[7:1]} : MBUS_A[8:1];
always @(posedge MCLK) begin
	if (fe_we) fmsh_e[fw_a] <= fe_d;
	if (fo_we) fmsh_o[fw_a] <= fo_d;
	fmsh_qe <= fmsh_e[fr_a];
	fmsh_qo <= fmsh_o[fr_a];

	if (fm_tap & ~ZBUS_A[0]) begin
		fm_part_l <= ZBUS_A[1];
		fm_addr_l <= ZBUS_DO;
	end
	if (fm_tap_d && ~fm_part_l && fm_addr_l == 8'h28) fm_key[ZBUS_DO[2:0]] <= ZBUS_DO[7:4];
	if (ss_iw && ss_iw_idx == 7'd25) begin
		fm_key[0] <= ss_iw_d[3:0];  fm_key[1] <= ss_iw_d[7:4];
		fm_key[2] <= ss_iw_d[11:8]; fm_key[3] <= ss_iw_d[15:12];
	end
	if (ss_iw && ss_iw_idx == 7'd26) begin
		fm_key[4] <= ss_iw_d[3:0];  fm_key[5] <= ss_iw_d[7:4];
		fm_key[6] <= ss_iw_d[11:8]; fm_key[7] <= ss_iw_d[15:12];
	end
end
assign fmsh_q = {fmsh_qe, fmsh_qo};

// ---- VDP register and PSG shadows (snooped from bus writes) ----
reg        vsel_q = 0;
reg        vpend = 0;
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] vdp_sh [0:31];
reg  [9:0] psg_t [0:2];
reg  [3:0] psg_v [0:3];
reg  [2:0] psg_n = 0;
reg  [2:0] psg_l = 0;
wire [7:0] psg_d = MBUS_DO[15:8];
always @(posedge MCLK) begin
	vsel_q <= VDP_SEL;
	if (reset) vpend <= 0;
	else if (VDP_SEL & ~vsel_q) begin
		if (MBUS_A[4:2] == 3'b001) begin
			if (MBUS_RNW) vpend <= 0;
			else if (vpend) vpend <= 0;
			else if (MBUS_DO[15:14] == 2'b10) begin
				if (MBUS_DO[12:8] < 5'd24) vdp_sh[MBUS_DO[12:8]] <= MBUS_DO[7:0];
			end
			else vpend <= 1;
		end
		else if (MBUS_A[4:2] == 3'b000) vpend <= 0;
		else if (MBUS_A[4] & ~MBUS_A[3] & ~MBUS_RNW) begin
			if (psg_d[7]) begin
				psg_l <= psg_d[6:4];
				case (psg_d[6:4])
				3'd0: psg_t[0][3:0] <= psg_d[3:0];
				3'd2: psg_t[1][3:0] <= psg_d[3:0];
				3'd4: psg_t[2][3:0] <= psg_d[3:0];
				3'd6: psg_n <= psg_d[2:0];
				default: psg_v[psg_d[6:5]] <= psg_d[3:0];
				endcase
			end
			else begin
				case (psg_l)
				3'd0: psg_t[0][9:4] <= psg_d[5:0];
				3'd2: psg_t[1][9:4] <= psg_d[5:0];
				3'd4: psg_t[2][9:4] <= psg_d[5:0];
				3'd6: psg_n <= psg_d[2:0];
				default: psg_v[psg_l[2:1]] <= psg_d[3:0];
				endcase
			end
		end
	end
end

// ---- info block seen by the handler at $5FF100 ----
wire [223:0] z80_reg_w = {12'd0, Z80_REG};
wire [6:0]   ii = MBUS_A[7:1];
wire [6:0]   iv = ii - 7'd32;
wire [6:0]   ip = ii - 7'd56;
always @(*) begin
	ss_info_q = 16'd0;
	if (ii == 7'd0) ss_info_q = 16'h4D53;
	else if (ii == 7'd1) ss_info_q = {12'd0, ss_halted, ss_at_m1, Z80_BUSRQ_N, Z80_RESET_N};
	else if (ii <= 7'd15) ss_info_q = z80_reg_w[(ii - 7'd2)*16 +: 16];
	else if (ii == 7'd16) ss_info_q = {7'd0, BAR};
	else if (ii == 7'd17) ss_info_q = {14'd0, BANK_ROM, BANK_SRAM};
	else if (ii == 7'd18) ss_info_q = {3'd0, BANK_REG[1], 3'd0, BANK_REG[0]};
	else if (ii == 7'd19) ss_info_q = {3'd0, BANK_REG[3], 3'd0, BANK_REG[2]};
	else if (ii == 7'd20) ss_info_q = {3'd0, BANK_REG[5], 3'd0, BANK_REG[4]};
	else if (ii == 7'd21) ss_info_q = {3'd0, BANK_REG[7], 3'd0, BANK_REG[6]};
	else if (ii == 7'd22) ss_info_q = mdp_last_play;
	else if (ii == 7'd23) ss_info_q = {15'd0, MDP_PLAYING};
	else if (ii == 7'd24) ss_info_q = mdp_last_vol;
	else if (ii == 7'd25) ss_info_q = {fm_key[3], fm_key[2], fm_key[1], fm_key[0]};
	else if (ii == 7'd26) ss_info_q = {fm_key[7], fm_key[6], fm_key[5], fm_key[4]};
	else if (ii == 7'd27) ss_info_q = {SS_MDP_ON, SS_MDP_LOOP, 7'd0, SS_MDP_TRK};
	else if (ii == 7'd28) ss_info_q = SS_MDP_POS[31:16];
	else if (ii == 7'd29) ss_info_q = SS_MDP_POS[15:0];
	else if (ii >= 7'd32 && ii < 7'd56) ss_info_q = {3'b100, iv[4:0], vdp_sh[iv[4:0]]};
	else if (ii >= 7'd56 && ii < 7'd72) begin
		// PSG restore sequence, one byte per word (high byte) for writes to $C00011
		case (ip[3:0])
		4'd0:  ss_info_q = {1'b1, 2'd0, 1'b0, psg_t[0][3:0], 8'd0};
		4'd1:  ss_info_q = {2'b00, psg_t[0][9:4], 8'd0};
		4'd4:  ss_info_q = {1'b1, 2'd1, 1'b0, psg_t[1][3:0], 8'd0};
		4'd5:  ss_info_q = {2'b00, psg_t[1][9:4], 8'd0};
		4'd8:  ss_info_q = {1'b1, 2'd2, 1'b0, psg_t[2][3:0], 8'd0};
		4'd9:  ss_info_q = {2'b00, psg_t[2][9:4], 8'd0};
		4'd12, 4'd13: ss_info_q = {1'b1, 2'd3, 1'b0, 1'b0, psg_n, 8'd0};
		default: ss_info_q = {1'b1, ip[3:2], 1'b1, psg_v[ip[3:2]], 8'd0};
		endcase
	end
end

// ---- apply: Z80 registers, YM2612 registers, MD+ track ----
localparam AP_IDLE = 0, AP_ZW = 1, AP_DIR = 2, AP_DW = 3, AP_FM = 4, AP_FMR = 5, AP_FMA = 6,
           AP_FMD = 7, AP_FMW = 8, AP_KEY = 9, AP_KEYA = 10, AP_KEYD = 11, AP_KEYW = 12,
           AP_MDP = 13, AP_MDPW = 14, AP_VOL = 15, AP_END = 16;
reg  [4:0] ap_st = AP_IDLE;
reg [28:0] ap_cnt = 0;
reg  [2:0] ap_ch = 0;
wire       ap_part = ap_reg[8];
wire       ap_valid = ap_part ? (ap_r >= 8'h30 && ap_r <= 8'hB6)
                              : (ap_r >= 8'h21 && ap_r <= 8'hB6 && ap_r != 8'h28);
always @(posedge MCLK) begin
	ss_zctl_we <= 0;
	ss_dirset <= 0;
	ss_zabort <= 0;
	fm_we <= 0;
	ss_mdp_cmd_req <= 0;
	ss_mdp_trig_req <= 0;
	ap_cnt <= ap_cnt + 1'd1;

	if (reset) begin
		ap_st <= AP_IDLE;
		ss_apply_busy <= 0;
		fm_ovr <= 0;
	end
	else case (ap_st)
	AP_IDLE:
		if (ss_apply_req) begin
			ss_apply_busy <= 1;
			ss_zctl_we <= 1;
			ap_cnt <= 0;
			ap_st <= AP_ZW;
		end
	AP_ZW:
		if (ap_cnt[6]) ap_st <= AP_DIR;
	AP_DIR:
		begin
			ss_dirset <= 1;
			ss_zabort <= 1;
			ap_cnt <= 0;
			ap_st <= AP_DW;
		end
	AP_DW:
		if (ap_cnt[4]) begin
			fm_ovr <= 1;
			ap_reg <= 0;
			ap_st <= AP_FM;
		end
	AP_FM:
		if (ap_valid) begin
			ap_cnt <= 0;
			ap_st <= AP_FMR;
		end
		else if (&ap_reg) begin
			ap_ch <= 0;
			ap_st <= AP_KEY;
		end
		else ap_reg <= ap_reg + 1'd1;
	AP_FMR:
		if (ap_cnt[2]) begin
			fm_a <= {ap_part, 1'b0};
			fm_d <= ap_r;
			fm_we <= 1;
			ap_cnt <= 0;
			ap_st <= AP_FMA;
		end
	AP_FMA:
		if (ap_cnt[4]) begin
			fm_a <= {ap_part, 1'b1};
			fm_d <= ap_r[0] ? fmsh_qo : fmsh_qe;
			fm_we <= 1;
			ap_cnt <= 0;
			ap_st <= AP_FMW;
		end
	AP_FMW:
		if (ap_cnt[10]) begin
			if (&ap_reg) begin
				ap_ch <= 0;
				ap_st <= AP_KEY;
			end
			else begin
				ap_reg <= ap_reg + 1'd1;
				ap_st <= AP_FM;
			end
		end
	AP_KEY:
		if (ap_ch == 3'd3 || ap_ch == 3'd7) begin
			if (ap_ch == 3'd7) begin
				fm_ovr <= 0;
				ap_cnt <= 0;
				ap_st <= AP_MDP;
			end
			else ap_ch <= ap_ch + 1'd1;
		end
		else begin
			fm_a <= 2'b00;
			fm_d <= 8'h28;
			fm_we <= 1;
			ap_cnt <= 0;
			ap_st <= AP_KEYA;
		end
	AP_KEYA:
		if (ap_cnt[4]) begin
			fm_a <= 2'b01;
			fm_d <= {fm_key[ap_ch], 1'b0, ap_ch};
			fm_we <= 1;
			ap_cnt <= 0;
			ap_st <= AP_KEYW;
		end
	AP_KEYW:
		if (ap_cnt[10]) begin
			ap_ch <= ap_ch + 1'd1;
			ap_st <= AP_KEY;
		end
	AP_MDP:
		begin
			ap_cnt <= 0;
			if (mdp_ld_on) begin
				if (MDP_EN | MDP_BUSY) begin
					// MD+ ready, or still starting: the command is queued until it is ready
					ss_mdp_cmd_val <= mdp_ld_cmd;
					ss_mdp_cmd_req <= 1;
					ap_st <= AP_VOL;
				end
				else ap_st <= AP_END;
			end
			else begin
				if (MDP_EN) begin
					ss_mdp_cmd_val <= 16'h1300;
					ss_mdp_cmd_req <= 1;
				end
				ap_st <= AP_END;
			end
		end
	AP_MDPW:
		if (MDP_EN && ap_cnt[12]) begin
			ss_mdp_cmd_val <= mdp_ld_cmd;
			ss_mdp_cmd_req <= 1;
			ap_cnt <= 0;
			ap_st <= AP_VOL;
		end
		else if (ap_cnt[28]) ap_st <= AP_END;
	AP_VOL:
		if (ap_cnt[12]) begin
			if (mdp_ld_vol[15:8] == 8'h15) begin
				ss_mdp_cmd_val <= mdp_ld_vol;
				ss_mdp_cmd_req <= 1;
			end
			ap_st <= AP_END;
		end
	AP_END:
		begin
			fm_ovr <= 0;
			ss_apply_busy <= 0;
			ap_st <= AP_IDLE;
		end
	default: ap_st <= AP_IDLE;
	endcase
end

endmodule
