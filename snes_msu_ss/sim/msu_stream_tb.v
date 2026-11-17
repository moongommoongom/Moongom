// MSU-1 stream test: music + voice msu_scache, msu_pr_arb, the real psram.sv controller with a behavioural PSRAM,
// a single SD command channel (bridge) paced like pcm data_loader, and two 44.1 kHz stereo players.
// Reports bridge retries (chunk re-reads after a write queue overflow), player underruns and data errors.
//
//   cd snes_msu_ss/sim
//   iverilog -g2012 -DBPERIOD=22 -o msu_stream msu_stream_tb.v ../rtl/upstream/chip/MSU1/msu_scache.v \
//       ../rtl/upstream/chip/MSU1/msu_pr_arb.v ../target/pocket/psram.sv && vvp msu_stream | grep BPERIOD
//
// BPERIOD = clk_sys cycles per 32-bit bridge write (22 ~ 4 MB/s as measured for the firmware, 16 ~ 5.4 MB/s,
// 14 = 6.1 MB/s, the pcm data_loader's maximum).
`timescale 1ps/1ps
`ifndef SC
 `define SC msu_scache
`endif
`ifndef NAME
 `define NAME "msu_scache"
`endif
`ifndef LAT
 `define LAT 2000         // clk_sys cycles of command latency per bridge read
`endif
`ifndef VSTART
 `define VSTART 10000000000   // ps: voice clip starts 10 ms after the music track
`endif
`ifndef TEND
 `define TEND 190000000000    // ps: run ~200 ms
`endif
`ifndef BPERIOD
 `define BPERIOD 22      // clk_sys cycles per 32-bit bridge write (22 ~ 1.0 us ~ 4 MB/s)
`endif
module tb;
  reg clk_sys=0, clk_mem=0;
  always #23280 clk_sys=~clk_sys;
  always #5820  clk_mem=~clk_mem;
  reg reset=1;

  // ---------------- caches ----------------
  reg m_mnt=0, v_mnt=0;
  reg [31:0] m_size=32'd8388608, v_size=32'd614400;
  reg  m_af=0, v_af=0; reg [31:0] m_aoff=0, v_aoff=0; reg [15:0] m_alen=0, v_alen=0;
  wire m_ad, m_ae, m_pw, v_ad, v_ae, v_pw; wire [15:0] m_pd, v_pd;
  wire m_bf, v_bf; wire [31:0] m_boff, m_blen, v_boff, v_blen;
  reg  m_bd=0, v_bd=0; reg m_bw=0, v_bw=0; reg [15:0] m_bdat=0, v_bdat=0;
  wire mp_req, mp_we, mp_done, vp_req, vp_we, vp_done; wire [21:0] mp_addr, vp_addr; wire [15:0] mp_wd, vp_wd, mp_rd, vp_rd;
  wire mp_two, vp_two; wire [15:0] mp_wd2, vp_wd2;

  `SC #(.PS_BASE(22'h100000), .FIXED(1), .OW(22), .RING_LOG2(21), .FIRST_BYTES(32'd65536), .CHUNK_BYTES(32'd131072)) vc (
    .clk(clk_sys),.reset(reset),.mounting(v_mnt),.missing(1'b0),.size(v_size),
    .a_fetch_tgl(v_af),.a_off(v_aoff),.a_len(v_alen),.a_done_tgl(v_ad),.a_err(v_ae),.a_pcm_wr(v_pw),.a_pcm_data(v_pd),
    .b_fetch_tgl(v_bf),.b_off(v_boff),.b_len(v_blen),.b_done_tgl(v_bd),.b_err(1'b0),.b_pcm_wr(v_bw),.b_pcm_data(v_bdat),
    .pr_req(vp_req),.pr_we(vp_we),.pr_addr(vp_addr),.pr_wdata(vp_wd),.pr_two(vp_two),.pr_wdata2(vp_wd2),.pr_done(vp_done),.pr_rdata(vp_rd));
  `SC #(.PS_BASE(22'h200000), .RING_LOG2(22), .FIRST_BYTES(32'd262144), .CHUNK_BYTES(32'd262144)) mc (
    .clk(clk_sys),.reset(reset),.mounting(m_mnt),.missing(1'b0),.size(m_size),
    .a_fetch_tgl(m_af),.a_off(m_aoff),.a_len(m_alen),.a_done_tgl(m_ad),.a_err(m_ae),.a_pcm_wr(m_pw),.a_pcm_data(m_pd),
    .b_fetch_tgl(m_bf),.b_off(m_boff),.b_len(m_blen),.b_done_tgl(m_bd),.b_err(1'b0),.b_pcm_wr(m_bw),.b_pcm_data(m_bdat),
    .pr_req(mp_req),.pr_we(mp_we),.pr_addr(mp_addr),.pr_wdata(mp_wd),.pr_two(mp_two),.pr_wdata2(mp_wd2),.pr_done(mp_done),.pr_rdata(mp_rd));

  wire tgl, we, two; wire [21:0] a; wire [15:0] wd, wd2, rd; wire ack;
  msu_pr_arb arb(.clk(clk_sys),.reset(reset),
    .c0_req(mp_req),.c0_we(mp_we),.c0_addr(mp_addr),.c0_wd(mp_wd),.c0_two(mp_two),.c0_wd2(mp_wd2),.c0_done(mp_done),.c0_rd(mp_rd),
    .c1_req(vp_req),.c1_we(vp_we),.c1_addr(vp_addr),.c1_wd(vp_wd),.c1_two(vp_two),.c1_wd2(vp_wd2),.c1_done(vp_done),.c1_rd(vp_rd),
    .pr_req_tgl(tgl),.pr_we(we),.pr_addr(a),.pr_wdata(wd),.pr_two(two),.pr_wdata2(wd2),.pr_ack_tgl(ack),.pr_rdata(rd));

  // ---------------- PSRAM: real controller timing + behavioural chip ----------------
  wire [15:0] dq; wire [21:16] ca; wire adv_n, ce0_n, oe_n, we_n;
  psram #(.CLOCK_SPEED(85.9)) ram(.clk(clk_mem),.bank_sel(1'b0),.addr(22'd0),.write_en(1'b0),.data_in(16'd0),
    .write_high_byte(1'b1),.write_low_byte(1'b1),.read_en(1'b0),.read_avail(),.data_out(),.busy(),.snes_acc(),
    .m_req_tgl(tgl),.m_we(we),.m_bank(1'b0),.m_addr(a),.m_wdata(wd),.m_two(two),.m_wdata2(wd2),.m_ack_tgl(ack),.m_rdata(rd),
    .cram_a(ca),.cram_dq(dq),.cram_wait(1'b0),.cram_clk(),.cram_adv_n(adv_n),.cram_cre(),.cram_ce0_n(ce0_n),.cram_ce1_n(),
    .cram_oe_n(oe_n),.cram_we_n(we_n),.cram_ub_n(),.cram_lb_n());
  reg [15:0] mem [0:22'h3FFFFF];
  reg [21:0] lat_a; reg [15:0] rd_q;
  always @(posedge clk_mem) begin
    if (!adv_n && !ce0_n) lat_a <= {ca, dq};
  end
  always @(posedge clk_mem) if (!we_n && !ce0_n && adv_n) mem[lat_a] <= dq;
  assign dq = (!oe_n && !ce0_n) ? mem[lat_a] : 16'hzzzz;

  // ---------------- bridge (single command channel) + data_loader pacing ----------------
  function [15:0] pat; input s; input [31:0] wordidx; pat = wordidx[15:0] ^ (s ? 16'hA5C3 : 16'h3C5A) ^ {wordidx[23:16], 8'h00}; endfunction
  reg m_bf_q=0, v_bf_q=0, m_pend=0, v_pend=0, last_v=0;
  integer cmds=0, retries_m=0, retries_v=0; reg [31:0] last_moff=32'hFFFFFFFF, last_voff=32'hFFFFFFFF;
  integer busy_cyc=0, tot_cyc=0;
  reg busy=0;
  initial begin : bridge
    integer i, n, sel; reg [31:0] off, len;
    @(negedge reset);
    forever begin
      @(posedge clk_sys);
      if (m_pend || v_pend) begin
        sel = (v_pend && (!m_pend || !last_v)) ? 1 : 0;
        last_v = sel;
        if (sel) begin v_pend=0; off=v_boff; len=v_blen; if (off==last_voff) retries_v=retries_v+1; last_voff=off; end
        else     begin m_pend=0; off=m_boff; len=m_blen; if (off==last_moff) retries_m=retries_m+1; last_moff=off; end
        cmds=cmds+1; busy=1;
        repeat (`LAT) @(posedge clk_sys);                  // command latency
        n = len/4;
        for (i=0;i<n;i=i+1) begin
          // one 32-bit bridge write -> two 16-bit words from the loader, 7 clk apart
          if (sel) begin v_bdat<=pat(1,(off>>1)+2*i);   v_bw<=1; end else begin m_bdat<=pat(0,(off>>1)+2*i);   m_bw<=1; end
          @(posedge clk_sys); v_bw<=0; m_bw<=0; repeat(6) @(posedge clk_sys);
          if (sel) begin v_bdat<=pat(1,(off>>1)+2*i+1); v_bw<=1; end else begin m_bdat<=pat(0,(off>>1)+2*i+1); m_bw<=1; end
          @(posedge clk_sys); v_bw<=0; m_bw<=0;
          repeat (`BPERIOD-8 + (($random & 7)==0 ? 6 : 0)) @(posedge clk_sys);
        end
        repeat (40) @(posedge clk_sys);
        if (sel) v_bd<=~v_bd; else m_bd<=~m_bd;
        busy=0;
      end
    end
  end
  always @(posedge clk_sys) begin
    if (m_bf != m_bf_q) begin m_bf_q <= m_bf; m_pend <= 1; end
    if (v_bf != v_bf_q) begin v_bf_q <= v_bf; v_pend <= 1; end
    tot_cyc = tot_cyc + 1; if (busy) busy_cyc = busy_cyc + 1;
  end

  // ---------------- audio consumers (44.1 kHz stereo, 1024-word FIFO, 512-word fetches) ----------------
  integer m_lvl=0, v_lvl=0, m_und=0, v_und=0, m_err=0, v_err=0, m_bad=0, v_bad=0, m_minl=99999, v_minl=99999;
  reg m_out=0, v_out=0, m_run=0, v_run=0, m_started=0, v_started=0; reg [31:0] m_cur=0, v_cur=0, m_exp=0, v_exp=0;
  reg m_ad_q=0, v_ad_q=0; integer sc=0;
  always @(posedge clk_sys) begin
    sc = sc + 1;
    if (m_pw) begin if (m_pd !== pat(0,m_exp)) begin if (m_bad<5) $display("MBAD t=%0t exp_idx=%0h got=%h want=%h", $time, m_exp, m_pd, pat(0,m_exp)); m_bad=m_bad+1; end m_exp=m_exp+1; m_lvl=m_lvl+1; end
    if (v_pw) begin if (v_pd !== pat(1,v_exp)) v_bad=v_bad+1; v_exp=v_exp+1; v_lvl=v_lvl+1; end
    if (m_ad != m_ad_q) begin m_ad_q<=m_ad; m_out<=0; if (m_ae) m_err=m_err+1; else m_cur=m_cur+1024; end
    if (v_ad != v_ad_q) begin v_ad_q<=v_ad; v_out<=0; if (v_ae) v_err=v_err+1; else v_cur=v_cur+1024; end
    if (m_run && !m_out && m_lvl <= 512) begin m_aoff<=m_cur; m_alen<=16'd1024; m_exp=m_cur>>1; m_af<=~m_af; m_out<=1; end
    if (v_run && !v_out && v_lvl <= 512 && v_cur + 1024 <= v_size) begin v_aoff<=v_cur; v_alen<=16'd1024; v_exp=v_cur>>1; v_af<=~v_af; v_out<=1; end
    if (sc % 487 == 0) begin
      if (m_run) begin if (m_lvl >= 2) begin m_lvl=m_lvl-2; m_started=1; end else if (m_started) m_und=m_und+1; if (m_started && m_lvl<m_minl) m_minl=m_lvl; end
      if (v_run) begin if (v_lvl >= 2) begin v_lvl=v_lvl-2; v_started=1; end else if (v_started && v_cur + 1024 <= v_size) v_und=v_und+1; if (v_started && v_lvl<v_minl) v_minl=v_lvl; end
    end
  end

  initial begin
    #(1000000); reset=0;
    #(1000000); m_mnt=1; #(1000000); m_mnt=0; m_run=1;
    #(`VSTART); v_mnt=1; #(1000000); v_mnt=0; v_run=1;
    #(`TEND);
    $display("%s BPERIOD=%0d: bridge cmds=%0d busy=%0d%%  retries music=%0d voice=%0d | music underruns=%0d minlvl=%0d err=%0d bad=%0d | voice underruns=%0d minlvl=%0d err=%0d bad=%0d | mc.pfail=%0d vc.pfail=%0d",
      `NAME, `BPERIOD, cmds, busy_cyc*100/tot_cyc, retries_m, retries_v, m_und, m_minl, m_err, m_bad, v_und, v_minl, v_err, v_bad, mc.pfail, vc.pfail);
    $finish;
  end
endmodule
