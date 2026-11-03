#!/usr/bin/env python3
"""Quartus .rbf -> Analogue Pocket .rev (reverse the bit order of every byte)."""
import sys
if len(sys.argv) != 3:
    sys.exit("usage: rbf_to_rev.py in.rbf out.rev")
tbl = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
open(sys.argv[2], "wb").write(open(sys.argv[1], "rb").read().translate(tbl))
