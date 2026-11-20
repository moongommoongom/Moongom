# R1SS (work in progress)

The R1 core (Moongom SNES MSU-1 r1) with MiSTer SNES save states added.
This branch is a snapshot of the source as it was built for the R1SS test2 package.
It is not a release.

## What was changed against main (R1 source)

- **Save state hooks** from MiSTer SNES_MiSTer commit 7e9ec63: DSP, DSP_PKG, SMP, SPC700, PPU, SNES.vhd (`patches/ss_hooks.patch`).
- **HDMAEN defer while SS_BUSY** from commit 912f93f (`patches/hdma.patch`).
  - `CPU.vhd` also gets an `SS_NMI_FORCE` input and a VBLANK falling-edge detector (`FALLING_VBLANK`).
- **savestates.sv, savestates_regs.sv, savestates_map.sv, savestates_sa1.sv** taken from the SS core (snes_msu_ss).
- **`rtl/main.v`:**
  - adds the `USE_SS` parameter and the SS ports;
  - instantiates `savestates`;
  - ARAM and BSRAM go through an SS access mux;
  - `SS_AVAIL` is set only when no coprocessor is in use (`ROM_TYPE[7:4] == 0`, `MAP_ACTIVE == 0`).
- **`rtl/mister_top/SNES.sv`:**
  - with `USE_SS` set:
    - ARAM moves to BRAM (`dpram #(16)`);
    - a `savestate` PSRAM blob is placed on cram1, with the MSU PSRAM port passed through;
    - `boot1_rom` is injected at bank FF while `ss_busy`;
    - BSRAM shrinks to 32 KB so the design fits in M10K (276/308).
  - without `USE_SS`, the R1 memory layout is kept.
- **`core_top.sv`:**
  - the save state bridge region is 0x7;
  - `data_loader`/`data_unloader` and `savestate_controller` are taken from the SS core;
  - the save state blob is 0x44000 bytes;
  - `ss_pause` goes to `msu_bridge`.
- **`msu_bridge.v`:**
  - no new track, voice or data request is issued while `ss_pause`;
  - the init watchdog is 31-bit, set to 15 s.
- **`core_constraints.sdc`:** max-delay constraints for `savestate_rom` and `main`.
- **`ap_core.qsf`:**
  - adds the new files;
  - turns SignalTap off and removes `stp1.stp`.
- **`apf/build_id_gen.tcl`:** added; it was missing from main.
- **`generate.tcl`:**
  - `USE_SS` defaults to 0;
  - a new variant `ntsc_ss` sets `USE_SS=1` with all chips off and MSU on.

## Build

`r1ss/build/drive201.tcl` builds `ntsc_ss` (R1SS) and then `ntsc_sa1gsu` (R1B control: same source, no save states, R1 layout).
It runs `quartus_sh -t generate.tcl <variant>` from the repo root.

## Packages

`r1ss/packages/*` holds `core.json` and `data.json` for each package:

| Package | Built from | sleep_supported |
|---|---|---|
| test2 | `ntsc_ss` | true |
| test2b_nosleep | same rbf as test2 | false |
| r1b_control | `ntsc_sa1gsu` (timing about -0.86 ns) | false |

## Test results so far

- **test1:** invalid. The wrong core was selected on the device.
- **test2:**
  - Fire Emblem (an MSU-1 music-only game) plays no MSU music.
  - FF6 plays only one of music or voice, never both together.
  - The MSU logic synthesizes the same as the R1B control (map report comparison).
  - Suspected cause: `sleep_supported: true` together with R1's older `core_bridge_cmd`.
- **test2b_nosleep, r1b_control:** waiting for results.
