"""Cocotb driver for the pin-level Tiny Tapeout smoke test."""

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def completes_qpi_boot_and_uart_exchange(dut):
    # SystemVerilog asserts the FP8 payload and exposes completion here.
    for _ in range(1000):
        await Timer(1, unit="us")
        if dut.done.value == 1:
            return
    assert False, "UART/QPI exchange did not complete"
