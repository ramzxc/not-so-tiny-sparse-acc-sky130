#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/fp8-math-test.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'test')
from fp8_reference import add8, mul8, encode8, F
out=Path(sys.argv[1])
with (out/'binary.hex').open('w') as f:
    for a in range(256):
        for b in range(256):
            f.write(f'{add8(a,b):02x}{mul8(a,b):02x}\n')
with (out/'pack.hex').open('w') as f:
    for scale in range(-18,11):
        for magnitude in range(256):
            f.write(f'{encode8(F(magnitude)*F(2)**scale):02x}\n')
PY
iverilog -g2012 -I src/rtl -s tb_fp8_math -o "$build_dir/test" test/tb_fp8_math.sv
vvp "$build_dir/test" +binary="$build_dir/binary.hex" +pack="$build_dir/pack.hex"
verilator --lint-only -Wno-fatal -Isrc/rtl -Isrc/rtl/core --top-module exec_unit src/rtl/core/exec_unit.sv
