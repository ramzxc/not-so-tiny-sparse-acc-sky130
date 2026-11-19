#!/usr/bin/env python3
"""Prepare test-only Bishop E4M3FN bit patterns without modifying source data."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'test'))
from fp8_reference import decode8, from16, add8, mul8


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def conversion_table():
    # All finite binary16 values and FP8 levels are exact in binary64. Compare
    # adjacent levels, then resolve midpoint ties by the stored significand LSB.
    bits = np.arange(65536, dtype=np.uint16)
    values = bits.view(np.float16).astype(np.float64)
    levels = np.array([float(decode8(i)) for i in range(127)])
    magnitude = np.minimum(np.abs(values), 448)
    magnitude = np.where(np.isnan(magnitude), 0, magnitude)
    hi = np.minimum(np.searchsorted(levels, magnitude), 126)
    lo = np.maximum(hi-1, 0)
    below, above = magnitude-levels[lo], levels[hi]-magnitude
    nearest = np.where((below < above) | ((below == above) & ((lo & 1) == 0)), lo, hi)
    table = (nearest | ((bits >> 8) & 128)).astype(np.uint8)
    table[np.isnan(values)] = 0x7f
    oracle = np.array([from16(int(b)) for b in bits], dtype=np.uint8)
    assert np.array_equal(table, oracle), 'E4M3FN conversion disagrees with rational oracle'
    return table


def convert(array, table):
    assert array.dtype.kind == 'f' and array.dtype.itemsize == 2
    return table[array.astype('<f2').view('<u2')]


def statistics(original, encoded):
    original = original.astype(np.float64)
    levels = np.array([float(decode8(i)) if decode8(i) is not None else np.nan for i in range(256)])
    decoded = levels[encoded]
    finite = np.isfinite(original)
    error = np.abs(original[finite]-decoded[finite])
    return dict(elements=int(original.size), source_bytes=int(original.size*2), fp8_bytes=int(encoded.nbytes),
                source_nonfinite=int((~finite).sum()),
                clipped_finite=int((finite & (np.abs(original)>448)).sum()),
                nonzero_to_zero=int((finite & (original != 0) & ((encoded & 127) == 0)).sum()),
                max_absolute_error=float(error.max()) if error.size else None,
                mean_absolute_error=float(error.mean()) if error.size else None)


def write_npz(path, arrays):
    # An existing result may be reused only after every key, shape, dtype and bit
    # pattern matches. Never silently replace an unrelated conversion.
    if path.exists():
        with np.load(path, allow_pickle=False) as old:
            assert set(old.files) == set(arrays), f'incompatible existing file: {path}'
            for key, value in arrays.items():
                assert old[key].dtype == value.dtype and old[key].shape == value.shape
                assert old[key].tobytes() == value.tobytes(), f'incompatible existing array: {path}:{key}'
    else:
        np.savez_compressed(path, **arrays)
    with np.load(path, allow_pickle=False) as saved:
        for key, value in arrays.items():
            assert saved[key].tobytes() == value.tobytes()


def rtl_fixture(output):
    image = []
    address = 0x2000
    cases = []
    def place(data):
        nonlocal address
        start = address
        payload = np.asarray(data, dtype=np.uint8).tobytes()
        image.append(f'@{start:04x}\n'+' '.join(f'{v:02x}' for v in payload)+'\n')
        address = (address+len(payload)+1)&~1
        return start
    for ds, first_output in enumerate([0,256,512,760]):
        with np.load(output/f'bishop_{ds}/test.npz') as z:
            inputs = z['inputs']
        with np.load(output/f'bishop_{ds}/weights.npz') as w:
            weights = w['kernel'][:,first_output:first_output+8]
            bias = w['bias'][first_output:first_output+8]
        for batch in (1,4):
            x = inputs[100:100+batch]
            columns = x.shape[1]
            padded = np.pad(x, ((0,0),(0,columns%2)))
            packed = padded.reshape(batch,-1,2).transpose(1,0,2).copy()
            assert packed.nbytes <= 768
            initial = np.repeat(bias.reshape(4,1,2), batch, axis=1)
            expected = initial.copy()
            for b in range(batch):
                for c in range(columns):
                    a = int(x[b,c])
                    if a & 127 == 0:
                        continue
                    for g in range(4):
                        for lane in range(2):
                            expected[g,b,lane] = add8(int(expected[g,b,lane]),
                                                     mul8(a,int(weights[c,2*g+lane])))
            cases.append(dict(dataset=f'bishop_{ds}', batch=batch, columns=columns, groups=4,
                              first_row=100, first_output=first_output,
                              input_source=place(packed), input_vectors=packed.nbytes//2,
                              weight_source=place(weights), bias_source=place(initial),
                              active_columns=int(((x & 127) != 0).any(axis=0).sum()),
                              expected=expected.reshape(-1).tolist()))
    assert address <= 65536
    (output/'rtl_flash.hex').write_text(''.join(image))
    (output/'rtl_cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    return len(cases)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--data',type=Path,default=Path('/docker/projects/egru/sim/data/sdc_raw'))
    ap.add_argument('--output',type=Path,default=ROOT/'reports/fp8_1k/data')
    args = ap.parse_args()
    table = conversion_table()
    args.output.mkdir(parents=True,exist_ok=True)
    manifest = dict(schema=1, format='FP8 E4M3FN', storage_dtype='uint8 raw encoding, not integer magnitude',
                    rounding='nearest, ties to even', overflow='finite saturation to +/-448',
                    nan='canonical 0x7f', signed_zero='preserved', scaling='none',
                    exhaustive_conversion_patterns=65536,
                    metadata='Only test.inputs is converted; labels/targets/trial metadata remain source values.',
                    source_input_saturation_count='Copied from FP16 source; FP8 conversion statistics are recorded here.',
                    gate_layout='Original axes/order preserved; no gate reorder or bias folding.', datasets=[])
    for ds in range(4):
        source = args.data/f'bishop_{ds}/fp16'
        target = args.output/f'bishop_{ds}'
        target.mkdir(parents=True,exist_ok=True)
        record = dict(dataset=f'bishop_{ds}', source={}, outputs={}, statistics={})
        for name in ('weights','test'):
            path = source/f'{name}.npz'
            record['source'][name] = dict(path=str(path.resolve()),sha256=digest(path))
            with np.load(path,allow_pickle=False) as data:
                arrays = {}
                for key in data.files:
                    value = data[key]
                    if name == 'weights' or key == 'inputs':
                        encoded = convert(value,table)
                        arrays[key] = encoded
                        record['statistics'][f'{name}.{key}'] = statistics(value,encoded)
                    else:
                        arrays[key] = value
            result = target/f'{name}.npz'
            write_npz(result,arrays)
            for key,value in arrays.items():
                if name != 'weights' and key != 'inputs':
                    continue
                # C-order: output lanes contiguous for each matrix input row.
                binary=target/f'{key}.bin'
                if binary.exists():
                    assert binary.read_bytes()==value.tobytes(), f'incompatible existing binary: {binary}'
                else:
                    binary.write_bytes(value.tobytes())
            record['outputs'][name] = dict(path=str(result),sha256=digest(result))
            assert digest(path) == record['source'][name]['sha256'], 'source changed during conversion'
        manifest['datasets'].append(record)
        stats=record['statistics']
        print(record['dataset'], 'input bytes',stats['test.inputs']['fp8_bytes'],
              'clipped',sum(s['clipped_finite'] for s in stats.values()),
              'nonzero-to-zero',sum(s['nonzero_to_zero'] for s in stats.values()),flush=True)
    manifest['rtl_cases'] = rtl_fixture(args.output)
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (args.output/'README.txt').write_text(
        'Test-only E4M3FN data. NPZ converted arrays and .bin files contain uint8 FP8 bit patterns.\n'
        'Do not cast uint8 directly to float: decode E4M3FN first.\n'
        'Weights retain original matrix axes and separate biases. Raw binaries use C order.\n'
        'Only inputs are quantized in test.npz; other arrays are unchanged reference metadata.\n'
        'rtl_flash.hex/rtl_cases.json exercise actual full-width input projections onto eight outputs;\n'
        'these fixtures do not constitute full EGRU/FC inference or accuracy validation.\n')
    print(args.output)


if __name__ == '__main__':
    main()
