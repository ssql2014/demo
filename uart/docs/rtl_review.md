# UART RTL Code Review (2025-09-18)

## 1. 总体评价

代码结构清晰，模块划分合理，与 `prd.md` 和 `design_spec.md` 的功能描述高度一致。RTL 代码是一个非常好的起点。

在现有基础上，发现一些可以改进的地方，主要集中在**代码健壮性、时序逻辑和参数化**方面。这些修改旨在提升代码的可综合性、可维护性和在真实硬件中的可靠性。

---

## 2. 具体建议

### 2.1 `uart_apb.sv` (顶层模块)

#### a. APB 读操作的时序假设

- **问题**: `rx_fifo_rd_en` 在 APB 的 `setup_phase` (`PSEL && !PENABLE`) 就被置位。这会使 FIFO 的读使能提前一个时钟周期有效，此时 `PRDATA` 可能还没有准备好。标准的 APB 协议要求在 `access_phase` (`PSEL && PENABLE`) 进行数据传输。
- **建议**: 将 `rx_fifo_rd_en` 的触发条件从 `apb_read_setup` 改为 `apb_read`。
  ```systemverilog
  // 建议修改为:
  assign rx_fifo_rd_en = apb_read && (addr_q == ADDR_DATA);
  ```
  这能确保仅在 APB 读传输阶段才从 FIFO 读取数据。

#### b. 状态寄存器位域不匹配

- **问题**: `STATUS` 寄存器的定义 (`status_word`) 与 `prd.md` 中的定义不完全一致。例如，`prd.md` 的 `STATUS[1]` 是 `RX_FULL`，而代码中是 `TX_EMPTY`。
- **建议**: 调整 `status_word` 的位域分配，使其与 `prd.md` 中 `STATUS @0x04 (RO)` 的定义严格保持一致，以确保软件驱动的正确性。

#### c. 中断清除逻辑

- **问题**: `INT_STATUS` 和 `INT_CLEAR` 寄存器在中断清除逻辑中的作用是等价的，但 `always_ff` 块中对它们的处理可以合并，使其更简洁。
- **建议**: 简化中断清除逻辑。可以创建一个 `int_clear_mask` 信号，它由对 `INT_STATUS` 或 `INT_CLEAR` 的写操作产生，然后用这个 mask 来清除 `reg_int_status`。
  ```systemverilog
  logic [7:0] int_clear_mask;
  assign int_clear_mask = (apb_write && (addr_q == ADDR_INT_STATUS)) ? PWDATA[7:0] :
                          (apb_write && (addr_q == ADDR_INT_CLEAR))  ? PWDATA[7:0] : 8'd0;

  // 在 always_ff 块中:
  reg_int_status <= (reg_int_status | int_set_mask) & ~int_clear_mask;
  ```

---

### 2.2 `uart_fifo.sv` (FIFO 模块)

#### a. 读数据路径可能存在组合逻辑

- **问题**: `rd_data` 是在 `always_ff` 块中赋值的，但它直接读取 `mem[rd_ptr]`。如果 `rd_ptr` 在同一个时钟周期内更新，这可能会在综合后形成一个不期望的时序路径。
- **建议**: 采用“先读后更新指针”的策略。为了让输出更稳定，可以将 `rd_data` 的输出寄存一拍，但这会增加一拍延迟。一个更安全的做法是让 `rd_data` 在 `rd_fire` 的下一个周期有效，或者保持现有逻辑但仔细检查综合报告以确认时序。

---

### 2.3 `uart_rx.sv` (接收模块)

#### a. 状态机中的采样时序假设

- **问题**: 在 `ST_START` 状态，代码在 `osr_tick` 的驱动下计数到 `osr_mid - 1`，然后采样 `rxd`。这依赖于 `osr_tick` 在每个时钟周期都会变，但 `uart_baud_gen` 产生的 `osr_tick` 是一个单周期脉冲。这可能导致采样点错位或状态机卡死。
- **建议**: 简化采样逻辑。在检测到 `start_edge` 后，状态机进入 `ST_START`，然后等待 `osr_mid` 个 `osr_tick` 脉冲，再进行第一次采样。之后每个比特的采样都等待 `osr_value` 个 `osr_tick` 脉冲。这需要一个单独的计数器来对 `osr_tick` 脉冲进行计数。

---

### 2.4 `uart_tx.sv` (发送模块)

#### a. `compute_parity` 函数的 `for` 循环

- **问题**: 在函数中使用 `for` 循环是合法的，但某些综合工具可能对其支持不佳或产生复杂的组合逻辑。
- **建议**: 将 `compute_parity` 函数改为一个纯组合逻辑的 `assign` 语句，使用 `^` (缩减异或) 操作符来计算奇偶校验位。这在语法上更清晰，且对综合工具更友好。
  ```systemverilog
  function automatic logic compute_parity(input logic [7:0] data, input logic [3:0] bits, input logic odd);
      logic parity_calc;
      case (bits)
          4'd7: parity_calc = ^data[6:0];
          4'd8: parity_calc = ^data[7:0];
          default: parity_calc = ^data[7:0];
      endcase
      compute_parity = odd ? ~parity_calc : parity_calc;
  endfunction
  ```
  或者，直接在模块中用 `assign` 实现。

---

## 3. 总结

核心建议:
1.  **修正 `uart_apb.sv` 中的 APB 读时序和 `STATUS` 寄存器位域。**
2.  **优化 `uart_tx.sv` 中的奇偶校验计算方式，使其对综合更友好。**
3.  **审视并加固 `uart_rx.sv` 中的采样逻辑，确保其在 `osr_tick` 脉冲信号下的可靠性。**

这些修改将显著提升设计的稳健性。
