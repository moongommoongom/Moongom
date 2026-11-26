# Credits

- **agg23** — openFPGA SNES port for Analogue Pocket (https://github.com/agg23/openfpga-snes), GPLv3.
- **srg320** — original FPGA SNES core (SNES/SA-1/GSU/DSP/CX4/S-DD1/SPC7110 implementation).
- **MiSTer-devel / SNES_MiSTer contributors** — MSU-1 reference implementation and SNES core integration (GPL).
- **drizzt (openfpga-snes experimental)** — save-state implementation for the Pocket SNES core (https://github.com/drizzt/openfpga-snes) and the `agg23.SNES_experimental` core, GPLv3.
- **Analogue** — Analogue Pocket / openFPGA framework (APF).
- MSU-1 specification by byuu (Near).

This build only adds MSU-1 integration, CPU Turbo modes, chip combinations and related fixes on top of
the above. All trademarks and game titles belong to their respective owners. No game data is included.

The `snes_msu_ss/` (0.8) tree additionally contains Analogue's openFPGA APF platform files (`platform/pocket`), which keep their original license notices. Core icon and loader come from upstream openfpga-snes. `rtl/analogizer/` (third-party Analogizer support code) is kept only so the project compiles; the feature is disabled in this build.

0.8.5 (`src/`): the R1 line plus the MiSTer SNES save state engine and chip save state hooks (SNES_MiSTer upstream,
GPL), the 0.8 save state firmware blocks (S-DD1, MSU-1) and a new SPC7110 block (`tools/boot1/mkboot1.py`).
`src/fpga/core/rtl/mister_top/sram_split.sv` uses the async SRAM controller engine by Adam Gastineau (agg23,
openfpga-litex, MIT License).

## Genesis MD+ (`genesis_mdplus/`)

- **ericlewis** — openFPGA Genesis for Analogue Pocket (https://github.com/opengateware/openFPGA-Genesis).
- **RndMnkIII** — Analogizer version of the Genesis core and Analogizer support code (https://github.com/RndMnkIII/Analogizer).
- **sorgelig, srg320, Kitrinx and the MiSTer Genesis contributors** — MiSTer Genesis core.
- **Gregory Estrade (Torlus)** — fpgagen.
- **Jotego** — jt12 (YM2612) and jt89 (SN76489), GPLv3.
- **Jorge Cwik** — fx68k (68000). **Daniel Wallner** — T80 (Z80).
- **agg23** — Analogue Pocket support modules.
- **Terraonion and the MD+ patch authors** — MD+ / MegaSD CD audio format.

Licenses of each upstream part are listed in [`genesis_mdplus/README.md`](genesis_mdplus/README.md#license);
every file keeps its original notice. The MD+ and save state additions are GPLv3.
