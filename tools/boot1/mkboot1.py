"""Build src/fpga/core/rtl/mister_top/boot1.mif (0.8.5 save state firmware).

Input: the 0.8 save state firmware snes_msu_ss/rtl/upstream/releases/boot1.rom (MiSTer savestates firmware plus the
0.8 S-DD1 block $18 and MSU-1 block $19). This script appends an SPC7110 block (tag $1A: 37 registers read on save,
written back on load; the SPC7110 HDL ignores the side effects of these writes while SS_BUSY) and hooks it into the
save chip dispatch and the load tag dispatch.
usage: mkboot1.py <boot1.rom in> <boot1.mif out>
"""
import sys
src=open(sys.argv[1],'rb').read()

def mif(data, path, name):
    data=data+bytes(4096-len(data))
    with open(path,'w',newline='\r\n') as f:
        f.write('-- Generated from %s\n\nWIDTH=16;\nDEPTH=2048;\n\nADDRESS_RADIX=HEX;\nDATA_RADIX=HEX;\n\nCONTENT BEGIN\n'%name)
        for i in range(2048):
            f.write('\t%03X : %04X;\n'%(i, data[2*i] | (data[2*i+1]<<8)))
        f.write('END;\n')


b=bytearray(src)
assert len(b)==3790
assert b[0x0DF1:0x0DF4]==bytes([0x4C,0x0B,0x84])   # S-DD1 save dispatch: JMP $840B (not S-DD1)
assert b[0x0E98:0x0E9B]==bytes([0x4C,0xAF,0x87])   # load tag dispatch: JMP $87AF (not tag $19)

class Asm:
    def __init__(s,org): s.org=org; s.code=bytearray(); s.fix=[]; s.lab={}
    def pc(s): return s.org+len(s.code)
    def emit(s,*bs): s.code+=bytes(bs)
    def label(s,n): s.lab[n]=s.pc()
    def bra(s,op,n): s.emit(op,0); s.fix.append((len(s.code)-1,n))
    def done(s):
        for off,n in s.fix:
            rel=s.lab[n]-(s.org+off+1)
            assert -128<=rel<=127
            s.code[off]=rel&0xFF
        return s.code

REGS=[0x30,0x31,0x32,0x33, 0x01,0x02,0x03,0x04,0x05,0x06, 0x09,0x0A,0x0B,0x0C,
      0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18, 0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27, 0x2E,
      0x28,0x29,0x2A,0x2B,0x2C,0x2D]
TAG=0x1A
base=len(b)                       # append after the 0.8 blocks
cpu=lambda off: 0x8000+off        # boot1 runs at $00:8000

# table first (fixed address)
tbl_off=base
table=bytes(REGS)+b'\xff'
a=Asm(cpu(base+len(table)))
# ---- save: A = rom_type & $F0 (8-bit A, 16-bit X/Y), the stream port is $C06000
a.label('save')
a.emit(0xC9,0xD0)                 # CMP #$D0 (SPC7110)
a.emit(0xF0,0x03)                 # BEQ +3
a.emit(0x4C,0x0B,0x84)            # JMP $840B (next block)
a.emit(0xDA, 0x5A)                # PHX / PHY
a.emit(0xC2,0x20, 0xA9,0x00,0x00, 0xE2,0x20)   # B = 0 (for TAY)
a.emit(0x8B, 0x48, 0xAB)          # PHB / PHA / PLB : DB = $00
a.emit(0xA9,TAG, 0x8F,0x00,0x60,0xC0)          # tag
a.emit(0xA2,0x00,0x00)            # LDX #0
a.label('s_loop')
a.emit(0xBF, cpu(tbl_off)&0xFF, cpu(tbl_off)>>8, 0x00)   # LDA $00:table,X
a.emit(0xC9,0xFF); a.bra(0xF0,'s_done')                  # end marker
a.emit(0xA8)                      # TAY
a.emit(0xB9,0x00,0x48)            # LDA $4800,Y
a.emit(0x8F,0x00,0x60,0xC0)       # STA $C06000
a.emit(0xE8)                      # INX
a.bra(0x80,'s_loop')
a.label('s_done')
a.emit(0xAB, 0x7A, 0xFA)          # PLB / PLY / PLX
a.emit(0x4C,0x0B,0x84)            # JMP $840B
# ---- load: A = tag
a.label('load')
a.emit(0xC9,TAG)                  # CMP #$1A
a.emit(0xF0,0x03)
a.emit(0x4C,0xAF,0x87)            # JMP $87AF (as before)
a.emit(0xDA, 0x5A)
a.emit(0xC2,0x20, 0xA9,0x00,0x00, 0xE2,0x20)
a.emit(0x8B, 0x48, 0xAB)
a.emit(0xA2,0x00,0x00)
a.label('l_loop')
a.emit(0xBF, cpu(tbl_off)&0xFF, cpu(tbl_off)>>8, 0x00)
a.emit(0xC9,0xFF); a.bra(0xF0,'l_done')
a.emit(0xA8)                      # TAY
a.emit(0xAF,0x00,0x60,0xC0)       # LDA $C06000
a.emit(0x99,0x00,0x48)            # STA $4800,Y
a.emit(0xE8)
a.bra(0x80,'l_loop')
a.label('l_done')
a.emit(0xAB, 0x7A, 0xFA)
a.emit(0x4C,0x3E,0x87)            # JMP $873E (next tag)
code=a.done()
b+=table+code
sv=a.lab['save']; ld=a.lab['load']
b[0x0DF1:0x0DF4]=bytes([0x4C,sv&0xFF,sv>>8])
b[0x0E98:0x0E9B]=bytes([0x4C,ld&0xFF,ld>>8])
assert len(b)<=4096
mif(bytes(b),sys.argv[2],'boot1.rom (0.8 SS firmware + SPC7110 block $1A)')
print('size',len(b),'table @%04x save @%04x load @%04x'%(cpu(tbl_off),sv,ld))
