#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--top uart_tb] [--build-dir build] [--sim vvp]

Compiles the UART RTL plus the SystemVerilog smoke testbench and runs it using
Icarus Verilog (iverilog/vvp) by default.

Environment:
  IVERILOG     Override iverilog binary (default: iverilog)
  VVP          Override vvp binary (default: vvp)

Outputs:
  Builds <build-dir>/uart_tb.vvp and writes simulation transcript to stdout.
USAGE
}

TOP="uart_tb"
BUILD_DIR="build"
SIM_BIN="vvp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --top)
      TOP="$2"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --sim)
      SIM_BIN="$2"
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

SRC_RTL=(
  "$UART_ROOT/rtl/uart_apb.sv"
  "$UART_ROOT/rtl/uart_tx.sv"
  "$UART_ROOT/rtl/uart_rx.sv"
  "$UART_ROOT/rtl/uart_fifo.sv"
  "$UART_ROOT/rtl/uart_baud_gen.sv"
)

TB_SRC="$UART_ROOT/tb/${TOP}.sv"
if [[ ! -f "$TB_SRC" ]]; then
  echo "Error: testbench '$TB_SRC' not found" >&2
  exit 1
fi

mkdir -p "$UART_ROOT/$BUILD_DIR"
ELAB_OUT="$UART_ROOT/$BUILD_DIR/${TOP}.vvp"

set -x
"$IVERILOG_BIN" -g2012 -o "$ELAB_OUT" "${SRC_RTL[@]}" "$TB_SRC"
"$VVP_BIN" "$ELAB_OUT"
set +x
