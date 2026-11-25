#!/usr/bin/env python3
"""Build a batch-1, 256-neuron FP8 EGRU/FC image for the column SRAM layout."""

import argparse
from pathlib import Path

import numpy as np

LANES = 4
HIDDEN = 256
TABLE_BASE = 0x1FF000
HEADER_ADDR = 0x1FFFF8
PROGRAM_BASE = 0x200000
STATE_C, STATE_Y, FC_OUTPUT = 0x2000, 0x3000, 0x3800

LOAD_UB, STORE_UB, STORE_ACC, LOAD_ACC = 0x40, 0x42, 0x43, 0x44
WEIGHT = 0x08
MUL, SUB, ACCUMULATE = 0x20, 0x24, 0x01
COPY, SIGMOID, TANH, STEP, SYNC = 0x80, 0x89, 0x8A, 0x8B, 0xFF


def build_image(model_dir, add_table, uart_clocks=0, state_c=None, state_y=None):
    """Return the complete image and its channel and instruction counts."""
    if uart_clocks != 0 and not 32 <= uart_clocks <= 1023:
        raise ValueError("UART clocks per bit must be zero or 32–1023")

    def read(name):
        return np.fromfile(model_dir / f'{name}.bin', dtype=np.uint8)

    wx = read('kernel').reshape(-1, 3, HIDDEN)
    wy = read('recurrent_kernel').reshape(HIDDEN, 3, HIDDEN)
    if not 1 <= len(wx) <= 256:
        raise ValueError("Expected 1–256 input channels")
    add = np.fromfile(add_table, dtype=np.uint8).reshape(256, 256)
    bias = add[read('bias'), read('recurrent_bias')].reshape(3, HIDDEN)
    head_weight = np.pad(read('head_weight').reshape(HIDDEN, 2), ((0, 0), (0, 2)))
    head_bias = np.pad(read('head_bias').reshape(2), (0, 2))

    image = bytearray(0x10000)
    for address, state in ((STATE_C, state_c), (STATE_Y, state_y)):
        if state is not None:
            if len(state) != HIDDEN:
                raise ValueError("Initial state must contain 256 FP8 bytes")
            image[address:address + HIDDEN] = state
    words, table = [], []
    constants = {}

    def alloc(values, alignment=8):
        payload = bytes(values)
        key = (alignment, payload)
        if key not in constants:
            image.extend(bytes(-len(image) % alignment))
            constants[key] = len(image)
            image.extend(payload)
            image.extend(bytes(-len(image) % 8))
        return constants[key]

    def reserve(size):
        address = len(image)
        image.extend(bytes(size))
        return address

    def dma(op, addr, row, rows):
        words.append((addr << 32) | (row << 16) | (rows << 8) | op)

    def vpu(op, ub_row, acc_row, rows):
        words.append((ub_row << 24) | (acc_row << 16) | (rows << 8) | op)

    def weight(row):
        words.append((row << 9) | 0x100 | WEIGHT)

    def repeat(weights, recurrent=False):
        width = weights.shape[1]
        rows = width // LANES
        stride = max(8, width)
        padded = np.pad(weights, ((0, 0), (0, stride - width)))
        table.extend([
            len(words) | (int(recurrent) << 25) | (len(weights) << 26) |
            ((rows.bit_length() - 1) << 35),
            alloc(padded.tobytes(), stride),
        ])

    def activate_column(op, destination):
        for start in (0, 32):
            vpu(op, 0, start, 32)
            dma(STORE_UB, destination + start * LANES, 0, 32)

    u, r, z = (reserve(HIDDEN) for _ in range(3))
    for gate, destination in enumerate((u, r)):
        dma(LOAD_ACC, alloc(bias[gate].tobytes()), 0, 64)
        repeat(wx[:, gate, :])
        repeat(wy[:, gate, :], recurrent=True)
        activate_column(SIGMOID, destination)

    dma(LOAD_ACC, alloc(bias[2].tobytes()), 0, 64)
    repeat(wy[:, 2, :], recurrent=True)
    # The UB holds 32 rows. Keep 16 rows each of r and z while computing r*z.
    for start in range(0, 64, 16):
        vpu(COPY, 0, start, 16)
        dma(LOAD_UB, r + start * LANES, 16, 16)
        for row in range(16):
            weight(16 + row)
            vpu(MUL, row, start + row, 1)
    repeat(wx[:, 2, :])
    activate_column(TANH, z)

    state_rows = 8
    ones = alloc(bytes([0x38]) * state_rows * LANES)
    threshold = alloc(read('threshold').reshape(HIDDEN).tobytes())
    ub_u, ub_t, ub_e, ub_f = (index * state_rows for index in range(4))

    def vector(op, weight_row, data_row):
        for row in range(state_rows):
            weight(weight_row + row)
            vpu(op, data_row + row, row, 1)

    for start in range(0, HIDDEN, state_rows * LANES):
        dma(LOAD_UB, u + start, ub_u, state_rows)
        dma(LOAD_UB, ones, ub_t, state_rows)
        vector(SUB, ub_u, ub_t)
        vpu(COPY, ub_t, 0, state_rows)
        dma(LOAD_UB, z + start, ub_e, state_rows)
        vector(MUL, ub_t, ub_e)
        dma(LOAD_UB, STATE_C + start, ub_e, state_rows)
        vector(MUL | ACCUMULATE, ub_u, ub_e)
        vpu(COPY, ub_e, 0, state_rows)
        dma(LOAD_UB, threshold + start, ub_t, state_rows)
        vector(SUB, ub_t, ub_e)
        vpu(STEP, ub_f, 0, state_rows)
        vector(MUL, ub_f, ub_t)
        vpu(COPY, ub_t, 0, state_rows)
        vector(SUB, ub_t, ub_e)
        dma(STORE_ACC, STATE_C + start, 0, state_rows)
        vector(MUL, ub_f, ub_e)
        dma(STORE_ACC, STATE_Y + start, 0, state_rows)

    dma(LOAD_ACC, alloc(head_bias.tobytes()), 0, 1)
    repeat(head_weight, recurrent=True)
    dma(STORE_ACC, FC_OUTPUT, 0, 1)
    words.append(SYNC)
    table.append(0x1FFFF)

    def encode(values):
        return b''.join(int(value).to_bytes(8, 'little') for value in values)

    encoded_table = encode(table)
    if len(image) > TABLE_BASE or TABLE_BASE + len(encoded_table) > HEADER_ADDR:
        raise ValueError("PSRAM image overlaps the boot configuration")
    image.extend(bytes(TABLE_BASE - len(image)))
    image.extend(encoded_table)
    image.extend(bytes(HEADER_ADDR - len(image)))
    image.extend(encode([len(wx) | (1 << 9) | (uart_clocks << 12)]))
    image.extend(encode(words))
    return bytes(image), len(wx), len(words)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model_dir', type=Path, help='FP8 weights as separate .bin files')
    parser.add_argument('add_table', type=Path, help='65,536-byte FP8 add table')
    parser.add_argument('output', type=Path, help='PSRAM binary image starting at address zero')
    parser.add_argument('--uart-clocks', type=int, default=0)
    parser.add_argument('--initial-c', type=Path)
    parser.add_argument('--initial-y', type=Path)
    args = parser.parse_args()
    image, _, _ = build_image(args.model_dir, args.add_table, args.uart_clocks,
        args.initial_c.read_bytes() if args.initial_c else None,
        args.initial_y.read_bytes() if args.initial_y else None)
    args.output.write_bytes(image)


if __name__ == '__main__':
    main()
