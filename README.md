# SNES (MSU-1) for Analogue Pocket — unofficial modified build

An **unofficial, experimental, personal fork** of agg23's openFPGA SNES core (openfpga-snes 0.4.4).
It is **not** made, endorsed or supported by agg23, srg320 or the MiSTer project, and it is **not** a
pull request or proposal to upstream. Please do **not** report problems with this build to them;
open an issue here instead.

## AI disclosure
This fork was developed with heavy help from an AI assistant (Claude, by Anthropic), directed and
tested by the repository owner. Expect rough edges. It has not been reviewed by the upstream authors.

## What this fork changes (vs upstream 0.4.4)
Upstream already contains the MSU-1 HDL (`MSU.sv`, `msu_audio.v`, `msu_data_store.sv`, `msu_fifo.v`,
ported from MiSTer) but ships it disabled (`USE_MSU=0`) and without Pocket data/audio streaming.
This fork:
- enables MSU-1 and connects it to the Pocket (APF data slots / bridge: `msu_bridge.v`, `core_bridge_cmd.v`, `core_top.sv`),
- modifies the MSU audio/data path (buffering, aligned reads, retries) to stream tracks from the SD card,
- adds a CPU Turbo setting (Off / On),
- removes debug beeps,
- provides different chip combinations per bitstream to fit the FPGA, all selected automatically from ONE core folder (the chip32 loader reads the ROM header),
- adds an optional MSU-1 pack format (`.msp` / `.ms1`…) and the MSUPackMaker tool (see `docs/MSUPackMaker.md`).
See `patches/` for the exact diff against upstream 0.4.4 (about +3,600 lines).

## What's included
One core folder, `Cores/Moongom.SNES_MSU`, holds several bitstreams. At load time the loader reads the ROM header and
picks one (all chips do not fit the FPGA together, ~96% ALM full):

| Bitstream | Chips | Selected for |
|---|---|---|
| `snes_main.rev` / `snes_pal.rev` | SA-1, Super FX (GSU), S-DD1, MSU-1 | most games, SA-1 / GSU / S-DD1 games |
| `snes_spc.rev` | SPC7110, BSX, S-DD1, MSU-1 | SPC7110, BSX |
| `snes_cx4dsp.rev` / `snes_cx4dsp_pal.rev` | CX4, DSP-n (1–4), ST010, Super FX, MSU-1 | Mega Man X2/X3, Super Mario Kart, Pilotwings, … |

NTSC and PAL variants are chosen from the ROM region. The automatic selection (`loader.bin`) is not yet verified on all games.

## Download / Install
Download `Moongom_SNES_MSU1_core_r1.zip` from the [Releases](https://github.com/moongommoongom/Moongom/releases) page (the repository holds source only, no `.rev` bitstreams). Copy the `Cores/Moongom.SNES_MSU` folder (and remove any older `Moongom.SNES_MSU*` folders) to the root of your Pocket SD card. You may remove the
original `agg23.SNES` core or keep it side by side.

See also: [한국어 README](README.ko.md).

## Using MSU-1
You must supply your own game files. Put them next to the ROM, with matching names:

    game.sfc   game.msu (may be empty)   game-1.pcm   game-2.pcm ...

or, packed with MSUPackMaker:  `game.sfc   game.msp   game.ms1 ...`

### Pack files (optional)
For games with thousands of `.pcm` files use [MSUPackMaker](docs/MSUPackMaker.md) to build `game.msp` (music) and `game.ms1`… (voice). No 4 GiB limit; music and voice play in parallel.

PCM format: header `MSU1`, 32-bit loop point, then 16-bit little-endian stereo at 44.1 kHz.
**No ROMs, PCM audio or other copyrighted game data are included or may be distributed with this core.**

## CPU Turbo
Off / On (6 master clocks, FastROM speed). The old "Max" level was removed. Turbo is disabled automatically
for SA-1 and S-DD1 games. Some games may freeze with turbo enabled; leave it Off if so.

## Known issues / status
- Experimental. Tested mainly on Tales of Phantasia and Final Fantasy VI MSU-1 packs; not every game is tested.
- The CPU Turbo freezing issue has not been fully root-caused.
- SA-1 + GSU + S-DD1 and CX4 + DSP-n cannot share one bitstream (they do not fit the FPGA together), so they are separate bitstreams in the same core folder.
- Timing is not clean in the latest builds: main-clock setup slack is slightly negative (about −0.1 to −0.9 ns, worst in the CX4/DSP PAL build); hold is met. Not all variants are verified on hardware.
- In some folders with thousands of files MSU-1 did not start while the same files worked elsewhere (cause not found). Packs (`.msp`) or a separate folder helped.

## License and source
This work is a modification of GPLv3 software and is distributed under the **GNU GPL v3** (see `LICENSE`).
The complete corresponding source is this repository:
- `src/` — modified Quartus project (HDL, chip32 loader `src/support/loader.asm`)
- `patches/msu1-vs-openfpga-snes-0.4.4.patch` — all changes against upstream openfpga-snes 0.4.4
- `tools/` — `rbf_to_rev.py` (bitstream converter), `MSUPackMaker.exe` + source `tools/msupack/` (usage: `docs/MSUPackMaker.md`)
- `docs/` — notes and dev log (`DEVLOG.md`, Korean)

Build: Quartus Prime 25.1 Lite, `quartus_sh -t generate.tcl <variant>` (variants: `ntsc`, `pal` = CX4/DSP-n; `ntsc_sa1gsu`, `pal_sa1gsu` = SA-1/GSU/S-DD1; `ntsc_spc` = SPC7110/BSX), then `python3 tools/rbf_to_rev.py ap_core.rbf out.rev`.
The loader is assembled with bass + bass-chip32 (`src/support/loader.asm`).

See `CREDITS.md` for attribution.

## Repository
https://github.com/moongommoongom/Moongom (upstream: https://github.com/agg23/openfpga-snes)

## Contributing / upstream
This is a separate fork. Do not send this work to upstream repositories unless the maintainers ask for it.
