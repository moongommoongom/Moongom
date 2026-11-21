#!/usr/bin/env python3
"""Patch the openfpga-snes chip32 loader.bin (1430 bytes, R1 / agg23 build) to the 0.8.5 bitstream routing.

The routing is documented in src/support/loader.asm; no chip32 assembler is needed here, the release binary is
patched in place and a small routine is appended:
  0 main NTSC (plain, S-DD1, BS-X)   1 SPC7110        2 PAL (plain + CX4 + DSP-n)   3 CX4/DSP-n NTSC
  4 SA-1 NTSC   5 SA-1 PAL          6 Super FX NTSC   7 Super FX PAL
usage: patch_loader.py <loader.bin in> <loader.bin out>
"""
import struct, sys

src, dst = sys.argv[1], sys.argv[2]
c = bytearray(open(src, 'rb').read())
assert len(c) == 0x598, 'expected the 1430-byte openfpga-snes loader.bin'

def ld(r, imm):  return bytes([r, 0x08]) + struct.pack('<H', imm)
def cmp(r, imm): return bytes([r, 0x0e]) + struct.pack('<H', imm)
def core(r):     return bytes([r, 0x5b])
def jp(cond, addr):                      # chip32 jump word: cond << 12 | addr >> 1
    assert addr % 2 == 0
    return struct.pack('<H', (cond << 12) | (addr >> 1))
Z, NZ, AL = 8, 7, 6

# set_core: "ld r8,#0 / core r8" at 0x4CC -> jump to the appended routine (it re-runs both, then checks SA-1 / GSU)
assert c[0x4CC:0x4D2] == ld(8, 0) + core(8)
c[0x4CC:0x4D0] = jp(AL, 0x598) + b'\x00\x00'
# SDD1 (0x50): core 0 (S-DD1 is in the NTSC main bitstream): "jp expansion_core" -> "jp send_chip"
assert c[0x4F8:0x500] == cmp(4, 0x50) + jp(NZ, 0x500) + jp(AL, 0x506)
c[0x4FE:0x500] = jp(AL, 0x52C)
# BSX (0x30): compare never matches -> default path (main core)
assert c[0x500:0x504] == cmp(4, 0x30)
c[0x502:0x504] = struct.pack('<H', 0xFFFF)
# CX4 / DSP-n PAL carts: core 2 (the PAL bitstream is the PAL CX4 + DSP-n build)
assert c[0x518:0x51C] == ld(8, 4)
c[0x518:0x51C] = ld(8, 2)

SA1, GSU, GO = 0x5AC, 0x5BC, 0x5CA
p = bytearray()
p += ld(8, 0) + core(8)                                    # 598 default core 0
p += cmp(4, 0x60) + jp(Z, SA1)                             # SA-1
p += cmp(4, 0x70) + jp(Z, GSU)                             # Super FX
p += jp(AL, 0x4D2)                                         # back to the CX4 / DSP / SPC7110 checks
p += ld(8, 4) + cmp(3, 1) + jp(NZ, GO) + ld(8, 5) + jp(AL, GO)   # 5AC SA-1: 4 NTSC / 5 PAL
p += ld(8, 6) + cmp(3, 1) + jp(NZ, GO) + ld(8, 7)                # 5BC Super FX: 6 NTSC / 7 PAL
p += core(8) + jp(AL, 0x52C)                               # 5CA select, then send the chip type
c += p
open(dst, 'wb').write(c)
print('wrote', dst, len(c), 'bytes')
