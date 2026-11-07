# MSUPackMaker — MSU-1 pack tool / MSU-1 팩 변환 툴

Packs the thousands of `game-N.pcm` files of an MSU-1 set into a few large files, so the Pocket opens
one file instead of searching a huge folder. The pack is optional: plain `.pcm` files keep working.
(수천 개의 `game-N.pcm`을 소수의 큰 파일로 묶는 도구입니다. 팩은 선택 사항이며 `.pcm` 그대로도 동작합니다.)

> Tool source: `tools/msupack/main.go` (Go). Build: `GOOS=windows go build -o MSUPackMaker.exe`.
> Windows binary: `tools/MSUPackMaker.exe`. Use only with game files you own.

## How to use / 사용법
1. Copy `MSUPackMaker.exe` into the folder that holds your `game.msu` and `game-1.pcm`, `game-2.pcm`, …
   (`.msu` 와 `-N.pcm` 이 있는 폴더에 exe 를 복사)
2. Double-click it (or run `MSUPackMaker.exe <folder-or-.msu file>` from a terminal).
3. Wait for `Done`, press Enter. A progress bar shows percent, GB written, current track, speed and ETA (first a scan of the folder, which can be slow in a folder with thousands of files).
4. Put the generated files next to the ROM on the SD card (same folder, same base name).
   The core uses the pack automatically; you may delete the `.pcm` files afterwards (keep a backup).

## Output files / 생성 파일
| File | Content |
|---|---|
| `game.msp` | index + music tracks (track number < 1000) |
| `game.ms1` `game.ms2` `game.ms3` | voice / long tracks (track ≥ 1000), a new file starts at track 1000 |

- Each file stays under 2 GiB (no 4 GiB limit), at most 4 files (`.msp` + 3), one track < 1 GiB.
- Tracks are aligned to 4096 bytes. Format v2: 4096 × 8-byte index entries `{offset, size | part<<30}`, entry 0 = `MSUP`, version 2.
- The summary printed at the end lists music/voice track counts and sizes; a `WARNING` means some tracks did not
  fit and are **not** in the pack (they will not play).
- The `game.msu` file is not modified. A 0-byte `.msu` is fine for games that only use the audio tracks; games whose patch streams data from the `.msu` (for example the Chrono Trigger FMV intro patch) need the real `.msu` file.

## Notes / 참고
- Test aid: a `maxtrack.txt` next to the exe containing a number N packs only tracks 1..N.
- Known issue (not fully understood): in some folders with thousands of files MSU-1 did not start while the same
  files worked in another folder. Moving the game into its own folder helped in tests.
