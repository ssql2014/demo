# UART IP Verification Plan

## 1. Objectives
- Demonstrate functional correctness against PRD/design specification across configuration space (data bits, parity, stop bits, FIFO depths).
- Validate APB register interface behaviour, including read/write side effects, interrupts, and status reporting.
- Exercise reliability features (RX oversampling, error detection, FIFO overflow handling) under nominal and stressed conditions.
- Establish automation hooks so regressions can run on open-source simulators (e.g. Icarus Verilog) while remaining portable to commercial tools.

## 2. Verification Environments

| Environment | Description | Status |
|-------------|-------------|--------|
| SystemVerilog self-checking testbench | APB stimulus tasks, internal loopback, scoreboard for TX→RX checking. | Implemented (`tb/uart_tb_base.sv`). |
| Directed scenario benches | Focus on parity, stop bits, error injection; derived from base bench with parameter overrides. | Implemented (`tb/uart_tb_<case>.sv`). |
| (Optional) UVM environment | Full APB agent, coverage-driven sequences, scoreboard mirroring reference model. | Future enhancement. |

## 3. Test Matrix

| ID | Name | Description | Coverage Goals | Status |
|----|------|-------------|----------------|--------|
| T0 | Smoke loopback | Base regression: enable loopback, transmit pattern, ensure RX path/flags/IRQs behave. | Sanity of TX/RX datapath, APB DATA accesses, RX trigger interrupt. | Automated (`run_sim.sh`) |
| T1 | Parity modes | Sweep `PARITY_EN` with even/odd, verify expected parity bits and interrupt on mismatches (inject fault). | Parity FSM, INT bits, sticky error flags. | Automated (`parity_error`) |
| T2 | Stop-bit variations | Exercise 1-stop and 2-stop configurations, ensure RX tolerance and TX framing. | Stop sequencing, STATUS.IDLE/ BUSY flags. | Automated (`stop_bits`) |
| T3 | FIFO depth stress | Fill/empty FIFOs to boundaries, assert overflow/underflow reporting. | STATUS.RX_FULL/TX_FULL, OE errors. | Automated (`rx_overflow`) |
| T4 | Baud/OSR sweep | Vary divisors/OSR selection, confirm sampling alignment and throughput. | Baud generator operation, RX sampling counter. | Automated (`baud_sweep`) |
| T5 | CTS/RTS flow control (if enabled) | Gate TX on CTS, drive RTS thresholds. | Flow-control handshake. | Automated (`flow_control`) |
| T6 | Timeout interrupt | Configure timeout, idle RX line to trigger `RX_TIMEOUT_INT`. | Timeout counter, interrupt clears. | Automated (`rx_timeout`) |

## 4. Stimulus Strategy
- APB driver tasks provide cycle-accurate read/write sequencing and can be reused across benches.
- Directed sequences scripted in SystemVerilog tasks; reusable pattern arrays permit data-driven testing.
- Error injection performed by manipulating RXD (when not in loopback) through procedural tasks.

## 5. Checkers & Scoreboards
- Scoreboard queue compares expected TX payload with RX FIFO reads.
- Assertions (future) to cover protocol invariants: e.g., start bit low, stop bits high, no simultaneous FIFO full/empty.
- Sticky error flag verification via read-modify-clear checks.

## 6. Coverage Plan
- Functional coverage points (future):
  - Register field accesses (CTRL bits, INT enables).
  - Interrupt status cross coverage (source × enable × clear path).
  - FIFO level bins (empty, threshold, full).
  - Parity/stop/data-length combinations.
- Code coverage targeted via simulator reports; aim for 95%+ line/branch.

## 7. Regression Strategy
        - Tier-0: `scripts/run_sim.sh` smoke/regression (CI friendly, <1 min) using Icarus Verilog; compiles per-test top (`uart_tb_<case>.sv`) and archives logs under `uart/out/<case>/`.
- Tier-1: Extended directed benches executed sequentially.
- Tier-2: When UVM environment available, randomized regression with seed logging.

## 8. Deliverables
- Testbench sources under `uart/tb/`.
- Regression scripts under `uart/scripts/`.
- Logs/artifacts captured in `build/<test_name>`.
- Verification reports summarising pass/fail and coverage per milestone.

## 9. Schedule & Ownership
- Smoke test (T0) — completed.
- Stop-bit, FIFO overflow, parity, timeout, flow-control, and baud sweep scenarii — automated via directed benches.
- Additional corner cases (e.g., fractional baud, underflow) — pending.
- UVM expansion — optional, contingent on tool availability.
