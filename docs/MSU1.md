# MSU-1 support (experimental)

## 파일 배치
ROM과 같은 폴더(예: /Assets/snes/common/)에 둡니다.
    game.sfc / game.msu / game-1.pcm / game-2.pcm ...
코어 메뉴에서 ROM을 로드하면 MSU 데이터/오디오 슬롯 경로가 ROM 경로에서 자동 유도됩니다.
(1GB 미만 팩 대상. 트랙/데이터는 SD에서 APF 데이터슬롯 읽기로 스트리밍.)

## 빌드
    quartus_sh -t generate.tcl ntsc     # -> output_files/*.rbf
    quartus_sh -t generate.tcl pal
    python3 tools/rbf_to_rev.py ap_core_ntsc.rbf snes_main.rev
    python3 tools/rbf_to_rev.py ap_core_pal.rbf  snes_pal.rev
.rev 파일을 Cores/agg23.SNES/ 에 복사 (SPC/SDD1 variant 는 USE_MSU=0 유지).

## 미검증 가정
- 0x0192 후 데이터슬롯 크기 테이블 갱신 여부 (없으면 트랙 크기 0=없음 처리)
- 0x0190 이 슬롯 0 에서 /Assets/... 전체 경로를 돌려주는지
- 브릿지 바이트 순서, 타겟 커맨드 지연 vs 오디오 버퍼, FPGA 리소스/타이밍
- Quartus 컴파일·시뮬레이션 하지 않음
