# Analogue Pocket용 SNES (MSU-1) — 비공식 수정 빌드

agg23의 openFPGA SNES 코어(openfpga-snes 0.4.4)에 **MSU-1**(CD 음질 음악 트랙과 데이터 스트리밍), CPU 터보(Off/On),
비프음 제거를 추가한 **비공식 실험용** 수정판입니다. agg23, srg320, MiSTer 프로젝트가 만들었거나 보증하거나 지원하는
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
