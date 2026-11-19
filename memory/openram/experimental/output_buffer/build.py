"""Build an isolated candidate; never overwrite released SRAM views."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("output", type=Path)
p.add_argument("--openram", type=Path, default=Path("/tmp/tt-openram-dev"))
p.add_argument("--python", default="/tmp/tt-openram-venv/bin/python")
a = p.parse_args()
here = Path(__file__).resolve().parent
out = a.output.resolve()
if out.exists():
    raise SystemExit("Choose a new output directory; existing results are preserved")
for name, expected in json.loads((here / "base_hashes.json").read_text()).items():
    if hashlib.sha256((a.openram / name).read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Unexpected OpenRAM source: {name}")
out.mkdir(parents=True)
tree = out / "openram"
shutil.copytree(a.openram, tree)
subprocess.run(["patch", "-p1", "--input", str(here / "openram.patch")], cwd=tree, check=True)
shutil.copy2(here / "sense_amp_buffered.py", tree / "compiler/modules/sense_amp_buffered.py")
env = os.environ.copy()
env.update(OPENRAM_HOME=str(tree / "compiler"), OPENRAM_TECH=str(tree / "technology"),
           PDK_ROOT=env.get("PDK_ROOT", "/tmp/tt-openram-pdk"),
           TT_SRAM_OUTPUT=str(out / "macro"), OPENBLAS_NUM_THREADS="1", PYTHONUNBUFFERED="1")
env["PATH"] = "/tmp/tt-magic/bin:/tmp/tt-netgen/bin:" + env["PATH"]
with (out / "build.log").open("w") as log:
    subprocess.run([a.python, str(tree / "sram_compiler.py"), str(here / "config.py")],
                   env=env, cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True)
print("Generated candidate only; inspect DRC/LVS and characterize before release:", out)
