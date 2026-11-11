# Tiny Tapeout 8×2용 단일 SRAM 두 가지

1 KiB(64×128)와 대체용 512 B(64×64)를 각각 독립적인 단일 1RW 매크로로 생성한다. 두 개를 동시에 쓰는 구성이 아니다. 현재 TPU는 compute width=2이며, 32-bit 논리 행 두 개를 64-bit 물리 word에 저장한다. `src/mem_ctrl.sv`가 UB/ACC/WB 요청을 중재하며 단일 매크로에 연결한다. 기본 분할은 UB 1/2, ACC 1/4, WB 1/4이다. `ACC_SRAM_BYTES=1024` 또는 `512`로 선택한다.

**2026-11-11: 두 용량 모두 매크로 단독 최종 DRC=0, LVS=0, LVS 치수 불일치 없음. 행동 모델 테스트와 전원 핀 포함 래퍼 컴파일도 통과했다.**

| 유효 용량 | 구성 | 크기 (µm) | 면적 (mm²) | DRC / LVS |
|---|---|---:|---:|---|
| 1 KiB | 64×128, 1RW, WPR=4 | 840.455×214.355 | 0.180156 | 0 / 0 |
| 512 B | 64×64, 1RW, WPR=2 | 520.455×187.495 | 0.097583 | 0 / 0 |

1 KiB를 수직 중앙에 놓으면 위아래 여유가 각각 5.7025 µm, 512 B는 19.1325 µm다. 특히 1 KiB는 PDN/배선 여유가 좁고, 면적도 초기 가정 예산보다 크므로 전체 설계에 들어간다고 확정할 수 없다.

최종 선택 결과와 검증 상태는 [summary.json](summary.json), 검증한 GDS/LEF/SPICE/Verilog/Liberty는 `generated/`에 저장한다. 최종 통과한 원본 실행 결과는 `runs/64x{64,128}_custom_tapped/`에 있으며, 두 용량이 모두 통과해야 `package.py`로 배포 폴더를 갱신할 수 있다.

## 물리 검증 범위

Magic 8.3.696의 SKY130 `drc(full)` 및 Netgen 1.5.328로 최종 매크로 DRC/LVS를 수행한다. 전원 ring과 내부 전원 배선을 포함하며 `final_verification=True`로 추출한다. 연결 일치뿐 아니라 트랜지스터 속성 불일치도 실패로 판정한다. 검증 JSON의 GDS/LVS-SPICE SHA-256과 배포 파일을 대조한다.

1378.16×225.76 µm 외곽 안에 드는지 확인하지만, 이는 TPU 로직·배선·PDN·halo까지 포함한 최종 Tiny Tapeout 배치배선 검증은 아니다. 매크로 단독 DRC/LVS와 칩 전체 signoff를 구분해야 한다.

Liberty는 TT 1.8 V / 25°C의 **analytical 추정치**이며 SPICE 기반 다중 corner timing characterization은 아직 수행하지 않았다. 행동 모델 테스트는 전체 주소에 네 패턴을 쓰고 역순으로 읽으며 비활성 쓰기의 보존 동작을 검사한다. 트랜지스터 수준 기능 검증을 대신하지 않는다. 별도 소형 배열의 untrimmed SPICE 테스트는 18분 이상 완료되지 않아 중단했으며 PASS로 취급하지 않는다.

## 수정한 원인

OpenRAM dev와 SKY130 custom bitcell을 사용하며 [패치 설명](patches/README.md)에 재현 가능한 수정 내용을 기록했다.

- Deep-N-well 경계의 N-well 폭을 실제로 넓혀 enclosure 위반 해결.
- 큰 인버터를 바디 접점이 있는 병렬 슬라이스로 나눠 latch-up 접점 거리 위반 해결. 요청한 총 드라이브 크기를 유지한다.
- custom bitcell 핀 종류와 내부 저장 노드 이름을 수정해 timing graph 생성 오류 해결.
- 누락된 custom-cell LVS 뷰에 SI 단위를 명시해 추출 결과와 W/L 비교 단위 통일.
- Netgen 속성 오류 문구도 실패로 인식하도록 검증 파서 보강.

PDK 규칙을 완화하거나 실패 셀을 새로 blackbox 처리하지 않았다. 기존 OpenRAM 기술 설정의 SRAM 라이브러리 처리 규칙은 그대로 사용한다. 이전 Cypress 후보는 DRC 653건 및 LVS 불일치로 폐기했다. 중간 custom 후보도 큰 드라이버의 접점 거리 위반 때문에 폐기했다. 상세 시행 로그는 git에서 제외한 `runs/`에 보존한다.

## 인터페이스

- 1RW: 한 사이클에 읽기 또는 쓰기 하나. 현재 1R1W RTL과 교체하려면 접근 중재가 필요하다.
- `clk0` 상승 에지에 요청을 잡고 하강 에지에서 동작한다.
- `csb0`: active-low enable. `web0`: 0=write, 1=read. 64-bit 전체 행 쓰기이며 byte mask는 없다.
- 한 spare column은 사용하지 않는다. 물리 데이터 포트는 65-bit이며 `spare_wen0=0`, `din0[64]=0`, `dout0[64]` 미사용으로 처리한다. `wrappers/`에서 유효 64-bit 포트를 제공한다.
- 전원은 `vccd1`, `vssd1`. 행동 모델에서 전원 핀을 노출하려면 `USE_POWER_PINS`를 정의한다. reset/초기화 기능은 없다.

## 재현

소스 commit, 도구 버전, 패치 해시는 [provenance/sources.json](provenance/sources.json), 라이선스는 `licenses/`에 있다. OpenRAM dev checkout에 `patches/sky130-custom-physical-and-pin-types.patch`를 적용한다. PDK와 SRAM 셀 라이브러리를 설치한 뒤 다음을 실행한다.

```sh
python3 memory/openram/build.py 64 --geometry-only
python3 memory/openram/build.py 128 --geometry-only
```

`--geometry-only`는 생성 중 단위별 DRC/LVS만 생략한다. 전원 배선과 산출물 생성은 수행한다. 다음 최종 검증을 별도로 실행해야 한다.

```sh
export OPENRAM_HOME=/tmp/tt-openram-dev/compiler
export OPENRAM_TECH=/tmp/tt-openram-dev/technology
export PDK_ROOT=/tmp/tt-openram-pdk
export PATH=/tmp/tt-magic/bin:/tmp/tt-netgen/bin:$PATH

TT_WORDS_PER_ROW=2 /tmp/tt-openram-venv/bin/python memory/openram/verify.py \
  memory/openram/runs/64x64_custom_tapped 64
TT_WORDS_PER_ROW=4 /tmp/tt-openram-venv/bin/python memory/openram/verify.py \
  memory/openram/runs/64x128_custom_tapped 128
python3 memory/openram/tests/test_models.py memory/openram/runs/64x64_custom_tapped 64
python3 memory/openram/tests/test_models.py memory/openram/runs/64x128_custom_tapped 128
python3 memory/openram/package.py
```

기본 도구 위치는 `/tmp` 아래다. 장기 재현 시 기록한 commit에서 다시 설치해야 한다. `TT_OPENRAM_ROOT`, `TT_OPENRAM_PYTHON`, `TT_PDK_ROOT`는 생성 도구 위치, `TT_MAGIC`, `TT_NETGEN`은 검증 실행 파일을 지정한다. 검증 시 `OPENRAM_HOME`, `OPENRAM_TECH`, `PDK_ROOT`도 해당 설치에 맞춰 지정한다.

이전 실패 산출물은 `archive/rejected_cypress/`에 로컬 보관했다. Git push는 수행하지 않았다.

### 512 B physical repair candidate (SRAM-only CI)

The raw detailed LEF omitted actual routing geometry. `lef_from_gds.py` rebuilds
M1–M4 and via–via3 OBS from final GDS, subtracting only the public LEF pin
shapes. It verifies that pins exist in GDS and no routing geometry is omitted.
See [ORFS #4753](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts/issues/4753)
for an independently reported analogous failure. No route/check exemptions are added.

The raw macro also had 1700 KLayout mask-spacing violations. The geometry-specific
`repair_512_masks.py` adds NSDM/PSDM/NPC bridges while retaining every original
cell polygon. It follows the merge requirement in the SKY130
[periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)
(nsd.2, psd.2, npc.2). Two diagonal PSDM junctions use asymmetric 0.78 x 0.63 um bridges;
these coordinates apply only to this 512 B layout. It does not modify transistor,
contact, routing-metal or via geometry. Magic DRC, KLayout DRC and LVS must be
rerun after any change to the repair or input.

Reproduce using Python with `gdstk` (raw input is retained in git):

```sh
mkdir -p /tmp/sram-raw /tmp/sram-repaired
name=tt_sram_1rw_64x64_sky130
git show 92e4afc:memory/openram/generated/$name/$name.gds > /tmp/sram-raw/$name.gds
git show 92e4afc:memory/openram/generated/$name/$name.lef > /tmp/sram-raw/$name.lef
python3 memory/openram/repair_512_masks.py /tmp/sram-raw/$name.gds /tmp/sram-repaired/$name.gds
python3 memory/openram/lef_from_gds.py /tmp/sram-repaired/$name.gds /tmp/sram-raw/$name.lef /tmp/sram-repaired/$name.lef
```

GDS timestamps may differ; cell geometry must be identical. `repair_audit.json`
records the reproduction audit. `lef_coverage.json` records coverage on all seven
routing/cut layers. The adopted GDS is the exact file checked by Magic and LVS
(`verification.json` includes its SHA256); standalone KLayout checked FEOL,
BEOL, off-grid and seal rules with zero markers. Local OpenROAD pin access also
passed. Full wrapper routing DRC/LVS and Magic-versus-KLayout XOR are **pending**
for this candidate. The previous strict run 42994071301 failed (254954 XOR,
3609 Magic DRC, 2593 KLayout DRC). Earlier route-zero results in
`routing_checks.json` apply only to the previous, incomplete LEF.
Timing Liberty is still analytical, not SPICE/PVT signoff. This is a CI validation
candidate, not a tapeout-qualified release. All strict CI checks remain enabled.

The first repaired run (42998782861) stopped in Magic streamout: 81 LEF
polygon parsing errors. The writer put as many as 31279 characters on one line,
exceeding Magic's 2048-byte LEF input buffer. Coordinates now appear one pair
per line (maximum line length 48); all LEF tokens and geometry are unchanged.
Magic 8.3.623, the CI version, read all 356310 lines with no errors. See
`provenance/512b-physical-repair/magic_lef_read.txt`. Full signoff remains pending.

### Integration repair after run 43000975752

The run passed LVS and antenna but failed with 394 KLayout DRC markers,
576 Magic DRC markers, 310 extraction overlap errors and 252193 XOR differences.
The KLayout streamout contained an empty SRAM cell: `RenameCell` retained the
cleared LEF cell rather than replacing it with macro GDS. `OverwriteCell` now
fills the existing cell from its supplied GDS. The macro geometry must be present
and equivalent in both streamouts; XOR remains mandatory.

392 KLayout markers were via3 size/spacing violations at the SRAM power rings.
Automatic macro M3/M4 stitching duplicated existing internal macro vias.
`pdn_standard_grid.tcl` preserves LibreLane 3.0.14's standard-cell power grid
(Apache-2.0 source), omitting its default macro grid; the explicit checked edge
connections remain in `pdn_sram_connections.tcl`. Both supply connectivity checks
must pass. This removes duplicate geometry rather than ignoring DRC.

The other two markers were NSDM/PSDM overlap on active beneath the previously
added square bridges. The bridges are now asymmetric and the generation script
asserts zero implant overlap on active. The earlier standalone KLayout deck
lacked that rule and was insufficient. The CI PDK reference at open_pdks
8afc8346a57fe1ab7934ba5a6056ea8b43078e71 pins fossi-foundation/mpw_precheck
7eb869a4b6a5807f49d5ae738c541cce39c41ba5. Its `sky130A_mr.drc` SHA256 is
caf4a6b08cb12f78d6bb2d120737424c786b3bae8d6489234b9b269e91107bfc.
The updated macro passes this deck with FEOL/BEOL/offgrid/seal enabled, plus
Magic DRC and unique Netgen LVS, with no property errors. Previous reports were
replaced by reports for the updated macro. Physical checks are not timing/PVT
characterization.

Local replay of run 43000975752's final signal routing with the corrected PDN
and macro gives **Magic DRC 0, KLayout DRC 0, XOR 0**, and both supply nets
connected. Both streamouts contain the actual SRAM geometry. Evidence and hashes
are in `provenance/512b-integration-repair/`. This replay does not replace a fresh
full CI run or full-chip extraction/LVS after the changes. All checks stay enabled.
