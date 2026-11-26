#!/usr/bin/env python3
# Builds the 68000 save state handler (overlay at $5F0000) and writes rtl/ss_hrom.sv
# Hand encoded subset of 68000 instructions.
import sys

STREAM = 0x5FE000   # sequential stream port (any address in 5FE000-5FEFFF)
S_RST  = 0x5FF002
Z80CTL = 0x5FF006
APPLY  = 0x5FF008
DONE   = 0x5FF00A
SEEK   = 0x5FF00C
PROG   = 0x5FF00E   # diagnostic progress mark
INFO   = 0x5FF100
FMSH   = 0x5FF400
VCTRL  = 0xC00004
VDATA  = 0xC00000

# stream layout (word offsets)
O_REGS, O_INFO, O_FM, O_CRAM, O_VSRAM, O_IO, O_ZRAM, O_VRAM, O_WRAM, O_END = \
    0x0000, 0x0040, 0x00C0, 0x01C0, 0x0200, 0x0240, 0x0400, 0x2400, 0xA400, 0x12400
INFO_VDP, INFO_PSG = 32, 56

class Asm:
    def __init__(s, base): s.base=base; s.w=[]; s.lab={}; s.fix=[]
    def pc(s): return s.base + 2*len(s.w)
    def L(s, n): s.lab[n]=s.pc()
    def words(s,*ws):
        for x in ws: s.w.append(x & 0xFFFF)
    def l32(s,v): s.words(v>>16, v)
    # instructions
    def move_sr(s,imm): s.words(0x46FC, imm)
    def movew_imm_abs(s,imm,a): s.words(0x33FC, imm); s.l32(a)
    def movel_imm_abs(s,imm,a): s.words(0x23FC); s.l32(imm); s.l32(a)
    def movew_abs_abs(s,src,dst): s.words(0x33F9); s.l32(src); s.l32(dst)
    def moveb_abs_abs(s,src,dst): s.words(0x13F9); s.l32(src); s.l32(dst)
    def movem_save(s,a): s.words(0x48F9, 0x7FFF); s.l32(a)      # movem.l d0-a6,abs.l
    def movem_load(s,a): s.words(0x4CF9, 0x7FFF); s.l32(a)      # movem.l abs.l,d0-a6
    def move_usp_a0(s): s.words(0x4E68)
    def move_a0_usp(s): s.words(0x4E60)
    def movel_a0_abs(s,a): s.words(0x23C8); s.l32(a)
    def movel_a7_abs(s,a): s.words(0x23CF); s.l32(a)
    def moveal_abs_a0(s,a): s.words(0x2079); s.l32(a)
    def moveal_abs_a7(s,a): s.words(0x2E79); s.l32(a)
    def lea_a0(s,a): s.words(0x41F9); s.l32(a)
    def lea_a1(s,a): s.words(0x43F9); s.l32(a)
    def movew_imm_d0(s,imm): s.words(0x303C, imm)
    def btst_abs(s,bit,a): s.words(0x0839, bit); s.l32(a)
    def bcc(s,op,lab): s.fix.append((len(s.w),lab,'s')); s.words(op<<8)
    def dbra(s,lab): s.words(0x51C8); s.fix.append((len(s.w),lab,'w')); s.words(0)
    def stop(s,imm): s.words(0x4E72, imm)
    def rts(s): s.words(0x4E75)
    def addq6_sp(s): s.words(0x5C8F)
    def movel_absw_predec_sp(s,a): s.words(0x2F38, a)
    def raw(s,op): s.words(op)
    def resolve(s):
        for i,lab,k in s.fix:
            tgt=s.lab[lab]
            if k=='s':
                d=tgt-(s.base+2*i+2); assert -128<=d<=127 and d!=0
                s.w[i] |= d & 0xFF
            else:
                d=tgt-(s.base+2*(i-1)+2); assert -32768<=d<=32767
                s.w[i] = d & 0xFFFF
    # helpers
    def copy(s, op, n, lab):
        s.movew_imm_d0(n-1); s.L(lab); s.raw(op); s.dbra(lab)
    def seek(s,o): s.movew_imm_abs(o, SEEK)
    def z80_freeze(s,lab):
        s.movew_imm_abs(1, Z80CTL); s.L(lab); s.btst_abs(0, Z80CTL+1); s.bcc(0x67, lab)

OP_W_A0P_A1  = 0x3298  # move.w (a0)+,(a1)
OP_W_A0_A1   = 0x3290  # move.w (a0),(a1)
OP_W_A0_A1P  = 0x32D0  # move.w (a0),(a1)+
OP_B_A0P_A1  = 0x1298  # move.b (a0)+,(a1)
OP_B_A0_A1P  = 0x12D0  # move.b (a0),(a1)+
OP_B_A0_A1   = 0x1290  # move.b (a0),(a1)

IO_REGS = [0xA10009, 0xA1000B, 0xA1000D, 0xA10003, 0xA10005, 0xA10007]

def tail(a, p):
    # restore of everything done: wait for the start of vblank, then sleep until the
    # vblank interrupt (that IACK is redirected to the stub at $5F03D0)
    a.L(p+'w1'); a.btst_abs(3, VCTRL+1); a.bcc(0x66, p+'w1')
    a.L(p+'w2'); a.btst_abs(3, VCTRL+1); a.bcc(0x67, p+'w2')
    a.movew_imm_abs(9, PROG)
    a.stop(0x2500)
    a.raw(0x4E71); a.raw(0x4E71)   # never reached

def save():
    a=Asm(0x5F0000)
    a.move_sr(0x2700)
    a.movew_imm_abs(0, S_RST)
    a.movem_save(STREAM)                 # 30 words
    a.move_usp_a0(); a.movel_a0_abs(STREAM)   # 2
    a.movel_a7_abs(STREAM)               # 2 -> 34
    a.z80_freeze('zw')
    a.movew_imm_abs(1, PROG)
    a.seek(O_INFO)
    a.lea_a0(INFO); a.lea_a1(STREAM); a.copy(OP_W_A0P_A1, 128, 'c1')
    a.lea_a0(FMSH);                   a.copy(OP_W_A0P_A1, 256, 'c2')
    a.movew_imm_abs(0x8F02, VCTRL)       # auto increment 2
    a.movel_imm_abs(0x00000020, VCTRL)   # CRAM read 0
    a.lea_a0(VDATA); a.copy(OP_W_A0_A1, 64, 'c3')
    a.movel_imm_abs(0x00000010, VCTRL)   # VSRAM read 0
    a.copy(OP_W_A0_A1, 40, 'c4')
    a.seek(O_IO)
    for r in IO_REGS: a.moveb_abs_abs(r, STREAM)
    a.seek(O_ZRAM)
    a.lea_a0(0xA00000); a.copy(OP_B_A0P_A1, 8192, 'c5')
    a.movel_imm_abs(0x00000000, VCTRL)   # VRAM read 0
    a.lea_a0(VDATA); a.copy(OP_W_A0_A1, 32768, 'c6')
    a.lea_a0(0xFF0000); a.copy(OP_W_A0P_A1, 32768, 'c7')
    a.movew_imm_abs(2, PROG)
    a.movew_abs_abs(INFO + 2*(INFO_VDP+15), VCTRL)   # game's auto increment back
    a.movew_imm_abs(0, Z80CTL)
    a.seek(0)
    a.movem_load(STREAM)
    tail(a,'s')
    a.resolve(); return a

def load():
    a=Asm(0x5F01A0)
    a.move_sr(0x2700)
    a.z80_freeze('zw')
    a.movew_imm_abs(1, PROG)
    a.movew_imm_abs(0x8104, VCTRL)       # display off
    a.movew_imm_abs(0x8F02, VCTRL)
    a.lea_a0(STREAM)
    a.seek(O_ZRAM)
    a.lea_a1(0xA00000); a.copy(OP_B_A0_A1P, 8192, 'l1')
    a.movew_imm_abs(2, PROG)
    a.movel_imm_abs(0x40000000, VCTRL)   # VRAM write 0 (stream is at O_VRAM now)
    a.lea_a1(VDATA); a.copy(OP_W_A0_A1, 32768, 'l2')
    a.movew_imm_abs(3, PROG)
    a.lea_a1(0xFF0000); a.copy(OP_W_A0_A1P, 32768, 'l3')
    a.movew_imm_abs(4, PROG)
    a.seek(O_CRAM)
    a.movel_imm_abs(0xC0000000, VCTRL)   # CRAM write 0
    a.lea_a1(VDATA); a.copy(OP_W_A0_A1, 64, 'l4')
    a.seek(O_VSRAM)
    a.movel_imm_abs(0x40000010, VCTRL)   # VSRAM write 0
    a.copy(OP_W_A0_A1, 40, 'l5')
    a.seek(O_FM)
    a.lea_a1(FMSH); a.copy(OP_W_A0_A1P, 256, 'l6')
    a.seek(O_INFO)
    a.lea_a1(INFO); a.copy(OP_W_A0_A1P, 128, 'l7')
    a.movew_imm_abs(5, PROG)
    a.movew_imm_abs(1, APPLY)
    a.L('aw'); a.btst_abs(0, APPLY+1); a.bcc(0x66, 'aw')
    a.movew_imm_abs(6, PROG)
    a.seek(O_INFO + INFO_PSG)
    a.lea_a1(0xC00011); a.copy(OP_B_A0_A1, 16, 'l8')
    a.seek(O_INFO + INFO_VDP)
    a.lea_a1(VCTRL); a.copy(OP_W_A0_A1, 24, 'l9')
    a.movew_imm_abs(7, PROG)
    a.seek(O_IO)
    for r in IO_REGS: a.moveb_abs_abs(STREAM, r)
    a.seek(30)
    a.moveal_abs_a0(STREAM); a.move_a0_usp()
    a.moveal_abs_a7(STREAM)
    a.seek(0)
    a.movem_load(STREAM)
    a.movew_imm_abs(0, Z80CTL)
    a.movew_imm_abs(8, PROG)
    tail(a,'l')
    a.resolve(); return a

def stub():
    # vblank IACK taken from the STOP above: drop that frame, run the game's own
    # vblank handler on the saved frame
    a=Asm(0x5F03D0)
    a.addq6_sp()
    a.movew_imm_abs(0, DONE)
    a.movel_absw_predec_sp(0x0078)
    a.rts()
    a.resolve(); return a

rom=[0x4E71]*512
for a in (save(), load(), stub()):
    off=(a.base-0x5F0000)//2
    assert len(a.w) <= 512, (hex(a.base), len(a.w))
    rom[off:off+len(a.w)]=a.w
    print(hex(a.base), len(a.w), 'words', file=sys.stderr)

out=sys.argv[1]
with open(out,'w') as f:
    f.write("// generated by tools/ss_handler.py - 68000 save state handler at $5F0000\n")
    f.write("// $5F0000 save, $5F0160 load, $5F0310 vblank tail stub\n")
    f.write("module ss_hrom (input wire clk, input wire [8:0] addr, output reg [15:0] q);\n")
    f.write("(* ramstyle = \"M10K\" *) reg [15:0] rom [0:511];\n")
    f.write("integer i;\ninitial begin\n    for (i = 0; i < 512; i = i + 1) rom[i] = 16'h4E71;\n")
    for i,w in enumerate(rom):
        if w!=0x4E71: f.write(f"    rom[{i}] = 16'h{w:04X};\n")
    f.write("end\nalways @(posedge clk) q <= rom[addr];\nendmodule\n")
