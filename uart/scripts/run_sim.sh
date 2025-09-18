#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--build-dir build] [--sim vvp] \\
                    [--log-dir out] [--testcases list]

Compiles the UART RTL plus the SystemVerilog regression testbench and runs
each requested testcase using Icarus Verilog (iverilog/vvp) by default.

Environment:
  IVERILOG     Override iverilog binary (default: iverilog)
  VVP          Override vvp binary (default: vvp)

Outputs:
  Builds <build-dir>/<test>.vvp and stores logs under <log-dir>/<test>/sim.log.
USAGE
}

BUILD_DIR="build"
SIM_BIN="vvp"
LOG_DIR="out"
TESTCASE_LIST="reg_access,loopback,parity_error,stop_bits,rx_overflow,rx_timeout,baud_sweep,flow_control"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --sim)
      SIM_BIN="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --testcases)
      TESTCASE_LIST="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

IVERILOG_BIN="${IVERILOG:-iverilog}"
VVP_BIN="${VVP:-$SIM_BIN}"

if ! command -v "$IVERILOG_BIN" >/dev/null 2>&1; then
  echo "Error: iverilog binary '$IVERILOG_BIN' not found" >&2
  exit 1
fi

if ! command -v "$VVP_BIN" >/dev/null 2>&1; then
  echo "Error: vvp binary '$VVP_BIN' not found" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UART_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TESTCASE_LIST=${TESTCASE_LIST//,/ }
read -r -a TESTCASES <<< "$TESTCASE_LIST"
if [[ ${#TESTCASES[@]} -eq 0 ]]; then
  TESTCASES=(loopback)
fi

SRC_RTL=(
  "$UART_ROOT/rtl/uart_apb.sv"
  "$UART_ROOT/rtl/uart_tx.sv"
  "$UART_ROOT/rtl/uart_rx.sv"
  "$UART_ROOT/rtl/uart_fifo.sv"
  "$UART_ROOT/rtl/uart_baud_gen.sv"
)

TB_BASE="$UART_ROOT/tb/uart_tb_base.sv"
if [[ ! -f "$TB_BASE" ]]; then
  echo "Error: base testbench '$TB_BASE' not found" >&2
  exit 1
fi

mkdir -p "$UART_ROOT/$BUILD_DIR" "$UART_ROOT/$LOG_DIR"
failures=0

for test in "${TESTCASES[@]}"; do
  TB_TOP="$UART_ROOT/tb/uart_tb_${test}.sv"
  if [[ ! -f "$TB_TOP" ]]; then
    echo "Error: testcase source '$TB_TOP' not found" >&2
    exit 1
  fi

  ELAB_OUT="$UART_ROOT/$BUILD_DIR/${test}.vvp"
  OUT_PATH="$UART_ROOT/$LOG_DIR/$test"
  LOG_FILE="$OUT_PATH/sim.log"
  mkdir -p "$OUT_PATH"

  echo "Running testcase '$test' (log: $LOG_FILE)"

  set -x
  "$IVERILOG_BIN" -g2012 -o "$ELAB_OUT" "${SRC_RTL[@]}" "$TB_BASE" "$TB_TOP"
  set +x

  if "$VVP_BIN" "$ELAB_OUT" >"$LOG_FILE" 2>&1; then
    echo "[PASS] $test"
  else
    echo "[FAIL] $test (see $LOG_FILE)"
    failures=$((failures + 1))
  fi
done

exit $failures
