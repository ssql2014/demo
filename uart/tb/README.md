# UART RTL Smoke Testbench

A lightweight SystemVerilog testbench (`uart_tb.sv`) exercises the APB register interface and UART datapaths using the built-in loopback mode. The flow is:

1. Apply reset, program a fast baud divisor, set FIFO/interrupt thresholds.
2. Enable loopback and push four bytes into the TX FIFO via APB writes.
3. Wait for the RX FIFO to report data, read each byte back, and compare.

## Running with open-source tools

# From repo root
mkdir -p build
# From repo root (preferred)
./uart/scripts/run_sim.sh

# Manual compile/run if you need custom arguments
iverilog -g2012 -o build/uart_tb.vvp \
  uart/rtl/uart_apb.sv \
  uart/rtl/uart_tx.sv \
  uart/rtl/uart_rx.sv \
  uart/rtl/uart_fifo.sv \
  uart/rtl/uart_baud_gen.sv \
  uart/tb/uart_tb.sv

vvp build/uart_tb.vvp
```

Expected output ends with `UART smoke test PASSED`.

If `iverilog` is not installed, use any SystemVerilog-capable simulator and run the same top-level.

## Pseudo C setup sequence

The pseudo-code below mirrors the testbench configuration for firmware bring-up:

```c
// Assume `UART_REG(off)` macro defined as in PRD appendix
UART_REG(0x0C) = 0x0000_0001;          // BAUD: div_int = 1, div_frac = 0
UART_REG(0x10) = (1u << 2);           // FIFO_CTRL: RX_TRIG = 1 byte
UART_REG(0x18) = (1u << 0) | (1u << 6); // INT_ENABLE: RX_TRIG + RX_DONE
UART_REG(0x08) = 0x0000_000F;         // CTRL: enable | RX_EN | TX_EN | LOOPBACK

uint8_t pattern[] = {0x55, 0xA5, 0x5A, 0xFF};
for (unsigned i = 0; i < sizeof(pattern); ++i) {
    while (UART_REG(0x04) & (1u << 3)) { /* wait for TX not full */ }
    UART_REG(0x00) = pattern[i];
}

for (unsigned i = 0; i < sizeof(pattern); ++i) {
    while (!(UART_REG(0x04) & (1u << 0))) { /* wait for RX data */ }
    uint8_t val = UART_REG(0x00);
    // compare against expected pattern[i]
}
```
