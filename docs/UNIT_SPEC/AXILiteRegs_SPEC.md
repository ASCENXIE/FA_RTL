# `fa_axi_lite_regs` 规格说明

## 1. 模块概述

`fa_axi_lite_regs` 是 Flash Attention 加速器中的 AXI4-Lite CSR/寄存器模块。

该模块作为 AXI4-Lite 从设备工作。软件通过 AXI4-Lite 接口访问内部寄存器；模块内部保存软件配置的控制/配置寄存器，生成单周期控制脉冲，并将执行通路输入的状态和性能信息映射为软件可读寄存器。

## 2. 接口说明

### 2.1 时钟与复位

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `clk` | input | 1 | 寄存器模块工作时钟。AXI4-Lite 接口和 CSR 逻辑均同步于该时钟。 |
| `rst_n` | input | 1 | 低有效复位。复位 AXI4-Lite 内部控制状态，并将可写寄存器恢复为默认值。 |

### 2.2 AXI4-Lite Slave 接口

AXI4-Lite 从接口数据宽度为 32 bit，字节写使能宽度为 4 bit。

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `s_axil_awaddr` | input | 32 | 写地址。 |
| `s_axil_awvalid` | input | 1 | 写地址有效。 |
| `s_axil_awready` | output | 1 | 写地址就绪。 |
| `s_axil_wdata` | input | 32 | 写数据。 |
| `s_axil_wstrb` | input | 4 | 字节写使能。`WSTRB[n]` 对应字节 `8*n +: 8`。 |
| `s_axil_wvalid` | input | 1 | 写数据有效。 |
| `s_axil_wready` | output | 1 | 写数据就绪。 |
| `s_axil_bresp` | output | 2 | 写响应。 |
| `s_axil_bvalid` | output | 1 | 写响应有效。 |
| `s_axil_bready` | input | 1 | 写响应就绪。 |
| `s_axil_araddr` | input | 32 | 读地址。 |
| `s_axil_arvalid` | input | 1 | 读地址有效。 |
| `s_axil_arready` | output | 1 | 读地址就绪。 |
| `s_axil_rdata` | output | 32 | 读数据。 |
| `s_axil_rresp` | output | 2 | 读响应。 |
| `s_axil_rvalid` | output | 1 | 读响应有效。 |
| `s_axil_rready` | input | 1 | 读响应就绪。 |

### 2.3 硬件侧 CSR 接口

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `ctrl_start_pulse` | output | 1 | 软件写 `CTRL.START = 1` 时产生的单周期启动脉冲。 |
| `ctrl_soft_reset` | output | 1 | 软件写 `CTRL.SOFT_RESET = 1` 时产生的单周期软复位脉冲。 |
| `ctrl_done_clr` | output | 1 | 软件写 `STATUS.DONE = 1` 时产生的单周期完成状态清除请求。 |
| `ctrl_irq_en` | output | 1 | `CTRL.IRQ_EN` 的保持型配置输出。 |
| `ctrl_causal_en` | output | 1 | `CFG.CAUSAL_EN` 的保持型配置输出。 |
| `cfg_q_base` | output | 64 | Q 矩阵基地址，等于 `{Q_BASE_H, Q_BASE_L}`。 |
| `cfg_k_base` | output | 64 | K 矩阵基地址，等于 `{K_BASE_H, K_BASE_L}`。 |
| `cfg_v_base` | output | 64 | V 矩阵基地址，等于 `{V_BASE_H, V_BASE_L}`。 |
| `cfg_o_base` | output | 64 | O 矩阵基地址，等于 `{O_BASE_H, O_BASE_L}`。 |
| `cfg_stride_bytes` | output | 32 | `STRIDE_BYTES` 的保持型配置输出。 |
| `cfg_neg_large` | output | 32 | `NEG_LARGE` 的保持型配置输出。具体定点格式由计算通路解释。 |
| `cfg_scale` | output | 32 | `SCALE` 的保持型配置输出。具体定点格式由计算通路解释。 |
| `status_busy` | input | 1 | 来自执行通路的 busy 状态。 |
| `status_done` | input | 1 | 来自执行通路的 done 状态。 |
| `status_error` | input | 1 | 来自执行通路的 error 状态。 |
| `perf_cycles` | input | 32 | 来自执行通路或性能计数逻辑的周期计数。 |

## 3. 功能行为

### 3.1 AXI4-Lite 事务模型

本模块实现一个适用于 CSR 访问的简单 AXI4-Lite 从设备模型。

- 数据宽度为 32 bit。
- 寄存器 offset 按 word 对齐。
- 模块可同时维护一个读事务和一个写事务。
- 写地址通道和写数据通道允许独立到达；只有当写地址和写数据均被接收后，写操作才生效。
- 读地址被接收后，读数据通过 AXI4-Lite 读响应通道返回。
- 所有已定义寄存器访问均返回 `OKAY`。
- 对未定义或保留地址的访问也返回 `OKAY`；读返回 `0`，写被忽略。

### 3.2 写语义

本模块支持 AXI4-Lite 标准 `WSTRB` 按字节写语义。

- 对保持型可写寄存器，仅更新 `WSTRB` 选中的字节。
- 对单周期脉冲字段，仅当对应字节 lane 被 `WSTRB` 选中，且写入 bit 为 `1` 时，才产生脉冲。
- 对只读字段的写入被忽略。
- 对保留字段的写入被忽略。

### 3.3 读语义

- 读操作返回被访问寄存器在读响应时刻的当前值。
- 保留 bit 读出为 `0`。
- 仅脉冲型控制 bit 读出为 `0`。
- 跨多个寄存器组成的值，例如 64 bit base address，不保证多次读之间具备原子快照语义。软件应避免在加速器运行期间更新这些配置寄存器。

### 3.4 复位语义

当 `rst_n` 被拉低时：

- AXI4-Lite 内部控制状态被复位。
- 所有单周期脉冲输出被清零。
- 可写保持型寄存器恢复为默认值。
- 只读状态寄存器在复位后反映外部输入信号的当前值。

`CTRL.SOFT_RESET` 不复位 `fa_axi_lite_regs` 自身。它只向下游执行通路输出一个 `ctrl_soft_reset` 单周期脉冲。

## 4. 寄存器映射

访问类型定义如下。

| 访问类型 | 含义 |
|---|---|
| `RO` | 只读。写入被忽略。 |
| `RW` | 可读写保持型字段。 |
| `W1P` | Write-One-to-Pulse。写 `1` 产生单周期硬件脉冲，读出为 `0`。 |
| `W1C` | Write-One-to-Clear request。写 `1` 产生单周期清除请求脉冲。 |
| `RSVD` | 保留字段。读出为 `0`，写入被忽略。 |

所有寄存器宽度均为 32 bit。

| Offset | 寄存器名 | 访问类型 | 复位值 | Bit Field | 说明 |
|---:|---|---|---:|---|---|
| `0x00` | `CTRL` | mixed | `0x0000_0000` | `[0] START` `W1P` | 写 `1` 产生 `ctrl_start_pulse`。 |
|  |  |  |  | `[1] SOFT_RESET` `W1P` | 写 `1` 产生 `ctrl_soft_reset`。 |
|  |  |  |  | `[2] IRQ_EN` `RW` | 中断使能配置位。本模块只负责保存并输出该 bit。 |
|  |  |  |  | `[31:3] RSVD` | 保留。 |
| `0x04` | `STATUS` | mixed | external | `[0] BUSY` `RO` | 映射外部输入 `status_busy`。 |
|  |  |  |  | `[1] DONE` `RO/W1C` | 映射外部输入 `status_done`。写 `1` 产生 `ctrl_done_clr`。 |
|  |  |  |  | `[2] ERROR` `RO` | 映射外部输入 `status_error`。 |
|  |  |  |  | `[31:3] RSVD` | 保留。 |
| `0x08` | `CFG` | mixed | `0x0000_0000` | `[0] CAUSAL_EN` `RW` | 使能 causal attention 模式。baseline 实现必须支持该 bit。 |
|  |  |  |  | `[31:1] RSVD` | 保留。 |
| `0x0C` | `RESERVED` | RSVD | `0x0000_0000` | `[31:0] RSVD` | 保留地址。 |
| `0x10` | `RESERVED` | RSVD | `0x0000_0000` | `[31:0] RSVD` | 保留地址。 |
| `0x14` | `Q_BASE_L` | RW | `0x0000_0000` | `[31:0] Q_BASE_L` | Q 基地址低 32 bit。 |
| `0x18` | `Q_BASE_H` | RW | `0x0000_0000` | `[31:0] Q_BASE_H` | Q 基地址高 32 bit。 |
| `0x1C` | `K_BASE_L` | RW | `0x0000_0000` | `[31:0] K_BASE_L` | K 基地址低 32 bit。 |
| `0x20` | `K_BASE_H` | RW | `0x0000_0000` | `[31:0] K_BASE_H` | K 基地址高 32 bit。 |
| `0x24` | `V_BASE_L` | RW | `0x0000_0000` | `[31:0] V_BASE_L` | V 基地址低 32 bit。 |
| `0x28` | `V_BASE_H` | RW | `0x0000_0000` | `[31:0] V_BASE_H` | V 基地址高 32 bit。 |
| `0x2C` | `O_BASE_L` | RW | `0x0000_0000` | `[31:0] O_BASE_L` | O 基地址低 32 bit。 |
| `0x30` | `O_BASE_H` | RW | `0x0000_0000` | `[31:0] O_BASE_H` | O 基地址高 32 bit。 |
| `0x34` | `STRIDE_BYTES` | RW | `DEFAULT_STRIDE_BYTES` | `[31:0] STRIDE_BYTES` | 行 stride，单位为 byte。baseline 默认值为 `HEAD_DIM * ELEM_BYTES`，FP16 场景通常为 `d * 2`。 |
| `0x38` | `NEG_LARGE` | RW | `DEFAULT_NEG_LARGE` | `[31:0] NEG_LARGE` | 近似负无穷值，例如 Q8.8 格式。具体数值解释由计算通路负责。 |
| `0x3C` | `SCALE` | RW | `DEFAULT_SCALE` | `[31:0] SCALE` | Softmax 缩放系数，通常为 `1 / sqrt(d)`。具体定点格式由计算通路负责。 |
| `0x40` | `CYCLES` | RO | external | `[31:0] CYCLES` | 映射外部输入 `perf_cycles`。寄存器模块内部不负责计数。 |

## 5. 寄存器字段说明

### 5.1 `CTRL`

`CTRL.START` 和 `CTRL.SOFT_RESET` 是命令型 bit，不是保持型配置 bit。软件成功写入对应 bit 为 `1` 后，模块生成单周期脉冲；这些 bit 读回为 `0`。

`CTRL.IRQ_EN` 是保持型配置 bit。模块将其输出为 `ctrl_irq_en`。如果系统需要中断产生逻辑，应在本模块外部实现，例如将 `ctrl_irq_en` 与 done 或 error 条件组合。

### 5.2 `STATUS`

`STATUS.BUSY`、`STATUS.DONE` 和 `STATUS.ERROR` 均由外部执行通路驱动。`fa_axi_lite_regs` 不在内部生成这些状态。

软件写 `STATUS.DONE = 1` 时，模块生成 `ctrl_done_clr` 单周期脉冲。下游执行/状态逻辑负责使用该脉冲清除自身的 done 状态。

### 5.3 Base Address 寄存器

每个 base address 由两个 32 bit 寄存器保存，并在硬件侧拼接为一个 64 bit 信号：

```text
cfg_q_base = {Q_BASE_H, Q_BASE_L}
cfg_k_base = {K_BASE_H, K_BASE_L}
cfg_v_base = {V_BASE_H, V_BASE_L}
cfg_o_base = {O_BASE_H, O_BASE_L}
```

软件应在写 `CTRL.START = 1` 之前完成 low word 和 high word 的配置。

### 5.4 `NEG_LARGE` 与 `SCALE`

寄存器模块将 `NEG_LARGE` 和 `SCALE` 视为不透明的 32 bit 数值，不检查其数值格式或合法范围。

推荐 baseline 语义如下：

- `NEG_LARGE`：masking 逻辑使用的近似 `-inf` 值。
- `SCALE`：softmax 缩放系数，通常为 `1 / sqrt(d)`。

## 6. 软件编程模型

典型的软件配置和启动流程如下：

1. 配置 `Q/K/V/O_BASE_L/H`。
2. 配置 `STRIDE_BYTES`、`NEG_LARGE`、`SCALE` 和 `CFG.CAUSAL_EN`。
3. 如需中断，设置 `CTRL.IRQ_EN`。
4. 如下游状态逻辑需要，写 `STATUS.DONE = 1` 清除旧的完成状态。
5. 写 `CTRL.START = 1` 启动执行。
6. 轮询 `STATUS.BUSY`、`STATUS.DONE` 和 `STATUS.ERROR`，或使用本模块外部生成的中断。
7. 执行完成后读取 `CYCLES` 进行性能分析。

除非外围系统明确保证运行时更新配置是安全的，否则软件不应在加速器运行期间修改配置寄存器。
