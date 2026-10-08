# 호혈사일족 / Power Instinct — MiSTer FPGA 코어

> [!IMPORTANT]
> **취미로 만든 프로젝트입니다.**
> 개인이 순전히 취미로 만든 코어입니다. 버그 제보는 반갑게 받지만, **대응할 수도 있고 못 할 수도 있습니다.**
> 업데이트나 지원을 약속하지 않습니다.
>
> **이 코드로 이어서 개발하실 때는 꼭 출처를 남겨 주세요.**
> 이 저장소를 바탕으로 수정하거나 다른 코어를 만드실 때 출처(이 저장소 링크)를 밝혀 주시면 정말 감사하겠습니다.
> 라이선스(GPL-3.0)에 따라 원래의 저작권 표시와 이 프로젝트가 감사를 전한 분들의 출처도 함께 유지해 주세요.

1993 년 Atlus 가 내놓은 대전 격투 게임 **호혈사일족 (Gouketsuji Ichizoku, 해외판 Power Instinct)** 을
MiSTer (DE10-Nano) 에서 돌리는 FPGA 코어입니다.

원래 기판은 NMK 가 제조한 **OS93095** 입니다.

- 메인 CPU: Motorola 68000 @ 12 MHz
- 사운드 CPU: Zilog Z80 @ 6 MHz
- 사운드: Yamaha YM2203 (FM 3 채널 + SSG 3 채널) 1 개, OKI M6295 ADPCM 2 개, 그리고 둘의 샘플 ROM 뱅크를 바꾸는 NMK112
- 비디오: NMK 커스텀 칩 (NMK902/903/901/111/005, 스프라이트 NMK008/NMK009),
  텍스트 레이어, 스크롤 배경 레이어, 스프라이트
- 화면: 320×224, 픽셀 클럭 7 MHz, 448×278 토털, 약 56.2 Hz

이 코어는 MAME 의 동작을 FPGA 로 옮기는 데서 멈추지 않고, **원래 기판이 그 동작을 어떻게 만들었는지를
하드웨어 구조로 다시 세우는 것**을 목표로 했습니다. 예를 들어 비디오 타이밍, 인터럽트, 스프라이트 DMA 시점,
레이어 믹싱은 MAME 의 상수를 박아 넣은 것이 아니라 ROM 세트에 들어 있는 PROM 세 개
(`20.u54`, `21.u71`, `22.u81`) 를 FPGA 안에서 실제로 읽어 만들어 냅니다.

## 지원 게임

| MAME 세트 | 공식 명칭 | 상태 |
|---|---|---|
| `powerins` | Power Instinct (USA) | 실기에서 플레이 가능. 부팅·어트랙트·대전·P1/P2 입력·flip screen·사운드 확인. 실기 캡처 대부분이 MAME 와 픽셀 단위로 동일 |
| `powerinsj` | Gouketsuji Ichizoku (Japan) | 실기에서 부팅과 일본어 화면 확인. USA 판과 같은 하드웨어 경로를 쓴다 |
| `powerinspu` | Power Instinct (USA, prototype) | 실기에서 스토리 화면과 대전 데모까지 확인. 68000 ROM 두 개만 다르고 나머지는 양산판과 같다 |
| `powerinspj` | Gouketsuji Ichizoku (Japan, prototype) | 위와 같음 |

부트렉 (`powerinsa`, `powerinsb`, `powerinsc`) 은 기판 구성이 달라(사운드 CPU 없음, 입출력 맵,
스프라이트 형식) 지원하지 않습니다. 이 코어는 MiSTer 전용이며 Analogue Pocket 판은 없습니다.

ROM 은 포함되어 있지 않습니다. MAME 0.289 기준으로 정상인 `powerins.zip` (일본판은 `powerinsj.zip` 와
부모 `powerins.zip`) 을 직접 준비해 주셔야 합니다.

## 설치 — ROM 만 넣으면 됩니다

이 배포본의 `SD/` 폴더는 MiSTer SD 카드의 루트(`/media/fat/`)와 같은 구조입니다.
**`SD/` 안의 내용을 SD 카드 루트에 그대로 복사**하면 됩니다.

```
SD/_Arcade/cores/PowerIns.rbf                 코어 (빌드된 비트스트림)
SD/_Arcade/_Kaze's Cores/<게임 이름>.mra    게임 목록 (공식 명칭)
SD/games/mame/필요한_ROM.txt               넣어야 할 ROM zip 목록
```

1. `SD/` 의 내용을 SD 카드 루트에 복사합니다. 기존 파일은 덮어써도 됩니다.
2. 직접 마련한 MAME ROM 세트 zip 을 SD 카드의 `/games/mame/` 에 넣습니다.
   어떤 zip 이 필요한지는 `필요한_ROM.txt` 에 게임별로 적혀 있습니다.
   zip 은 MAME 세트 이름 그대로 두고, 압축을 풀지 않습니다.
3. MiSTer 메뉴에서 **Arcade → `_Kaze's Cores`** 로 들어가 게임을 고릅니다.

- `.rbf` 를 직접 실행하지 말고 `.mra` 로 실행하세요. ROM 로드와 DIP·OSD 기본값이
  `.mra` 에 들어 있습니다.
- 폴더 이름이 `_` 로 시작해야 MiSTer 메뉴에 보입니다. 이름을 바꾸지 마세요.

## 빌드 방법

필요한 것: **Intel Quartus Prime Lite Edition 17.0** (MiSTer 코어 표준 버전). 다른 버전에서도
합성은 될 수 있지만 검증한 버전은 17.0 입니다.

명령줄에서 빌드하려면:

```sh
cd projects/atlus/powerins/targets/mister
quartus_sh --flow compile PowerIns
```

결과물은 `projects/atlus/powerins/targets/mister/output_files/PowerIns.rbf` 입니다. Quartus GUI 로
`PowerIns.qpf` 를 열고 Compile 을 눌러도 같습니다.

- 디렉터리 구조를 그대로 유지해야 합니다. 프로젝트 파일이 `../../../../../third_party`,
  `../../../../../platforms/mister/sys` 를 상대 경로로 찾습니다.
- `build_id.v` 는 빌드 시작 때 `platforms/mister/sys/build_id.tcl` 이 자동으로 만듭니다.
- Quartus 17.0 의 fitter 가 드물게 내부 오류로 죽으면서도 정상 종료 코드를 남기는 경우가 있습니다.
  `.rbf` 의 생성 시각과 로그 끝부분을 확인하고, 그런 경우 한 번 더 빌드하면 됩니다.

직접 빌드한 `.rbf` 는 `SD/_Arcade/cores/` 의 같은 이름 파일과 바꿔 넣으면 됩니다.

## 디렉터리 구성

원래 저장소의 상대 경로를 그대로 유지했습니다. 빌드에 실제로 쓰이는 파일만 들어 있습니다.

```
LICENSE                              GPL-3.0 전문
README.md                            이 문서
SD/                                  SD 카드 루트에 복사할 설치 파일 (RBF, MRA, ROM 목록)
projects/atlus/powerins/
  rtl/                               기판 하드웨어 RTL (68000 버스, PROM 구동 타이밍, 레이어·스프라이트, SDRAM·캐시, 사운드 RTL)
  integration/                       ROM 다운로드 경로 (플랫폼 중립 어댑터)
  targets/mister/                    MiSTer 최상위 (.qpf .qsf .sdc .sv files.qip, PLL)
third_party/                         외부 IP (아래 "감사의 말과 사용한 코드" 참조)
platforms/mister/sys/                MiSTer framework (Template_MiSTer)
```

소스 주석에는 개발 중에 쓴 내부 문서 번호(예: `D18`, `MEASUREMENTS 158`, `docs/...`)와
측정 기록이 그대로 남아 있습니다. 해당 개발 문서와 측정·분석 도구는 이 배포본에 포함하지
않았습니다. 주석은 설계 근거를 남기려는 것이고, 빌드에는 영향이 없습니다.

## 작업 내역

### 2026-10-08 — v0.9.1

- **OSD 설정 저장 유지.** 이전에는 `Save settings` 로 저장해도 다음 실행 때 코어가 `.mra` 기본값을 다시 올려 저장값을 덮어썼습니다(MiSTer 는 저장 파일을 ROM 로드 전에 읽고, 코어가 보낸 status 로 128비트 전체를 교체합니다). 이제 저장된 설정이 있으면 기본값을 올리지 않습니다. 실기에서 저장 파일 값이 화면에 반영되는 것을 확인했습니다.

### 진행 경과

| 날짜 | 내용 |
|---|---|
| 2026-09-15 | MAME / FBNeo 소스 조사, 메모리 맵·클럭·PROM 해석, 첫 RTL. 시뮬레이션에서 부팅 RAM CHECK 화면이 MAME 와 일치 |
| 2026-09-15 | IRQ 래치 구조 수정 (프레임당 IRQ4 한 번). **실기 첫 화면** — WARNING·FBI 화면이 MAME 와 동일 |
| 2026-09-15 | 68000 프로그램 ROM 캐시. 시뮬레이션의 부팅 타이밍이 MAME 와 맞음 |
| 2026-09-15 | 스프라이트 (DMA, 리스트 순회, 2 페이지 프레임 저장). ATLUS 로고와 어트랙트 대전 장면이 실기에서 MAME 와 픽셀 동일 |
| 2026-09-15 | 사운드 보드 (Z80 + YM2203 + M6295 ×2 + NMK112) 연결, 실기에서 소리 출력 |
| 2026-09-15 | flip screen 구현, 사운드 믹스 스케일 1차 조정 |
| 2026-09-16 | 일본판 `powerinsj` 세트 추가, 실기 부팅 확인 |
| 2026-10-06 | 프로토타입 `powerinspu` / `powerinspj` 세트 추가, 실기에서 대전 데모까지 확인 |
| 2026-09-16 | 실기 검증: flip screen (캡처 30 장 전부 MAME 와 같은 그림), P1 입력 전부, P2 입력, 30 분 연속 어트랙트 (멈춤 없음, 27 분 시점 프레임이 MAME 와 픽셀 동일) |
| 2026-09-16 | 시뮬레이션에 실제 Z80 을 붙여 사운드 프로그램이 MAME 와 같은 버스 트래픽을 내는 것을 확인. 소스별 음량을 MAME 와 측정 비교해 믹스 보정 |
| 2026-09-16 | M6295 샘플 바이트가 늦게 도착할 때 칩 클럭을 멈추는 구조 추가 |

### 블록별 구현

- **메인 CPU / 버스** — fx68k 를 48 MHz 에서 1/4 분주해 정확히 12 MHz 로 돌립니다. 메모리 맵은 MAME
  `powerins_map` 을 그대로 따랐고, 미매핑 읽기는 MAME 와 같이 0 을 돌려줍니다. 프로그램 ROM 은 SDRAM 에
  두고 16,384 엔트리 워드 캐시를 앞에 붙여, 실제 기판의 마스크 ROM 대비 늦어지는 시간을 줄였습니다.
  쓰기는 즉시 응답해 불필요한 wait state 를 없앴습니다.
- **비디오 타이밍과 인터럽트 (PROM 구동)** — 수평 카운터는 `20.u54` 를, 수직 카운터는 `21.u71` 을 매 스텝
  읽어 표시 구간·동기·라인 끝 신호·IRQ 레벨·스프라이트 DMA 트리거를 얻습니다. 그 결과 H 토털 448,
  V 토털 278, 표시 320×224, 수평 15.625 kHz / 수직 56.205 Hz 가 PROM 에서 저절로 나옵니다. IRQ 는
  트리거 에지에서 IPL 레벨을 래치하고 IACK 에서 지우는 구조로, 프레임당 IRQ1/2/3/4 가 PROM 이 정한 라인에서
  발생합니다.
- **레이어 믹서 (`22.u81`)** — MAME 는 이 PROM 을 로드만 하고 우선순위는 코드로 정합니다. 이 코어는 PROM
  내용을 그대로 룩업 테이블로 써서 텍스트 / 스프라이트 / 배경 중 어느 픽셀을 낼지와 팔레트 페이지를 고릅니다.
  PROM 32 바이트의 모양 (출력 enable 3 비트 중 정확히 하나만 0) 에서 주소 핀 배선을 역으로 추론했고, 이
  해석으로 만든 골든 모델이 MAME 91 프레임과 픽셀 단위로 일치했습니다.
- **타일 레이어** — 텍스트 (64×32 타일, 열 우선) 와 스크롤 배경 (페이지 스캔, 타일 뱅크 레지스터) 을 한
  라인 앞서 그리는 핑퐁 라인버퍼 두 개로 구현했습니다. 원판은 픽셀마다 마스크 ROM 을 직접 읽지만 MiSTer 에서는
  SDRAM 을 여러 블록이 나눠 써야 하기 때문에 택한 구조입니다.
- **스프라이트** — VBlank 의 DMA 가 스프라이트 RAM 을 복사하고, 리스트 순회기가 엔트리를 읽어 두 장의
  프레임 페이지 중 하나에 그리며, DMA 마다 페이지를 바꿉니다. 같은 위치에서는 뒤 엔트리가 위에 그려집니다.
- **flip screen** — DIP 의 flip 을 켜면 세 레이어 모두 거울 좌표로 읽어 화면이 180 도 돌아갑니다. 실기에서
  MAME 와 같은 그림이 나오는 것을 확인했습니다.
- **사운드** — T80 Z80 @ 6 MHz (두 위상의 클럭 enable 로 정확히), jt03 YM2203 @ 1.5 MHz, jt6295 ×2 @ 4 MHz (PIN7 low),
  NMK112 뱅크 스위치 (MAME 의 장치 동작을 새 RTL 로 작성). Z80 프로그램은 BRAM 에, M6295 샘플은 SDRAM 에서
  전용 캐시를 거쳐 읽습니다. 메모리 중재기는 샘플 페치를 최우선으로 둡니다.
- **믹스** — 각 칩의 출력 스케일을 하나의 기준으로 맞춘 뒤 MAME 의 라우팅 게인 (YM2203 2.0, M6295 각 0.15,
  모노) 을 적용합니다. SSG 는 DC 성분을 제거합니다. 이 비율은 시뮬레이션에서 소스별 RMS 를 MAME 렌더와
  비교해 보정했고, 보정 후 FM −0.03 dB, SSG +0.01 dB, M6295 +0.00 dB, 전체 +0.01 dB 차이로 맞췄습니다.
- **OSD** — 화면비, Scandoubler, DIP, OSD 열 때 일시정지, Service / Test 스위치, 패드의 Pause 버튼.
  디버그 페이지에서 레이어별 끄기와 이전 믹스 레벨 비교를 할 수 있습니다.

### 풀어낸 문제와 정확도에 관한 메모

- **MAME 의 IRQ4 위상.** MAME 의 인덱싱 식은 주석과 달리 IRQ4 를 화면 라인 28 에서 냅니다 (계산과 MAME 실행
  측정이 66 라인 차이로 정확히 일치). 이 코어는 PROM 이 정한 라인 240 을 따릅니다.
- **게임 진행의 분기.** 시뮬레이션과 MAME 의 게임 진행이 갈라지는 원인을 추적해 보니, 스타트 버튼을 누를 때
  IRQ4 카운터 값을 난수로 쓰는 루틴이었습니다. 입력 위상만 맞추면 코인 → 캐릭터 선택 → 월드맵 → 대전까지
  난수 호출과 사운드 명령이 MAME 와 하나도 다르지 않게 진행됩니다. RTL 결함이 아니었습니다.
- **M6295 샘플 페치 기한.** 샘플 바이트가 SDRAM 에서 늦게 오면 jt6295 는 틀린 바이트를 그대로 받습니다.
  대전 장면을 포함한 시뮬레이션에서 1,310 만 번 중 3 번 늦었고, 칩 클럭 enable 을 캐시가 바이트를 가질 때까지
  멈추는 구조로 바꿔 구조적으로 0 이 되게 했습니다 (대가는 0.1 % 정도 느려지는 칩 클럭으로, 반음의 1/60 수준).
- **실기 캡처 대조.** MiSTer 출력에 감마 1.1 이 걸려 있다는 것을 찾아 기준 이미지에 같은 감마를 적용한 뒤
  비교했습니다. 남는 차이 1–2 장은 HUD 를 표시 도중에 쓰는 프레임으로, 원판·MAME 의 그리기 시점 차이입니다.
- **팔레트·스크롤 레지스터 셀프 테스트, YM2203 I/O 포트** 등 소스만으로 애매한 부분은 MAME 를 실행해 실제
  접근 횟수를 세어 판단했습니다.

## 감사의 말과 사용한 코드

먼저 **MAME 팀**에 깊이 감사드립니다. 이 코어의 메모리 맵, 클럭, 입력·DIP 정의, 스프라이트·타일 포맷,
사운드 라우팅, NMK112 의 동작, 그리고 기판 레이아웃 노트까지 모두 MAME 소스에서 배웠습니다. MAME 를 직접
실행해 얻은 화면·소리·버스 트래픽이 이 코어를 검증하는 골든 레퍼런스였습니다. 수십 년에 걸친 보존 작업이
없었다면 이 코어는 시작조차 할 수 없었을 것입니다.

- MAME: <https://www.mamedev.org/> · <https://github.com/mamedev/mame>

### 빌드에 포함된 서드파티 코드

| 이름 | 용도 | 저자 | 라이선스 | 출처 (링크 + 커밋) | 사용한 파일 | 수정 여부 |
|---|---|---|---|---|---|---|
| fx68k | 메인 CPU (68000) | Jorge Cwik | GPL-3.0 | <https://github.com/ijor/fx68k> `0602ee4627b10f301298f2673d826cdd6baa9327` | `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem` | `fx68k.sv` 에 읽기 전용 디버그 포트 `dbg_d7` 추가 (동작 변경 없음, 파일 안 `// LOCAL:` 표시). 나머지는 원본 그대로 |
| T80 | 사운드 CPU (Z80) | Daniel Wallner, MiSTer-devel (Sorgelig 외) | BSD-3-Clause 계열 | <https://github.com/MiSTer-devel/T80> `830fd0315f0af5cdbcb0e703f1cea3ce4e91f538` | `T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`, `T80pa.vhd` | 수정 없음 |
| jt12 (jt03, jt49 포함) | YM2203 (FM + SSG) | Jose Tejada Gomez (jotego) | GPL-3.0 | <https://github.com/jotego/jt12> `4cf1c5b` (jt49 `47301ed`) | `jt03.v` 와 그것이 쓰는 `jt12_*.v`, `jt10*.v`, `jt49*.v` | 있음 — `jt10.v`, `jt10_adpcm_drvA.v`, `jt12_top.v`, `jt12_kon.v`, `jt12_mmr.v`, `jt12_reg.v` 에 디버그 관측용 출력 포트만 추가 (기존 논리 변경 없음, 추가한 모든 줄에 `// LOCAL:` 표시). jt49 는 원본 그대로 |
| jt6295 | OKI M6295 ×2 | Jose Tejada Gomez (jotego) | GPL-3.0 | <https://github.com/jotego/jt6295> `7d76b0be8cd8f85f3ae741178c9830b20e2071a1` | `jt6295*.v`, `jt12_comb.v` | 수정 없음 |
| MiSTer framework (`sys/`) | MiSTer 하드웨어 인터페이스 (HPS I/O, OSD, 스케일러, HDMI, 오디오) | MiSTer-devel 과 기여자들 | 파일별 (대부분 GPL-2.0+ / GPL-3.0+, 각 파일 헤더 참조) | <https://github.com/MiSTer-devel/Template_MiSTer> @ `54ac838e019d7fa07fbb40677a104cd6620d15c3` (2026-08-17, `sys/` 내용 일치로 식별) | `sys/` 전체 | `sys.tcl` 의 경로 해석 두 줄만 변경 (같은 파일을 지정, 동작 변경 없음) |
| Altera PLL | 48 / 48 / 100 MHz 클럭 생성 | Quartus MegaWizard 생성 | Intel FPGA IP | Quartus 17.0 | `targets/mister/rtl/pll*` | 생성물 |

- **Jorge Cwik** 님, 사이클 단위로 정확한 68000 코어 fx68k 에 감사드립니다. 이 코어의 타이밍 검증은 fx68k 가
  실제 68000 처럼 동작한다는 신뢰 위에 서 있습니다.
- **Daniel Wallner** 님과 **MiSTer-devel** 의 T80 유지보수자분들께 감사드립니다. 수많은 MiSTer 코어에서 검증된
  Z80 덕분에 사운드 CPU 는 고민할 필요가 없었습니다.
- **Jose Tejada Gomez (jotego)** 님께 감사드립니다. jt12 와 jt6295 는 이 코어의 소리 전부입니다.
- **MiSTer-devel** 과 MiSTer 프로젝트의 모든 기여자분들께 감사드립니다.

### 참고한 MAME 소스

MAME 소스는 사실 확인과 동작 이해에 사용했고, RTL 주석에 파일과 줄 번호로 인용해 두었습니다 (기준 커밋
`446356f29ee59b4f2dad4f93408b1aaa33fae926`). NMK112 는 MAME 장치 구현을 읽고 같은 동작을 새 RTL 로
작성했습니다.

| MAME 파일 | 라이선스 | copyright-holders | 참고한 내용 |
|---|---|---|---|
| `src/mame/nmk/nmk16.cpp` | BSD-3-Clause | Mirko Buffoni, Nicola Salmoria, Bryan McPhail, David Haywood, R. Belmont, Alex Marshall, Angelo Salese, Luca Elia | 메인/사운드 CPU 메모리 맵, 클럭, 입력·DIP 정의, 팔레트 포맷, 사운드 라우팅 게인, 스프라이트 DMA, OS93095 기판 레이아웃 노트 |
| `src/mame/nmk/nmk16_v.cpp` | BSD-3-Clause | (위와 같음) | 타일맵 스캔 방식, 스크롤 오프셋, powerins 스프라이트 속성 디코드 |
| `src/mame/nmk/nmk16spr.cpp` | BSD-3-Clause | (위와 같음) | 스프라이트 리스트 포맷, flip 시 좌표 |
| `src/mame/nmk/nmk_irq.cpp` | BSD-3-Clause | Sergio Galiano | H/V 카운터 범위와 타이밍 PROM 인덱싱 (비디오 타이밍 설계 문서에서 참고) |
| `src/devices/machine/nmk112.cpp` | BSD-3-Clause | Alex W. Jackson | NMK112 레지스터, 리셋값, 뱅크 마스크, 테이블 영역 페이징 |
| `src/emu/video/generic.cpp` | BSD-3-Clause | Nicola Salmoria | 스프라이트 타일 그래픽 레이아웃 |
| `src/emu/drawgfx.cpp` | BSD-3-Clause | Nicola Salmoria, Aaron Giles | 스프라이트끼리의 우선순위 (뒤 엔트리가 위) |
| `src/emu/tilemap.cpp` | BSD-3-Clause | Aaron Giles | flip 시 스크롤 계산 |

### 사실 확인에만 쓴 자료 (코드 미사용)

- **FBNeo** (<https://github.com/finalburnneo/FBNeo>, `d_powerins.cpp`, `nmk112.cpp`) — MAME 와 독립적으로
  같은 하드웨어 사실을 말하는지 교차 확인하는 데만 썼습니다. FBNeo 의 코드나 구조는 한 줄도 가져오지 않았습니다.
  FBNeo 개발자분들께도 감사드립니다.
- **Arcade-NMK16_MiSTer** (kuzearcade, <https://github.com/kuzearcade/Arcade-NMK16_MiSTer>, GPL-3.0-or-later,
  커밋 `98d7628a2a587ff8d7b3fe001344d2dd48451bf9`) — 이 게임을 이미 MiSTer 에서 돌리는 다른 코어입니다.
  기반으로 쓰지 않았고 코드도 가져오지 않았습니다. 기본 구현이 끝난 뒤 놓친 하드웨어 사실이 있는지 한 번
  대조했고 (찾지 못했습니다), 그쪽이 실기에서 겪고 기록한 **M6295 샘플 바이트 지연 문제와 그 해법 (칩 클럭을
  멈추는 방식)** 은 이 코어의 같은 문제를 측정하고 고치는 데 큰 도움이 됐습니다. 먼저 길을 낸 작업에 감사드립니다.

## 라이선스

이 코어 전체는 **GPL-3.0** 으로 배포됩니다 (GPL-3.0 인 fx68k 를 포함하기 때문입니다). 저장소의 `LICENSE`
파일은 GPL-3.0 전문입니다.

서드파티 파일은 각자의 저작권 표시와 라이선스 헤더를 그대로 유지합니다 (T80 의 BSD 계열 라이선스, MiSTer
framework 의 파일별 GPL 헤더 등). MAME 소스에서 인용한 사실은 MAME 의 BSD-3-Clause 에 따라 출처를 밝혔습니다.

게임 ROM, PROM 덤프는 저장소와 배포물에 포함되어 있지 않습니다. 타이밍과 믹서에 쓰는 PROM 세 개도
비트스트림에 굽지 않고, 실행할 때 사용자의 ROM 세트에서 읽어 옵니다.

## 알려진 제한사항

- **픽셀 클럭 지터.** 시스템 클럭 48 MHz 에서 7 MHz 픽셀을 분수 분주로 만들기 때문에 픽셀 간격이 6/7 클럭으로
  흔들립니다. 디지털 출력 (HDMI) 에서는 보이지 않지만 아날로그 출력에서는 드러날 수 있습니다.
- **스크롤 샘플 시점.** 타일 레이어를 한 라인 앞서 그리므로 스크롤 레지스터를 표시보다 한 라인 먼저 읽습니다.
  HUD 를 표시 도중에 쓰는 일부 프레임에서 MAME 와 한 프레임 위상 차이가 납니다.
- **하드웨어 근거가 아직 없는 부분.** flip screen 의 좌표 변환, DMA 동안 68000 정지 여부, 팔레트 5→8 비트 확장,
  미디코드 주소의 읽기값, 사운드 믹스 비율 (원판 DAC·앰프 대신 MAME 균형에 맞춤) 은 MAME 동작을 따른 것이며,
  실제 기판 측정으로 확인되지는 않았습니다.
- **M6295 클럭 정지 구조의 장시간 검증.** 샘플 지연 대책은 짧은 구간에서 지연 0 을 확인했지만 대전 장면을 포함한
  긴 시뮬레이션 확인은 끝나지 않았습니다.
- **검증 범위.** 실기 연속 구동은 30 분까지 확인했습니다. flip 이외의 DIP 설정은 실기에서 하나하나 확인하지
  않았습니다.
- 부트렉 세트와 Analogue Pocket 은 지원하지 않습니다.
