# UART IP 产品需求文档（PRD）

版本：v1.1  
日期：2025-09-18

---

## 1. 产品概述
该 UART IP 为 SoC/MCU 提供标准的异步串行通信能力，采用 **APB** 作为寄存器编程总线，提供 **TXD/RXD** 标准接口与 **IRQ** 中断输出。设计目标：**易集成**、**高可靠**、**低面积/低功耗**、**高度参数化**。

---

## 2. 系统接口（Signal List）
> 约定：输入=I，输出=O，低有效后缀 `n`；无特别说明电平为高有效。

### 2.1 时钟与复位
| 信号 | Dir | 宽度 | 描述 |
|---|---|---|---|
| PCLK | I | 1 | APB/工作时钟，最高 50 MHz（默认）。 |
| PRESETn | I | 1 | 异步低有效复位，释放后同步到 `PCLK`。 |

### 2.2 APB 接口（32-bit）
| 信号 | Dir | 宽度 | 描述 |
|---|---|---|---|
| PSEL | I | 1 | 片选。 |
| PENABLE | I | 1 | 传输阶段指示。 |
| PWRITE | I | 1 | 1=写，0=读。 |
| PADDR | I | `APB_ADDR_WIDTH` | 地址（**字对齐**）。默认 6 位（覆盖 0x00~0x3F）。 |
| PWDATA | I | 32 | 写数据。 |
| PRDATA | O | 32 | 读数据。 |
| PREADY | O | 1 | 就绪；默认 **0 wait**（始终 1），可参数化插入等待。 |
| PSLVERR | O | 1 | 错误响应（保留，默认 0）。 |

### 2.3 UART 引脚
| 信号 | Dir | 宽度 | 描述 |
|---|---|---|---|
| TXD | O | 1 | 串行发送输出。空闲为高。 |
| RXD | I | 1 | 串行接收输入。 |
| RTS (可选) | O | 1 | 请求发送（流控），极性可配（默认不实例化）。 |
| CTS (可选) | I | 1 | 允许发送（流控），极性可配（默认不实例化）。 |

### 2.4 中断
| 信号 | Dir | 描述 |
|---|---|---|
| IRQ | O | 中断输出，电平有效（至少一个已使能的中断挂起）。 |

---

## 3. 功能特性
- **通信格式**:
    - 数据位：7/8 位
    - 停止位：1/2 位
    - 奇偶校验：无/奇/偶
- **波特率**: 范围 1.2 kbps ~ 1 Mbps（更高速率取决于 `PCLK` 与分频设定）。
- **FIFO**: 独立的 RX/TX FIFO，深度参数化（典型 8/16/32 字节）。
- **中断源**: RX 阈值、TX 阈值/空、接收超时、帧错误、奇偶错误、溢出错误、接收完成、发送完成。
- **错误检测**: 帧错误 (FE), 奇偶校验错误 (PE), 溢出错误 (OE)。
- **低功耗**: 支持时钟门控；`UART_EN=0` 时可进入低功耗模式。

---

## 4. 异步输入的可靠性设计 (RX)
1.  **同步器**: `RXD` 输入通过两级（可配置为三级）D触发器同步到 `PCLK`，以降低亚稳态风险。
2.  **过采样**: 采用 ×16 过采样率（可配置为 ×8/×4），在一个比特周期内多次采样。
3.  **起始位检测与对齐**: 检测到下降沿后，延迟半个比特周期在 **中点** 进行二次确认，并以此为基准对齐后续数据位、奇偶校验位和停止位的采样。
4.  **判决策略**: 采用中点采样或 3/5 多数投票（实现可选）来判定比特值。
5.  **时钟偏差容忍度**: 设计需保证在两端时钟偏差 ±2% ~ ±5% 的范围内仍能稳健解码。
6.  **错误处理**: 停止位不为高电平则标记为帧错误（FE）；校验不符则标记为奇偶校验错误（PE）；RX FIFO 满后仍接收到数据则标记为溢出错误（OE）。所有错误均有状态位并可触发中断。

---

## 5. 参数化配置 (Generics)
| 参数 | 缺省值 | 说明 |
|---|---|---|
| APB_ADDR_WIDTH | 6 | APB 地址宽度（字对齐），决定寄存器地址空间大小。 |
| FIFO_DEPTH | 16 | RX/TX FIFO 深度（例如 8, 16, 32）。 |
| DEFAULT_OSR | 16 | 默认过采样倍率（例如 4, 8, 16）。 |
| FRACTIONAL_BAUD | 1 | 是否启用小数波特率分频器 (1=启用, 0=禁用)。 |
| HAS_RTS_CTS | 0 | 是否实例化 RTS/CTS 流控逻辑 (1=是, 0=否)。 |
| SYNC_STAGES | 2 | RXD 输入同步器的级数 (2 或 3)。 |

---

## 6. 寄存器映射与位域 (Register Map)
> **访问权限**: `R/W`=可读写, `RO`=只读, `WO`=只写, `R/W1C`=读写/写1清零。  
> **复位值**: `PRESETn` 异步复位释放后，在 `PCLK` 域同步后的值。

### 6.1 地址映射
| 偏移 (Offset) | 名称 (Name) | 访问 (Access) | 复位值 (Reset Value) | 描述 (Description) |
|---|---|---|---|---|
| 0x00 | DATA | R/W | 0x0000_0000 | 收/发数据窗口。 |
| 0x04 | STATUS | RO | 0x0000_0082 | 即时状态标志 (TX FIFO 空, IDLE 等)。 |
| 0x08 | CTRL | R/W | 0x0000_0007 | 全局控制 (使能, 数据格式等)。 |
| 0x0C | BAUD | R/W | 0x0000_0000 | 波特率分频器配置。 |
| 0x10 | FIFO_CTRL | R/W | 0x0000_0000 | FIFO 控制 (清空, 水位阈值, 超时)。 |
| 0x14 | INT_STATUS | R/W1C | 0x0000_0000 | 中断状态。 |
| 0x18 | INT_ENABLE | R/W | 0x0000_0000 | 中断使能/屏蔽。 |
| 0x1C | INT_CLEAR | WO | N/A | 中断清除 (写1清除对应中断)。 |
| 0x20 | FIFO_LEVEL | RO | 0x0000_0000 | RX/TX FIFO 实时深度。 |
| 0x24 | VERSION | RO | 0x0110_2509 | 版本与日期 (v1.1, 2025-09-18)。 |

### 6.2 寄存器详解

#### DATA @ 0x00 (R/W)
| 位段 | 名称 | 描述 |
|---|---|---|
| [7:0] | DATA | 数据位。 |
| [31:8] | RSV | 保留，读为0。 |
> **Side Effect**:
> - **读**: 当 RX FIFO 非空时，从 FIFO 弹出一个字节。若为空，返回值未定义或为0。
> - **写**: 当 TX FIFO 未满时，向 FIFO 推入一个字节。若已满，该次写入被忽略，并可选择置位 `STATUS.TX_WERR` 标志。

#### STATUS @ 0x04 (RO)
| 位 | 名称 | 描述 |
|---|---|---|
| 0 | RX_NONEMPTY | RX FIFO 非空 (`RX_LEVEL > 0`)。 |
| 1 | TX_EMPTY | TX FIFO 为空 (`TX_LEVEL == 0`)。 |
| 2 | RX_FULL | RX FIFO 已满。 |
| 3 | TX_FULL | TX FIFO 已满。 |
| 4 | RX_BUSY | 接收器正在采样或组帧。 |
| 5 | TX_BUSY | 发送器正在移位发送。 |
| 6 | ERR_ANY | 任何一个错误 (`FE`, `PE`, `OE`) 发生。 |
| 7 | IDLE | 收发均空闲且 TX FIFO 为空。 |
| 8 | FE | 帧错误标志。 |
| 9 | PE | 奇偶校验错误标志。 |
| 10 | OE | 接收溢出错误标志。 |
| 11 | TX_WERR | TX FIFO 满时尝试写入 (可选功能)。 |

#### CTRL @ 0x08 (R/W)
| 位 | 名称 | 描述 |
|---|---|---|
| 0 | UART_EN | 1: 使能 UART 模块。0: 禁用 (低功耗)。 |
| 1 | RX_EN | 1: 使能接收路径。 |
| 2 | TX_EN | 1: 使能发送路径。 |
| 3 | LOOPBACK_EN | 1: 开启内部回环模式 (TX->RX)，用于自测。 |
| 5:4 | DATA_LEN | `00`: 8位, `01`: 7位。 |
| 6 | PARITY_EN | 1: 启用奇偶校验。 |
| 7 | PARITY_ODD | 1: 奇校验, 0: 偶校验 (当 `PARITY_EN=1` 时有效)。 |
| 8 | STOP_2 | 1: 2个停止位, 0: 1个停止位。 |
| 13:10 | OSR_SEL | 过采样率选择: `0`: ×16, `1`: ×8, `2`: ×4。 |

#### BAUD @ 0x0C (R/W)
| 位段 | 名称 | 描述 |
|---|---|---|
| [15:0] | DIV_INT | 波特率分频器的整数部分。 |
| [23:16] | DIV_FRAC | 小数部分 (步进 1/256)。 |
> **公式**: Baud Rate = PCLK / (OSR × (DIV_INT + DIV_FRAC/256))

#### FIFO_CTRL @ 0x10 (R/W)
| 位段 | 名称 | 描述 |
|---|---|---|
| 0 | RX_CLR | 写1清空 RX FIFO (自复位为0)。 |
| 1 | TX_CLR | 写1清空 TX FIFO (自复位为0)。 |
| 5:2 | RX_TRIG | RX FIFO 中断触发阈值 (字节数)。 |
| 9:6 | TX_TRIG | TX FIFO 中断触发阈值 (字节数)。 |
| 13:10 | TIMEOUT_CFG | 接收超时门限 (单位：字符时间)。 |
| 23:16 | FIFO_DEPTH | **(RO)** 硬件实例化的 FIFO 深度。 |

#### INT_STATUS / INT_ENABLE / INT_CLEAR @ 0x14 / 0x18 / 0x1C
| 位 | 名称 | 描述 |
|---|---|---|
| 0 | RX_TRIG_INT | RX FIFO 水位达到 `RX_TRIG`。 |
| 1 | TX_TRIG_INT | TX FIFO 水位低于 `TX_TRIG`。 |
| 2 | RX_TIMEOUT_INT | 接收总线空闲超时。 |
| 3 | FE_INT | 帧错误中断。 |
| 4 | PE_INT | 奇偶校验错误中断。 |
| 5 | OE_INT | 溢出错误中断。 |
| 6 | RX_DONE_INT | 一帧接收完成。 |
| 7 | TX_DONE_INT | 一帧发送完成。 |
> **Side Effect**:
> - `INT_STATUS` (R/W1C): 读此寄存器返回中断状态；写1到某位会清除该位的中断状态。
> - `INT_ENABLE` (R/W): 中断屏蔽寄存器，对应位为1时才允许中断发出。
> - `INT_CLEAR` (WO): 写1到某位等效于对 `INT_STATUS` 的相应位写1。
> - **中断逻辑**: `IRQ = OR(INT_STATUS & INT_ENABLE)`

---

## 7. 验证需求
- **功能覆盖**:
    - 所有寄存器字段的读写与功能正确性。
    - 所有中断源的触发、屏蔽与清除。
    - 所有错误条件的注入与检测。
- **边界与异常场景**:
    - FIFO 满/空状态下的连续读写。
    - 波特率在最大/最小值及存在时钟偏差 (±5%) 时的收发。
    - 在数据传输过程中触发复位。
    - 背靠背 (Back-to-back) 连续帧传输。
- **性能场景**:
    - 最高波特率下的吞吐量测试。
    - 低功耗模式的进入与唤醒。

---

## 8. 交付物
- RTL 代码 (SystemVerilog/Verilog)
- 综合约束与脚本示例
- UVM 验证环境与测试用例
- 用户手册 (本文档)
- C 语言驱动示例

---

## 附录 A: 快速编程示例
```c
// 假设基地址为 UART_BASE
#define UART_REG(offset) (*(volatile unsigned int *)(UART_BASE + offset))

// 1. 初始化: 115200bps @ 50MHz, 8N1, OSR=16
// Baud Rate = 50M / (16 * (27 + 32/256)) ≈ 115200
UART_REG(0x0C) = (27 << 0) | (32 << 16); // BAUD: DIV_INT=27, DIV_FRAC=32
UART_REG(0x08) = (1 << 0) | (1 << 1) | (1 << 2); // CTRL: Enable UART, RX, TX
UART_REG(0x10) = (4 << 2); // FIFO_CTRL: RX_TRIG = 4 bytes
UART_REG(0x18) = (1 << 0) | (1 << 3) | (1 << 4) | (1 << 5); // INT_ENABLE: RX_TRIG, FE, PE, OE

// 2. 发送一个字节 (轮询方式)
void uart_putc(char c) {
    // 等待 TX FIFO 不满
    while (UART_REG(0x04) & (1 << 3)) {} // STATUS.TX_FULL
    UART_REG(0x00) = c; // DATA
}

// 3. 中断服务程序 (ISR) 示例
void uart_isr(void) {
    unsigned int status = UART_REG(0x14); // INT_STATUS

    if (status & (1 << 0)) { // RX_TRIG_INT
        // 读取所有接收到的数据，直到 FIFO 为空
        while (UART_REG(0x04) & (1 << 0)) { // STATUS.RX_NONEMPTY
            char c = UART_REG(0x00);
            // process(c);
        }
    }

    if (status & 0x38) { // Error Interrupts (FE, PE, OE)
        // handle_error();
    }

    // 清除已处理的中断
    UART_REG(0x14) = status;
}
```
