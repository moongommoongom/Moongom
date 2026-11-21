# MSUPackMaker — MSU-1 팩 변환 툴

수천 개의 `game-N.pcm` 파일을 소수의 큰 파일로 묶는 도구입니다. 팩을 쓰면 Pocket이 거대한 폴더를 뒤지지 않고
큰 파일 몇 개만 열면 됩니다. 팩은 선택 사항이며 `.pcm` 파일 그대로도 동작합니다.
([English](MSUPackMaker.md))

> 소스: `tools/msupack/main.go` (Go). 빌드: `GOOS=windows go build -o MSUPackMaker.exe`
> Windows 실행 파일: `tools/MSUPackMaker.exe`. macOS 실행 파일: `tools/MSUPackMaker_macOS`(Apple Silicon·Intel 공용,
> macOS 11 이상, 빌드 방법은 `tools/msupack/make_universal.py`). 본인이 가진 게임 파일에만 사용하세요.

## 사용법
1. `MSUPackMaker.exe`를 `game.msu`와 `game-1.pcm`, `game-2.pcm`, … 이 있는 폴더에 복사합니다.
2. 더블클릭하거나 터미널에서 `MSUPackMaker.exe <폴더 또는 .msu 파일>`로 실행합니다.
3. 진행 상황(퍼센트, 기록한 GB, 현재 트랙, 속도, 남은 시간)이 막대로 표시됩니다. 먼저 폴더 스캔이 있고, 파일이 수천 개인 폴더에서는 시간이 걸릴 수 있습니다. `Done`이 나오면 Enter를 눌러 닫습니다.
4. 생성된 파일을 SD카드의 ROM과 같은 폴더(같은 기본 이름)에 넣습니다. 코어가 팩을 자동으로 사용합니다.
   이후 `.pcm` 파일은 지워도 되지만 백업은 보관하세요.

## macOS
1. `MSUPackMaker_macOS`를 `game.msu`와 `game-N.pcm` 파일이 있는 폴더에 복사하고 더블클릭합니다.
   터미널 창이 열리고 Windows판과 같은 진행 상황이 표시됩니다. `Done`이 나오면 Enter를 누릅니다.
2. 처음 실행할 때: 서명되지 않은 프로그램이라 macOS가 한 번 막습니다.
   macOS 15 이상: 시스템 설정 > 개인정보 보호 및 보안 > **그래도 열기**를 누른 뒤 다시 엽니다.
   macOS 14 이하: Control-클릭 > 열기 > 열기. 또는 터미널에서 `xattr -d com.apple.quarantine MSUPackMaker_macOS`.
3. Finder에서 `.msu`를 프로그램 위로 끌어다 놓는 방식은 안 됩니다. 게임 폴더에 넣고 실행하거나 터미널에서
   `./MSUPackMaker_macOS /경로/game.msu`로 실행합니다(폴더를 주면 그 안의 `.msu`를 모두 처리).

## 생성 파일
| 파일 | 내용 |
|---|---|
| `game.msp` | 인덱스 + 음악 트랙(트랙 번호 1000 미만) |
| `game.ms1` `game.ms2` `game.ms3` | 음성/긴 트랙(트랙 번호 1000 이상). 1000번부터 새 파일로 시작 |

- 파일 하나는 2 GiB 미만이라 4 GiB 제한이 없습니다. 파일은 최대 4개(`.msp` + 3개), 트랙 하나는 1 GiB 미만입니다.
- 트랙은 4096바이트 단위로 정렬됩니다. v2 형식: 8바이트 인덱스 4096개 `{offset, size | part<<30}`, 0번 항목은 `MSUP`, 버전 2.
- 끝에 출력되는 요약에 음악/음성 트랙 수와 용량이 나옵니다. `WARNING`이 나오면 일부 트랙이 팩에 들어가지 못한 것이고
  그 트랙은 재생되지 않습니다.
- `game.msu` 파일은 수정하지 않습니다. 음악 트랙만 쓰는 게임은 0바이트여도 괜찮지만, 패치가 `.msu`에서 데이터를 읽는 게임(예: 크로노 트리거 인트로 영상 패치)은 실제 `.msu` 파일이 필요합니다.

## 참고
- 테스트용: exe 옆에 숫자 N이 적힌 `maxtrack.txt`를 두면 1~N번 트랙만 묶습니다.
- 알려진 문제(원인 불명): 파일이 수천 개인 폴더에서 MSU-1이 시작되지 않았는데 같은 파일이 다른 폴더에서는 동작한 경우가
  있었습니다. 테스트에서는 게임을 별도 폴더로 옮기면 해결된 적이 있습니다.
