#!/usr/bin/env python3
"""Join the darwin/amd64 and darwin/arm64 builds of MSUPackMaker into one universal (fat) Mach-O binary,
the same layout `lipo -create` writes (useful when building on Linux or Windows, where lipo is not available).

  GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o msupack_amd64 .
  GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o msupack_arm64 .
  python3 make_universal.py msupack_amd64 msupack_arm64 MSUPackMaker_macOS

The Go linker gives the arm64 build an ad-hoc code signature (required on Apple Silicon); each slice keeps its own.
"""
import os, struct, sys

amd64, arm64, out = sys.argv[1:4]
slices = [(amd64, 0x01000007, 3), (arm64, 0x0100000C, 0)]   # CPU_TYPE_X86_64 / CPU_TYPE_ARM64, subtype ALL
ALIGN_LOG2 = 14
align = 1 << ALIGN_LOG2
head = struct.pack('>II', 0xCAFEBABE, len(slices))
off, body = align, []
for path, cpu, sub in slices:
    data = open(path, 'rb').read()
    head += struct.pack('>iiIII', cpu, sub, off, len(data), ALIGN_LOG2)
    body.append((off, data))
    off = (off + len(data) + align - 1) // align * align
buf = bytearray(off)
buf[:len(head)] = head
for o, data in body:
    buf[o:o + len(data)] = data
open(out, 'wb').write(buf)
os.chmod(out, 0o755)
print('wrote', out, len(buf), 'bytes')
