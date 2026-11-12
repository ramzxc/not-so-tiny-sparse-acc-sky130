#!/usr/bin/env python3
"""Exhaustive binary proof for the narrowly scoped GL reset-X correction.

No register initialization is assumed. Feedback Qs and all other cone leaves
are independent binary inputs. Gate functions come from the SKY130 TT Liberty.
Not a replacement for full equivalence, timing, or transistor-level signoff.
"""
import ast
import json
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETLIST = Path(os.environ.get('RESET_NETLIST', ROOT / 'macro/acc_hard_macro/acc_hard_macro.pg.v'))
MODULE = 'activation_ctrl_COMPUTE_WIDTH2_META_FIFO_DEPTH4_UB_ROWS64'
TARGETS = {'n115': 'acc_req_addr[1]', 'n131': 'buffer_addr_cs[1]'}
CONSTANTS = {'rst': 1, 'HFSNET_9': 0, 'HFSNET_10': 1}


def prove():
    text = NETLIST.read_text()
    match = re.search(r'module ' + re.escape(MODULE) + r'\b.*?endmodule', text, re.S)
    assert match, f'Missing {MODULE}'
    functions = json.loads((ROOT / 'test/sky130_reset_gate_functions.json').read_text())['functions']
    drivers, flops = {}, {}
    for kind, instance, body in re.findall(r'sky130_fd_sc_hd__(\w+)\s+(\S+)\s*\((.*?)\)\s*;', match[0], re.S):
        ports = dict((k, v.strip()) for k, v in re.findall(r'\.(\w+)\s*\(\s*([^)]*)\)', body))
        if kind.startswith('df'):
            flops[ports['D']] = ports['Q']
        elif 'X' in ports or 'Y' in ports:
            output = ports.get('X', ports.get('Y'))
            assert output not in drivers, f'Multiple drivers: {output}'
            drivers[output] = (kind, ports)

    def inputs(net, visiting=frozenset()):
        if net in CONSTANTS:
            return set()
        assert net not in visiting, f'Combinational cycle: {net}'
        if net not in drivers:
            return {net}
        kind, ports = drivers[net]
        assert kind in functions, f'Unreviewed gate {kind}'
        names = {n.id for n in ast.walk(ast.parse(functions[kind].replace('!', '~'), mode='eval')) if isinstance(n, ast.Name)}
        return set().union(*(inputs(ports[n], visiting | {net}) for n in names))

    results = []
    for target, q in TARGETS.items():
        assert flops.get(target) == q, f'Changed D/Q mapping for {target}'
        leaves = sorted(inputs(target))
        assert len(leaves) <= 20, 'Cone too large for this exhaustive checker'
        combinations = 1 << len(leaves)
        mask = (1 << combinations) - 1
        cache = {n: mask if v else 0 for n, v in CONSTANTS.items()}
        cache.update({n: mask // ((1 << (1 << j)) + 1) for j, n in enumerate(leaves)})

        def value(net):
            if net in cache:
                return cache[net]
            kind, ports = drivers[net]
            tree = ast.parse(functions[kind].replace('!', '~'), mode='eval')
            def evaluate(node):
                if isinstance(node, ast.Expression): return evaluate(node.body)
                if isinstance(node, ast.Name): return value(ports[node.id])
                if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Invert): return ~evaluate(node.operand)
                if isinstance(node, ast.BinOp):
                    a, b = evaluate(node.left), evaluate(node.right)
                    if isinstance(node.op, ast.BitAnd): return a & b
                    if isinstance(node.op, ast.BitOr): return a | b
                    if isinstance(node.op, ast.BitXor): return a ^ b
                raise ValueError(f'Unsupported Boolean expression: {ast.dump(node)}')
            cache[net] = evaluate(tree) & mask
            return cache[net]

        assert value(target) == 0, f'UNSAFE reset correction: {target}'
        result = f'PASS {MODULE}.{q}: D={target}=0 for all {combinations} binary assignments during reset'
        print(result)
        results.append(result)
    return results


if __name__ == '__main__':
    prove()
