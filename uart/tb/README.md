# UART RTL Regression Testbench

`uart_tb_base.sv` holds the reusable APB/UART stimulus, while each scenario has
its own top-level wrapper:

- `uart_tb_reg_access.sv`
- `uart_tb_loopback.sv`
- `uart_tb_parity_error.sv`
- `uart_tb_stop_bits.sv`
- `uart_tb_rx_overflow.sv`
- `uart_tb_rx_timeout.sv`
- `uart_tb_baud_sweep.sv`
- `uart_tb_flow_control.sv`

## Running with open-source tools

```sh
# From repo root (preferred)
./uart/scripts/run_sim.sh
# Logs are saved under uart/out/<testcase>/sim.log

# Manual compile/run if you need custom arguments
mkdir -p build
iverilog -g2012 -o build/loopback.vvp \
  uart/rtl/uart_apb.sv \
  uart/rtl/uart_tx.sv \
  uart/rtl/uart_rx.sv \
  uart/rtl/uart_fifo.sv \
  uart/rtl/uart_baud_gen.sv \
  uart/tb/uart_tb_base.sv \
  uart/tb/uart_tb_loopback.sv

vvp build/loopback.vvp
```

Use `./uart/scripts/run_sim.sh --testcases "loopback parity_error"` to restrict
to specific scenarios or `--log-dir mylogs` to change the output folder.

## Pseudo C setup sequence (loopback smoke)

```c
// Assume `UART_REG(off)` macro defined as in PRD appendix
UART_REG(0x0C) = 0x0000_0010;          // BAUD: div_int = 16, div_frac = 0
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
