# SNES (MSU-1) for Analogue Pocket — unofficial modified build

An **unofficial, experimental** modification of agg23's openFPGA SNES core (openfpga-snes 0.4.4) that adds
**MSU-1** support (CD-quality audio tracks and streamed data), a 3-level CPU Turbo setting, and
beep-free operation. It is **not** made, endorsed or supported by agg23, srg320 or the MiSTer project.
Please do **not** report problems with this build to them.

## What's included
| Core folder | Chips in the main/PAL bitstreams | Use for |
|---|---|---|
| `Cores/Moongom.SNES_MSU` | SA-1, Super FX (GSU), S-DD1, MSU-1 | most games, SA-1 games (Super Mario RPG, Kirby Super Star, …) |
| `Cores/Moongom.SNES_MSU_CX4DSP` | CX4, DSP-n, Super FX (GSU), S-DD1, MSU-1 | Mega Man X2/X3, Super Mario Kart, Pilotwings, … |

Both cores have NTSC (main), PAL (PAL) and SPC7110/BSX (SPCSDD1) bitstreams.

## Install
Copy the folder(s) from `Cores/` to the `Cores/` folder of your Pocket SD card. You may remove the
original `agg23.SNES` core or keep it side by side.

## Using MSU-1
You must supply your own game files. Put them next to the ROM, with matching names:

    game.sfc   game.msu (may be empty)   game-1.pcm   game-2.pcm ...

PCM format: header `MSU1`, 32-bit loop point, then 16-bit little-endian stereo at 44.1 kHz.
**No ROMs, PCM audio or other copyrighted game data are included or may be distributed with this core.**

## CPU Turbo
Off / On (6 master clocks, FastROM speed) / Max (original 5 clocks). Turbo is disabled automatically
for SA-1 and S-DD1 games. Some games may freeze with turbo enabled; leave it Off if so.

## Known issues / status
- Experimental. Tested mainly on Tales of Phantasia and Final Fantasy VI MSU-1 packs; not every game is tested.
- The CPU Turbo freezing issue has not been fully root-caused.
- The SA-1 + GSU + S-DD1 core does not include CX4 or DSP-n (they do not fit the FPGA together).
- Timing report shows one small fast-corner hold violation (−0.05 ns) in the SA-1/GSU/S-DD1 NTSC build.

## License and source
This work is a modification of GPLv3 software and is distributed under the **GNU GPL v3** (see `LICENSE`).
The complete corresponding source is in `source/`:
- `openfpga-snes-msu1-source.tar.gz` — full modified source tree (Quartus project)
- `msu1-vs-openfpga-snes-0.4.4.patch` — changes against upstream openfpga-snes 0.4.4

Build: Quartus Prime 25.1 Lite, `quartus_sh -t generate.tcl <variant>`, then `python3 tools/rbf_to_rev.py ap_core.rbf out.rev`.

See `CREDITS.md` for attribution.

## Repository
https://github.com/moongommoongom/Moongom (upstream: https://github.com/agg23/openfpga-snes)
