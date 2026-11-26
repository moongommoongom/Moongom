# Changelog

## 0.8 (2026-11-26) - test release

First public test release of the MD+ / save state fork.

MD+ CD audio
- Reads `.cue` + `.wav` directly (same name as the ROM, same folder).
- 44.1 kHz -> 48 kHz resampling, loop points, fades, pause/resume, volume.
- Track heads (~1.5 s) cached in PSRAM in the background (63 tracks).
- SD access is paced and paused while the Pocket menu is open (no menu lag).
- MD+ starts in the background after the ROM load; commands sent before it is
  ready are queued. Wav headers are read when a track is first played/cached.
- Menu "MD+ Audio": On 100/75/50/25%, Off.

Save states (Pocket Memories)
- New: create / load Memories (`sleep_supported` enabled).
- Taken on vblank by a 68000 routine; VDP/PSG/YM2612 registers are shadowed,
  the Z80 is stopped on an instruction boundary.
- The MD+ track resumes from the saved position.
- Not supported: SVP (Virtua Racing). Battery RAM is not part of the state.

Other
- SRAM window limited to 0x200000-0x2FFFFF (MD+ drivers live at 0x300000+).
- "M30 Controllers" menu entry removed.

Development builds t1-t7.7d (2026-11-22 .. 2026-11-26) are not published
separately; their history is in the git log.
