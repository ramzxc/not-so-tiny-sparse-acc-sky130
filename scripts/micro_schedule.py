"""Instruction words for streaming retained-configuration MICRO tiles.

Send each word only after a UART READY credit. MICRO blocks subsequent dispatch
until RUN completes, so no intermediate SYNC is required between these runs.
Input/output movement and configuration commands must still be supplied by the
caller. This helper does not reorder arithmetic or change sparse/dense mode.
"""


def restore_run(input_address, weight_address, columns, *, input_sram=True,
                sparse=True, staging_high=None):
    """Restore consumed fields; omit an ADDR high word only when already known.

    Default is conservative. After a successful, nonempty auto-DMA RUN with SRAM
    input, the staging address high word is zero: its final memory command is
    an SRAM input read or accumulation. A caller chaining such runs may pass 0.
    Invalidate this knowledge across other commands, errors, or unknown/no-op
    runs. Flash-input callers must not infer the same postcondition.
    """
    if not 0 <= input_address < 1 << 24 or not 0 <= weight_address < 1 << 24:
        raise ValueError('addresses must fit 24 bits')
    if not 1 <= columns <= 255:
        raise ValueError('columns must be in 1..255')
    words = []
    for address, capture in [(input_address, 0xa000 | int(input_sram)),
                             (weight_address, 0xa400)]:
        words.append(0x2000 | (address & 0xfff))
        if staging_high != address >> 12:
            words.append(0x3000 | (address >> 12))
        staging_high = address >> 12
        words.append(capture)
    return words + [0xb000 | columns, 0xb402 | int(sparse)]
