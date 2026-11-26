# SNES MSU-1 + 세이브스테이트 0.8.6 (`Moongom.SNES_MSU_SS`) — 0.8 개선판

**0.8.5**는 0.8의 개선판이며 0.8을 대체합니다(코어 폴더는 같은 `Moongom.SNES_MSU_SS`). MSU-1 음질이 깨끗한 R1 계열([`src/`](src/))에 MiSTer SNES 세이브스테이트를 옮겨 넣었습니다. 비트스트림은 [Releases](https://github.com/moongommoongom/Moongom/releases)에만 있습니다. 기술 메모: [`docs/0.8.5.md`](docs/0.8.5.md)(영문).

**0.8.6**은 0.8.5의 버그 수정판입니다. `snes_main.rev`(일반 게임, S-DD1, BS-X)에서 게임 내 세이브(`.sav`)가 다시 유지됩니다. 0.8.5에서는 코어를 껐다 다시 켜면 세이브가 사라졌습니다. 바뀐 파일은 `snes_main.rev` 하나입니다.

- **세이브스테이트:** 일반 게임과 **SA-1, Super FX, CX4, DSP-n, S-DD1** 게임(NTSC·PAL). **SPC7110**은 실험 기능입니다(그래픽 압축을 푸는 도중에 저장하면 불러온 뒤 그래픽이 깨질 수 있음). BS-X, OBC1 게임은 세이브스테이트가 없습니다. 저장은 Analogue 버튼 + 위, 불러오기는 Memories 메뉴입니다.
- **MSU 음악 위치 저장:** 트랙, 재생 위치(약 0.4초 단위), 볼륨, 반복 여부가 저장되고, 불러오면 그 위치부터 이어서 재생합니다. 음성 클립은 저장되지 않습니다.
- **MSU-1 배경음 + 음성 팩**(FF6)이 NTSC 메인 비트스트림에서 함께 재생되고, 재생 중에도 세이브스테이트를 불러올 수 있습니다.
- 코어 폴더 하나에 **비트스트림 8개**(APF 최대치)가 있고, 로더가 ROM 헤더를 읽어 자동으로 고릅니다.

| 비트스트림 | 게임 |
|---|---|
| `snes_main.rev` | NTSC 일반 게임, S-DD1, BS-X (FF6 음성 팩, 라이트건) |
| `snes_spc.rev` | SPC7110 |
| `snes_pal.rev` | PAL 일반 게임, PAL CX4 / DSP-n |
| `snes_cx4dsp.rev` | NTSC CX4 / DSP-n (록맨 X2/X3, 슈퍼 마리오 카트, 파일럿윙스 등) |
| `snes_sa1.rev` / `snes_sa1p.rev` | SA-1 NTSC / PAL |
| `snes_gsu.rev` / `snes_gsup.rev` | Super FX NTSC / PAL |

- 칩 비트스트림에는 음성 스트림, MSU-1 데이터 트랙, 라이트건이 없습니다(세이브스테이트 회로 자리). PAL 비트스트림도 칩 빌드라 PAL 슈퍼스코프 게임은 라이트건이 안 됩니다.
- **테스트 현황:** FF6 배경음 + 음성과 세이브스테이트는 개발 중 실기에서 확인했습니다(R1SS 테스트 빌드). 칩 게임과 SPC7110 세이브스테이트는 0.8.5에서 새로 들어가 아직 테스트가 적습니다. 문제는 이슈로 알려주세요.
- MSU-1 음원은 MSUPackMaker로 `.msp` / `.ms1` 팩으로 묶어 쓰세요(Windows: `tools/MSUPackMaker.exe`, macOS: `tools/MSUPackMaker_macOS`, [`docs/MSUPackMaker.ko.md`](docs/MSUPackMaker.ko.md)).
- 비공식 빌드이며 원작자들과 관계없습니다. AI(Claude, Anthropic)의 도움을 받아 제작했고 저장소 주인이 방향을 정하고 테스트했습니다.
- **ROM, BIOS, DSP 펌웨어 덤프, MSU-1 음원은 포함되어 있지 않습니다.** 게임 파일은 직접 준비하세요.
- GPLv3(`LICENSE`, `CREDITS.md`). 빌드: Quartus Prime 25.1 Lite, 저장소 루트에서 `quartus_sh -t generate.tcl <variant>`(변형 목록은 [`docs/0.8.5.md`](docs/0.8.5.md)), `.rbf`를 비트 반전해 `.rev`로 만듭니다. 패키지 파일: `pkg/pocket/Cores/Moongom.SNES_MSU_SS/`.

---

# Analogue Pocket용 SNES (MSU-1) — 비공식 수정 빌드

agg23의 openFPGA SNES 코어(openfpga-snes 0.4.4)에 **MSU-1**(CD 음질 음악 트랙과 데이터 스트리밍), CPU 터보(Off/On),
비프음 제거를 추가한 **비공식 실험용** 수정판입니다. **현재 버전: Moongom 0.5** (이전 19번 빌드 계열). agg23, srg320, MiSTer 프로젝트가 만들었거나 보증하거나 지원하는
것이 아닙니다. 이 빌드의 문제를 그들에게 보고하지 마세요. 이 수정판은 AI의 도움을 받아 제작되었습니다.
([English](README.md))

## 구성
코어 폴더는 `Cores/Moongom.SNES_MSU` 하나입니다. 안에 비트스트림이 여러 개 있고, 로더가 ROM 헤더를 읽어 자동으로 고릅니다
(모든 칩이 FPGA에 함께 들어가지 않습니다. ALM 약 96%).

| 비트스트림 | 칩 | 선택되는 게임 |
|---|---|---|
| `snes_main.rev` / `snes_pal.rev` | SA-1, Super FX(GSU), S-DD1, MSU-1 | 대부분의 게임, SA-1/GSU/S-DD1 게임 |
| `snes_spc.rev` | SPC7110, BSX, S-DD1, MSU-1 | SPC7110, BSX |
| `snes_cx4dsp.rev` / `snes_cx4dsp_pal.rev` | CX4, DSP-n(1~4), ST010, Super FX, MSU-1 | 록맨 X2/X3, 슈퍼 마리오 카트, 파일럿윙스 등 |

NTSC/PAL은 ROM 지역으로 정해집니다. 자동 선택(`loader.bin`)은 모든 게임에서 검증되지는 않았습니다.

## 다운로드 / 설치
[Releases](https://github.com/moongommoongom/Moongom/releases)에서 `Moongom_SNES_MSU1_core_r1.zip`을 받습니다(저장소에는 소스만 있고 `.rev` 비트스트림은 없습니다). `Cores/Moongom.SNES_MSU` 폴더를 Pocket SD카드의 `Cores/` 폴더에 복사합니다(예전 `Moongom.SNES_MSU*` 폴더는 지우세요).

## MSU-1 사용
게임 파일은 직접 준비해야 합니다. ROM과 같은 폴더에 이름을 맞춰 둡니다.

    game.sfc   game.msu(비어 있어도 됨)   game-1.pcm   game-2.pcm ...

PCM 형식: `MSU1` 헤더, 32비트 루프 지점, 이어서 44.1 kHz 16비트 리틀엔디언 스테레오.
**ROM, PCM 음원 등 저작권이 있는 게임 데이터는 포함되어 있지 않으며 이 코어와 함께 배포해서는 안 됩니다.**

### 팩 파일 (선택)
`.pcm`이 수천 개인 게임(예: FF6)은 [MSUPackMaker](docs/MSUPackMaker.ko.md)로 `game.msp`(음악)와
`game.ms1`…(음성)로 묶어 쓸 수 있습니다. 4 GiB 제한이 없고, 음악과 음성을 따로 동시에 재생합니다.

## CPU 터보
Off / On(마스터 클럭 6, FastROM 속도). 예전의 Max 단계는 없앴습니다. SA-1과 S-DD1 게임에서는 자동으로 꺼집니다.
터보를 켜면 멈추는 게임이 있을 수 있으니 그럴 때는 Off로 두세요.

## 알려진 문제 / 상태
- 실험 단계입니다. 주로 환상의 전설(Tales of Phantasia)과 FF6 MSU-1 팩으로 테스트했고 모든 게임을 확인하지는 않았습니다.
- CPU 터보 멈춤 문제는 원인을 완전히 찾지 못했습니다.
- SA-1+GSU+S-DD1과 CX4+DSP-n은 한 비트스트림에 들어가지 않아서 같은 코어 폴더 안의 별도 비트스트림입니다.
- 최신 빌드의 타이밍은 깨끗하지 않습니다. 주 클럭 setup 여유가 NTSC 메인 −0.14 ns, CX4/DSP NTSC −0.81, CX4/DSP PAL −0.27, SPC −0.69로 조금 음수입니다(PAL 메인은 +0.17로 충족). hold는 모두 충족합니다. 모든 변형을 하드웨어에서 확인하지는 않았습니다.
- 파일이 수천 개인 폴더에서 MSU-1이 시작되지 않는 경우가 있었습니다(원인 불명). 게임을 별도 폴더에 두면 해결된 적이 있습니다.

## 라이선스와 소스
이 작업은 GPLv3 소프트웨어의 수정판이며 **GNU GPL v3**로 배포됩니다(`LICENSE` 참고). 소스 전체는 이 저장소에 있고
`patches/`에 업스트림 대비 패치, `tools/`에 변환 도구(`rbf_to_rev.py`, `MSUPackMaker.exe`와 소스), `docs/`에 문서와 개발 일지가 있습니다. 빌드: Quartus Prime 25.1 Lite, `quartus_sh -t generate.tcl <variant>`(`ntsc`/`pal` = CX4·DSP-n, `ntsc_sa1gsu`/`pal_sa1gsu` = SA-1·GSU·S-DD1, `ntsc_spc` = SPC7110·BSX),
이어서 `python3 tools/rbf_to_rev.py ap_core.rbf out.rev`. 출처 표기는 `CREDITS.md`를 보세요.
