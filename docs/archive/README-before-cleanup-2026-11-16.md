# Not-so-tiny sparse accelerator — SKY130

Experimental Tiny Tapeout SKY130 8×2 submission with one 512 B OpenRAM SRAM.
GitHub Actions validates RTL, hardening, precheck and gate-level simulation.

- Two-lane FP16 TPU with SPI host interface.
- Software-managed weight buffer; cache and replacement logic are disconnected.
- One shared OpenRAM 1RW SRAM: selectable 1 KiB or 512 B; UB/ACC/WB partitioned 1/2, 1/4, 1/4.
- Two FP16 lanes; two 32-bit rows per physical 64-bit SRAM word. Partial writes use atomic read-modify-write.
- [Protocol and implementation limits](docs/info.md).
- Compile SRAM libraries: `lc_shell -f syn/compile_openram.tcl`.
- Synthesis: `ACC_SRAM_BYTES=512 dc_shell -f syn/run_dc.tcl` in the local synthesis workspace; local `syn/` and `pnr/` outputs are excluded from submission.
- RTL tests: `make -C test SRAM_BYTES=512`; controller stress test: `make -C test -f Makefile.mem SRAM_BYTES=512`.
- P&R configs: `src/config_1024.json` or `src/config_512.json`; `src/config.json` defaults to 512 B.

## 수동 DC / ICC2 코어 하드닝

`main`의 제출 RTL은 통과 기준 `b22cd30` 그대로 유지합니다. 별도
`syn/rtl/acc_hard_macro.v`는 그 버전의 `src/project.v`에서 모듈명만
바꾼 top입니다. SPI, host, DMA, 연산부, 512 B SRAM을 전부 포함합니다.
2 lane / 물리 MAC 1개이며, 기존 SRAM 출력에 버퍼를 추가하지 않습니다.

구조는 `Tiny Tapeout 핀 → 얇은 wrapper → acc_hard_macro (SRAM 포함)`입니다.
`pnr/wrapper/tt_wrapper.v`와 `acc_hard_macro.blackbox.v`는 **하드닝 완료 후
사용할 통합 템플릿**입니다. 현재 Actions 입력에는 추가하지 않았습니다.
코어 RTL과 blackbox 모델을 동시에 읽지 마세요. 최종 통합에는 코어의
GDS·LEF·Liberty·LVS netlist 및 GL 시뮬레이션 모델이 필요합니다.
blackbox 선언만으로 제작 가능한 코어가 만들어지는 것은 아닙니다.

GF180 프로젝트와 같은 디렉터리 형식으로 정리했습니다.

```text
syn/env.sh                 도구 경로 설정
syn/script/config.tcl      SKY130·SRAM·입출력 경로
syn/script/setup.tcl       DC 라이브러리 로딩, acc_read_rtl 정의
syn/script/synth.tcl       setup + RTL elaboration/link까지만 실행
syn/script/export.tcl      사용자가 합성한 결과 내보내기
syn/cons/top.sdc           초기 타이밍 예산
syn/rtl/acc_hard_macro.v   코어 top
syn/runs/<TT_SYN_RUN>/     합성 작업 및 결과 (기본 manual)
pnr/scripts/config.tcl    공통 설정 로딩
pnr/scripts/libs.tcl      reference NDM 준비 (LM)
pnr/scripts/import.tcl    새 ICC2 library/block에 netlist 불러오기
pnr/core/setup.tcl        tt_core_* 함수와 경계 설정, source만으로 실행 안 함
pnr/core/init.tcl         현재 블록에 floorplan·SRAM·신호 핀 적용
pnr/core/pins.tcl         신호 핀만 적용, 기존 terminal이 있으면 중단
pnr/core/spare_load.tcl   선택 실행: spare 출력에 실제 inv_2 부하 추가
pnr/wrapper/             하드닝 후 TT 연결용 템플릿
pnr/refs/                reference NDM
pnr/work/<TT_SYN_RUN>/   ICC2 작업 library
```

전체 합성을 한 번에 실행하려면 다음 명령을 사용합니다.

```bash
./syn/run_synthesis.sh --check  # 입력 파일/경로 확인만
./syn/run_synthesis.sh          # DC compile + 리포트 + netlist/DDC/SDC 저장
```

기본 결과는 `syn/runs/<날짜_시간_PID>/`에 저장되고, 성공한 결과 경로는
`syn/LATEST`에 기록됩니다. 기존 실행 디렉터리는 덮어쓰지 않습니다.
기본 구성은 512 B / 2 lane / MAC 1개입니다. PnR에 넘길 때는 해당 실행의
`TT_SYN_RUN`을 지정하거나 `ACC_NETLIST`와 `ACC_SDC`로 결과 파일을 지정하세요.
합성 성공은 리포트의 타이밍/전기적 위반까지 없다는 의미는 아닙니다.

저장소 루트에서 `source syn/env.sh` 후 `$DC_SHELL` / `$ICC2_SHELL`을 실행합니다.
다른 실행 디렉터리에서 시작하면 아래 Tcl 경로를 절대 경로로 지정하세요.

```tcl
# dc_shell: 합성 최적화는 실행하지 않고 prompt로 돌아옵니다.
source syn/script/synth.tcl
# 사용자가 compile 수행 후:
source syn/script/export.tcl
```

```tcl
# icc2_lm_shell: reference NDM 생성, 최초 한 번만 실행
source pnr/scripts/libs.tcl
# 이 컴퓨터에서는 이미 준비되어 pnr/refs/에 있습니다. 덮어쓰지 않습니다.
```

```tcl
# icc2_shell: syn/script/export.tcl 결과가 준비된 후
source pnr/scripts/import.tcl
source pnr/core/init.tcl
# 선택: 실제 spare 부하를 추가하기로 한 경우에만 실행
# source pnr/core/spare_load.tcl
# init은 save하지 않습니다. 확인 후 사용자가 save_block 실행.
# 이후 전원망·tap/endcap·place_opt·CTS·배선은 사용자가 진행
```

`pnr/scripts/config.tcl`의 기본 합성 실행은 Formality/PrimeTime으로 확인한
`20261112_190700_161808`입니다. 따라서 별도 환경변수 없이 이번
`acc_hard_macro_gate.v`를 읽습니다. 다른 실행은 `TT_SYN_RUN`으로 지정합니다.
기본 NDM 출력은 `pnr/work/20261112_190700_161808/acc_hard_macro.ndm`이며,
이미 존재하면 import는 덮어쓰지 않고 중단합니다. 재개할 때는 해당 NDM을
`open_lib`, `open_block acc_hard_macro`로 여세요.

`spare_load.tcl`은 init에서 자동 호출하지 않습니다. CTS가 데이터 출력의
min-capacitance를 해결한다고 보장할 수 없으므로, 필요하면 이 Tcl로 실제
인버터 입력을 연결하고 보존한 뒤 배치/배선 및 추출 STA로 확인합니다.
출력은 의도적으로 미사용이며 PG net은 기존 VPWR/VGND에 연결합니다.
단순 `set_load`로 위반만 숨기지 않습니다. PG mesh/전원 terminal은 별도 `apply_pg.tcl`에 있습니다(아래 미해결 상태 참고).
tap/endcap, place_opt, CTS 실행, 배선, GDS 병합/export는 자동 실행하지 않습니다.

이미 직접 불러온 블록에 적용하려면 `pnr/scripts/import.tcl`을 건너뛰고
`source pnr/core/setup.tcl` → 필요하면 `tt_core_constraints` →
`source pnr/core/init.tcl` 순서로 실행합니다. `tt_core_constraints`는 초기
SDC 예산을 적용하므로 이미 설정한 사용자 제약을 유지하려면 호출하지 마세요.
기존 `syn/run_dc.tcl` 등 과거 자동 합성 실험은 보존했지만 새 수동 진입점은
`syn/script/synth.tcl`입니다. 이 파일은 compile을 실행하지 않습니다.

경로 설정은 `syn/script/config.tcl`에 있습니다. `ACC_STD_DB`, `ACC_SRAM_DB`,
`ACC_PDK`, `SKY130_TECH_FILE`, `SKY130_TLUP`, `SKY130_RC_MAP`,
`TT_SYN_RUN`, `TT_PNR_OUT`, `ACC_MANUAL_OUT`, `ACC_REF_DIR`,
`ACC_NETLIST`, `ACC_SDC`, `ACC_DESIGN_LIB` 환경변수로
덮어쓸 수 있습니다. 기본 작업 폴더 `syn/runs/` 및 `pnr/work/`는 Git에서 제외합니다.
경로는 현재 컴퓨터 기준이며 DB/NDM은 저장소에 포함되지 않습니다.
SRAM DB는 표준셀 target library가 아닌 link library로만 사용합니다.
PDK의 no_synth 및 DRC 제외 셀 목록을 적용하고, ICC2에서는 CTS용 clock buffer
사용 목적을 별도로 허용합니다. 기존 면적 측정과 합성 셀 선택이 달라질 수 있습니다.

| 항목 | 크기 / 위치 (µm) |
| --- | --- |
| TT SKY130 8×2 외곽 | 1378.16 × 225.76 |
| 코어 매크로 외곽 | 1367.12 × 214.88 |
| wrapper 내 코어 원점 | (5.52, 5.44), N / ICC2 R0 |
| SRAM 크기 | 520.455 × 187.495 |
| 코어 내 SRAM 원점 | (414.48, 13.695), R0 |
| SRAM 표준셀 keepout | 사방 5 |
| 코어 신호 핀 | 북쪽 met4, 0.30 × 1.00, 43개 |

TT 외곽은 통과한 b22cd30 실행의 config에서 확인했습니다. 신호 핀 x좌표는
동일 TT 템플릿을 사용한 CI DEF에서 추출하여 코어 원점만큼 이동했습니다.
wrapper에 위 좌표로 배치하면 TT 핀과 x축이 맞습니다. SRAM은 통과본의 절대
위치 (420, 19.135)를 유지합니다. floorplan은 배선 성공을 보장하지 않으며,
코어 핀/LEF는 wrapper 연결용입니다. TT 제출 외곽 핀은 기존 TT 템플릿을 유지해야 합니다.
전원 net 연결만 준비하며, PG mesh·전원 terminal·tap/endcap은 아직 생성하지 않습니다.
코어 PG 포트 이름은 최종 LEF/netlist/blackbox 모두 `VPWR` / `VGND`로 맞춰야 합니다.

DC와 ICC2 기본 SDC를 `syn/cons/top.sdc`로 통일했습니다. 통과한 b22cd30
Actions 실행 43060864621의 실제 설정과 SDC에 맞췄으며, 출처는
`syn/cons/tt_sky130_source.json`에 기록했습니다. 100 ns clock, 20 ns I/O delay,
0.25 ns uncertainty, 0.15 ns clock transition, inv_2/Y 입력 구동,
0.033442 pF 출력 부하, 최대 fanout 10 / transition 0.75 ns / capacitance 0.2 pF,
early/late derating 0.95/1.05를 적용합니다. ICC2도 예전 mapped SDC를 자동으로
읽지 않습니다. 필요하면 `ACC_SDC`로 다른 SDC를 지정할 수 있습니다.
DC와 ICC2에서 SDC 로딩을 확인했습니다. 다만 ICC2는 `set_max_fanout`을
지원하지 않아 해당 명령을 무시합니다(CSTR-011). fanout 10은 DC에서 적용되며,
ICC2에서도 동일하게 강제된다고 해석하면 안 됩니다.
CTS 전에는 ideal clock이며, CTS 후 `set_propagated_clock [get_clocks clk]`로
전환해야 합니다. 최종 wrapper 연결 후에도 동일 TT 조건으로 검증해야 합니다.
기본 TF는 로컬 보정한
community SKY130 TF이고 RC는 TT nominal 한 코너뿐입니다. 따라서 이 설정만으로
제조 signoff를 완료했다고 판단할 수 없습니다. 원본/보정 내역은
`/docker/projects/egru/acc/archive/sky130_20261102_192346/pnr/tech/`에 있습니다.

# Tiny Tapeout Verilog Project Template

- [Read the documentation for project](docs/info.md)

## SKY130 PG Tcl 구성

GF180 프로젝트와 같은 `pnr/core/setup.tcl`, `init.tcl`, `pins.tcl`,
`power_plan.tcl`, `apply_pg.tcl`, `init_with_pg.tcl`, `prepare_cts.tcl`로 나눴습니다.
실행 순서는 `pnr/core/README.txt`, 전원 좌표는 `pnr/core/POWER_PLAN.txt`를 보세요.
PG stripe는 b22cd30의 실제 GDS/DEF/LEF를 대조해 코어 원점 (5.52,5.44)에
맞춰 이동했습니다. wrapper의 코어 고정 Tcl과 전원 feed 좌표도 `pnr/wrapper/`에 있습니다.

**PG는 아직 ICC2 검증 완료가 아닙니다.** 마지막 실행에서 SRAM 접속부에
met4 blockage overlap 78건과 via 생성 실패가 있었습니다. 이를 숨기거나
DRC를 완화하지 않았습니다. 사용자의 요청 이후 ICC2 실행을 중단했으며,
현재 `pg_adjustments.tcl`은 기존 PG x좌표와 5 µm halo를 유지하며,
예전 10 µm halo에서 끊겼던 stripe를 복원하고 SRAM M3 옆면 접속으로 수정했습니다.
수정 후 ICC2는 실행하지 않았습니다. 직접 DRC·연결을 확인해야 합니다.

## Formality / PrimeTime 확인

합성 실행 `20261112_190700_161808`에 대해 두 도구를 실행했습니다.
Formality는 1,797개 비교점 동등성 통과, 실패/중단/미검증 비교점 0개입니다.
SRAM은 양쪽에서 같은 DB 매크로로 취급하므로 내부 SRAM 기능 검증은 포함하지 않습니다.
PrimeTime은 TT 조건의 pre-layout 분석에서 setup +29.34 ns, hold +0.15 ns입니다.
미검사 32개는 상수 출력과 spare 입력입니다. 미사용 SRAM `dout0[64]`에는
최소 부하 0.0017225 pF 대비 실제 0인 min-capacitance 위반 1개가 남습니다.
제약을 완화하거나 가짜 부하를 추가하지 않았습니다. 배선 SPEF 검증은 별도입니다.
상세 결과는 `reports/fm_pt_20261112_190700_161808.json`, 원본 로그와 리포트는
`sta/formality/runs/20261112_190700_161808/` 및 대응 `sta/primetime/runs/`에 있습니다.

재실행할 때는 별도 작업 디렉터리에서 `TT_SYN_RUN`을 대상 합성 실행명으로
지정하고 `fm_shell -f <저장소>/sta/formality/run.tcl` 또는
`pt_shell -f <저장소>/sta/primetime/run.tcl`을 실행합니다. 결과는 현재 디렉터리의
`reports/`에 기록됩니다. 기존 검증 결과 보존을 위해 새 작업 디렉터리를 사용하세요.

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get your digital and analog designs manufactured on a real chip.

To learn more and get started, visit https://tinytapeout.com.

## Set up your Verilog project

1. Add your Verilog files to the `src` folder.
2. Edit the [info.yaml](info.yaml) and update information about your project, paying special attention to the `source_files` and `top_module` properties. If you are upgrading an existing Tiny Tapeout project, check out our [online info.yaml migration tool](https://tinytapeout.github.io/tt-yaml-upgrade-tool/).
3. Edit [docs/info.md](docs/info.md) and add a description of your project.
4. Adapt the testbench to your design. See [test/README.md](test/README.md) for more information.

The GitHub action will automatically build the ASIC files using [LibreLane](https://www.zerotoasiccourse.com/terminology/librelane/).

## Enable GitHub actions to build the results page

- [Enabling GitHub Pages](https://tinytapeout.com/faq/#my-github-action-is-failing-on-the-pages-part)

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)

## What next?

- [Submit your design to the next shuttle](https://app.tinytapeout.com/).
- Edit [this README](README.md) and explain your design, how it works, and how to test it.
- Share your project on your social network of choice:
  - LinkedIn [#tinytapeout](https://www.linkedin.com/search/results/content/?keywords=%23tinytapeout) [@TinyTapeout](https://www.linkedin.com/company/100708654/)
  - Mastodon [#tinytapeout](https://chaos.social/tags/tinytapeout) [@matthewvenn](https://chaos.social/@matthewvenn)
  - X (formerly Twitter) [#tinytapeout](https://twitter.com/hashtag/tinytapeout) [@tinytapeout](https://twitter.com/tinytapeout)
  - Bluesky [@tinytapeout.com](https://bsky.app/profile/tinytapeout.com)

### Full accelerator CI with validated 512 B SRAM

Branch `main` retains the complete SPI host, DMA, TPU and memory
controller with two compute lanes, one physical MAC and instruction FIFO depth two. It imports
the 512 B macro and physical integration fixes from SRAM-only commit a92fb82:
exact GDS-derived LEF, corrected implants, explicit edge PDN connections,
continuous external power ports, strict DRC/LVS/XOR and KLayout GDS merge.
The macro instance path in PDN/config is the full accelerator hierarchy.
The SRAM-only validation records are reference evidence, not full-accelerator
signoff. This branch requires its own full CI validation. Only 512 B is selected;
1 KiB artifacts/configuration have not been rebuilt or validated by this update.
GL jobs select Icarus for both cleanup and simulation. SRAM power ports are
connected by physical PDN/global connection rules; RTL PINMISSING warnings
must be assessed against power-connectivity and LVS results.

SRAM NDM 접근 모델 수정용 Tcl은 `pnr/scripts/rebuild_sram_ndm.tcl`(LM)과
`pnr/scripts/replace_sram_ndm.tcl`(기존 ICC2 블록)입니다. SRAM에만
`configure_frame_options -mode preserve_all`을 적용하며, 표준셀 NDM과
원본 SRAM GDS/LEF/DB는 유지합니다. 직접 실행할 순서는 `pnr/core/README.txt`
마지막 부분에 있습니다. 아직 도구 실행·재검증하지 않았습니다.
