# Genesis MD+ for Analogue Pocket (한국어)

Analogue Pocket용 메가드라이브/제네시스 코어입니다. **MD+ CD 음원**(MegaSD 방식
cue + wav)과 **세이브 스테이트(Memories)** 를 지원합니다.

RndMnkIII의 [Analogizer Genesis 코어](docs/README_upstream.md)를 바탕으로 했고,
그 코어는 ericlewis의 openFPGA Genesis(MiSTer Genesis 포팅, fpgagen 기반)를
바탕으로 합니다. Analogizer 기능은 그대로 켜져 있습니다.

버전: **0.8** (테스트 릴리스)

## 기능

- **MD+ CD 음원**: MD+ 패치 롬이 SD 카드의 `.cue` + `.wav`를 바로 읽어 CD 음질로
  재생합니다. 변환 툴이 필요 없습니다.
  - 44.1kHz 16비트 스테레오 WAV (WAVE_FORMAT_EXTENSIBLE 포함)
  - 1회 재생 / 반복, `REM LOOP` 반복 지점, `REM NOLOOP`, 페이드, 일시정지/재개,
    MD+ 볼륨 명령
  - 곡마다 앞부분 약 1.5초를 게임 중 뒤에서 PSRAM에 미리 읽어 두어, 캐시된 곡은
    지연 없이 시작
  - 롬을 불러오자마자 MD+ 준비를 뒤에서 시작하며 게임을 멈추지 않음
- **세이브 스테이트 (Pocket Memories)**: Pocket 메뉴에서 저장/불러오기.
  불러오면 MD+ 곡이 저장한 지점부터 이어서 재생됩니다.
- 원본 코어의 기능(Analogizer 영상/SNAC, SVP, 매퍼 등)은 모두 유지.

## 설치

1. 릴리스 zip의 `Assets`, `Cores`, `Platforms` 폴더를 SD 카드 최상위에 복사합니다.
2. 롬은 평소처럼 `Assets/genesis/common/`에 넣습니다.

## MD+ 사용법

1. **MD+ 패치 롬**, **`.cue`**, 모든 **`.wav`** 파일을 `Assets/genesis/common/`
   아래 같은 폴더에 넣습니다.
2. `.cue` 파일 이름을 롬과 같게 바꿉니다.
   `Phantasy Star IV.md` -> `Phantasy Star IV.cue`
3. Pocket 메뉴에서 롬을 불러옵니다. cue가 없는 일반 롬은 평소대로 실행되고
   MD+는 저절로 꺼집니다.

메뉴 **MD+ Audio**: `On 100%` / `75%` / `50%` / `25%` / `Off`
(다음에 롬을 불러올 때 적용)

참고
- 가지고 있는 롬 버전에 맞는 MD+ 패치를 쓰세요. 한글 등 번역 롬은 그 번역판용
  패치가 필요합니다.
- 게임을 막 시작한 뒤 몇 초 동안은 Pocket이 코어의 SD 요청에 늦게 응답해서 첫
  곡이 늦게 나올 수 있습니다. 준비 전에 온 음악 명령은 모아 두었다가 준비되면
  재생합니다.
- SRAM 창은 0x200000-0x2FFFFF로 제한됩니다(MD+ 패치가 0x300000 이후에 드라이버를
  넣기 때문).

## 세이브 스테이트

- Pocket 메뉴 -> Memories -> 저장 / 불러오기.
- 다음 수직 블랭크(VBlank) 때 작은 68000 루틴이 상태를 저장하므로, 게임이
  VBlank 인터럽트를 켜 둔 상태여야 합니다(일반적인 플레이 중에는 항상 켜져 있음).
- 한계
  - 버추어 레이싱(SVP)은 지원하지 않습니다(코어가 Pocket에 미지원으로 알림).
  - 배터리 세이브 RAM은 상태에 포함되지 않습니다(게임 안 저장 데이터는 유지).
  - 저장 순간 울리고 있던 FM 음은 불러온 직후 잠깐 끊길 수 있습니다.

## 알려진 사항

- 테스트 릴리스입니다. 주로 판타지스타 4(MD+ 패치)로 시험했습니다.
- MD+ 메뉴 자리를 만들기 위해 원본의 "M30 Controllers" 메뉴를 뺐습니다.

## 빌드

Quartus Prime Lite 25.1 (Cyclone V 5CEBA4F23C8). `src/fpga/ap_core.qpf`를 열고
컴파일한 뒤, `output_files/ap_core.rbf`의 각 바이트 비트 순서를 뒤집어
`bitstream.rbf_r`을 만듭니다. 설계는 [docs/TECHNICAL.md](docs/TECHNICAL.md)에
있습니다.

68000 세이브 스테이트 루틴은 `tools/ss_handler.py`로 만듭니다
(`python3 tools/ss_handler.py src/fpga/core/rtl/ss_hrom.sv`).

## 크레딧 / 라이선스

크레딧과 원본 저장소별 라이선스는 [README.md](README.md)의 Credits, License 표를
참고하세요. 이 코어는 GPL-3.0 부분을 포함하므로 **GNU GPL v3.0**으로 배포합니다
(저장소 최상위 `LICENSE`). 각 파일은 원래의 저작권·라이선스 표시를 그대로
유지합니다.

비공식 코어이며 원작자들이 만들거나 지원하는 것이 아닙니다. 롬, BIOS, MD+ 음원은
포함되어 있지 않습니다.
