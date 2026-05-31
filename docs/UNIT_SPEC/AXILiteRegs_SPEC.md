# AXILiteRegs SPEC

## 状态

本文档定义当前 Flash Attention 加速器中 `fa_axi_lite_regs` 的规格说明。  
它基于当前已经收敛的控制寄存器模型，并与 `TOP_SPEC`、`Scheduler_SPEC`、`VPU_SPEC`、`DMAEngine_SPEC` 对齐。

## 1. 模块概述

`fa_axi_lite_regs` 是系统中的**AXI4-Lite 协议终止与 CSR 映射模块**。

它负责：

- 终止 AXI4-Lite slave 接口
- 提供软件可访问的控制/状态寄存器
- 将软件写入的配置寄存器输出给执行通路
- 将来自执行通路的状态信号映射为软件可读寄存器

它不负责：

- 任何执行通路调度决策
- 生成系统状态
- 生成中断组合逻辑
- 任何数值计算

从职责上看，它是：

> **AXI4-Lite 前端 + CSR 存取映射层**

## 2. 模块核心职责

`fa_axi_lite_regs` 的核心职责如下：

1. 处理 AXI4-Lite 的：
   - `AW/W/B`
   - `AR/R`
   通道协议
2. 提供保持型配置寄存器：
   - `IRQ_EN`
   - `CAUSAL_EN`
   - `Q/K/V/O_BASE`
   - `STRIDE_BYTES`
   - `NEG_LARGE`
   - `SCALE`
3. 生成单拍脉冲控制输出：
   - `ctrl_start_pulse`
   - `ctrl_done_clr`
   - `ctrl_soft_reset`
4. 采样来自 scheduler 的系统状态并映射为软件可见寄存器：
   - `status_busy`
   - `status_done`
   - `status_error`
   - `perf_cycles`
   - `debug_q_tile`
   - `debug_kv_tile`
5. 支持标准 `WSTRB` 按字节写语义。

## 3. 子模块概述

逻辑上建议将 `fa_axi_lite_regs` 划分为以下几个子块：

| 子模块 | 子模块功能 |
|---|---|
| `axil_write_ctrl` | 管理 AXI-Lite 写地址、写数据、写响应通道。 |
| `axil_read_ctrl` | 管理 AXI-Lite 读地址、读数据响应通道。 |
| `csr_config_bank` | 保存保持型配置寄存器。 |
| `csr_pulse_gen` | 生成 `START / DONE_CLR / SOFT_RESET` 单拍脉冲。 |
| `csr_status_bank` | 采样并映射外部状态寄存器。 |
| `csr_decode_mux` | 完成地址解码和读写数据选择。 |

## 4. 子模块功能说明

| 子模块 | 核心状态/信号 | 功能说明 |
|---|---|---|
| `axil_write_ctrl` | `awready`, `wready`, `bvalid`, `bresp` | 处理 AXI-Lite 写事务。 |
| `axil_read_ctrl` | `arready`, `rvalid`, `rdata`, `rresp` | 处理 AXI-Lite 读事务。 |
| `csr_config_bank` | `cfg_*` | 保存软件可写、持续生效的配置值。 |
| `csr_pulse_gen` | `ctrl_start_pulse`, `ctrl_done_clr`, `ctrl_soft_reset` | 将软件写操作转换为单拍控制脉冲。 |
| `csr_status_bank` | `status_*`, `perf_cycles`, `debug_*` | 映射外部驱动状态，不自行生成这些状态。 |
| `csr_decode_mux` | `addr decode`, `wstrb apply`, `rdata select` | 地址解码、按字节写、读数据复用。 |

## 5. 寄存器类型模型

`fa_axi_lite_regs` 中的寄存器分为三类：

### 5.1 保持型配置寄存器

特点：

- 软件写入后保持
- 直到被下一次写入覆盖或 `rst_n` 复位

包括：

- `IRQ_EN`
- `CAUSAL_EN`
- `Q/K/V/O_BASE_L/H`
- `STRIDE_BYTES`
- `NEG_LARGE`
- `SCALE`

### 5.2 脉冲型控制位

特点：

- 软件写 `1` 时产生单拍脉冲
- 不在寄存器中保持为 `1`

包括：

- `START`
- `DONE_CLR`
- `SOFT_RESET`

### 5.3 外部驱动状态位

特点：

- 由执行通路外部模块驱动
- 软件只能读取，不能直接修改

包括：

- `BUSY`
- `DONE`
- `ERROR`
- `CYCLES`
- `DEBUG_Q_TILE`
- `DEBUG_KV_TILE`

## 6. 顶层端口说明

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | AXI-Lite CSR 模块工作时钟 |
| `rst_n` | input | 1 | 低有效复位，清空 CSR 到默认值 |
| `s_axil_awaddr` | input | 32 | AXI-Lite 写地址 |
| `s_axil_awvalid` | input | 1 | 写地址有效 |
| `s_axil_awready` | output | 1 | 写地址就绪 |
| `s_axil_wdata` | input | 32 | AXI-Lite 写数据 |
| `s_axil_wstrb` | input | 4 | AXI-Lite 字节写使能 |
| `s_axil_wvalid` | input | 1 | 写数据有效 |
| `s_axil_wready` | output | 1 | 写数据就绪 |
| `s_axil_bresp` | output | 2 | 写响应 |
| `s_axil_bvalid` | output | 1 | 写响应有效 |
| `s_axil_bready` | input | 1 | 写响应就绪 |
| `s_axil_araddr` | input | 32 | AXI-Lite 读地址 |
| `s_axil_arvalid` | input | 1 | 读地址有效 |
| `s_axil_arready` | output | 1 | 读地址就绪 |
| `s_axil_rdata` | output | 32 | AXI-Lite 读数据 |
| `s_axil_rresp` | output | 2 | 读响应 |
| `s_axil_rvalid` | output | 1 | 读响应有效 |
| `s_axil_rready` | input | 1 | 读响应就绪 |
| `ctrl_start_pulse` | output | 1 | `START` 单拍脉冲输出 |
| `ctrl_done_clr` | output | 1 | `DONE_CLR` 单拍脉冲输出 |
| `ctrl_soft_reset` | output | 1 | `SOFT_RESET` 单拍脉冲输出 |
| `ctrl_irq_en` | output | 1 | `IRQ_EN` 保持型配置输出 |
| `ctrl_causal_en` | output | 1 | `CAUSAL_EN` 保持型配置输出 |
| `cfg_q_base` | output | 64 | 拼接后的 `Q` 基地址 |
| `cfg_k_base` | output | 64 | 拼接后的 `K` 基地址 |
| `cfg_v_base` | output | 64 | 拼接后的 `V` 基地址 |
| `cfg_o_base` | output | 64 | 拼接后的 `O` 基地址 |
| `cfg_stride_bytes` | output | 32 | 单一路 `stride_bytes` 配置输出 |
| `cfg_neg_large` | output | `CFG_DATA_WIDTH` | `NEG_LARGE` 配置输出 |
| `cfg_scale` | output | `CFG_DATA_WIDTH` | `SCALE` 配置输出 |
| `status_busy` | input | 1 | 来自 scheduler 的 `busy` 状态 |
| `status_done` | input | 1 | 来自 scheduler 的 `done` 状态 |
| `status_error` | input | 1 | 来自 scheduler 的 `error` 状态 |
| `perf_cycles` | input | 32 | 来自 scheduler 的端到端周期计数 |
| `debug_q_tile` | input | 8 | 来自 scheduler 的调试 `q_tile` 编号 |
| `debug_kv_tile` | input | 8 | 来自 scheduler 的调试 `kv_tile` 编号 |

## 7. 寄存器集合

当前 baseline 下，寄存器集合固定为：

- `CTRL`
- `STATUS`
- `CFG`
- `Q_BASE_L/H`
- `K_BASE_L/H`
- `V_BASE_L/H`
- `O_BASE_L/H`
- `STRIDE_BYTES`
- `NEG_LARGE`
- `SCALE`
- `CYCLES`
- 推荐调试寄存器：
  - `DEBUG_Q_TILE`
  - `DEBUG_KV_TILE`

当前不引入：

- `SEQ_LEN`
- `HEAD_DIM`
- `TILE_BR`
- `TILE_BC`

这些信息继续保留为 compile-time parameter。

## 8. `CTRL` 语义

建议定义：

- `bit0 START`
  - 脉冲型
- `bit1 SOFT_RESET`
  - 脉冲型
- `bit2 IRQ_EN`
  - 保持型

即：

- 写 `START=1`
  - 产生 `ctrl_start_pulse`
- 写 `SOFT_RESET=1`
  - 产生 `ctrl_soft_reset`
- `IRQ_EN`
  - 保存为配置位并持续输出

## 9. `STATUS` 语义

建议定义：

- `bit0 BUSY`
  - 只读直通
- `bit1 DONE`
  - 外部状态 + W1C
- `bit2 ERROR`
  - 只读直通

即：

- `BUSY`
  - 直接映射 `scheduler.status_busy`
- `DONE`
  - 直接映射 `scheduler.status_done`
  - 软件写 `1` 时产生 `ctrl_done_clr`
- `ERROR`
  - 直接映射 `scheduler.status_error`

## 10. `CFG` 语义

当前仅保留：

- `bit0 CAUSAL_EN`

其余位：

- 保留
- 读出为 `0`
- 写入忽略

## 11. 基地址与配置寄存器语义

### 11.1 `Q/K/V/O_BASE_L/H`

- 全部为保持型配置寄存器
- 在模块内部拼接为：
  - `cfg_q_base`
  - `cfg_k_base`
  - `cfg_v_base`
  - `cfg_o_base`

### 11.2 `STRIDE_BYTES`

- 保持型配置寄存器
- 输出单一路：
  - `cfg_stride_bytes`
- 当前 baseline 的合法运行配置要求：
  - `cfg_stride_bytes == HEAD_DIM * ELEM_BYTES`
- 也就是：
  - 该寄存器虽然可被软件写入
  - 但当前 baseline 只保证连续 tile 布局
  - 不保证带 padding 的逐行跨 stride tile 访存

### 11.3 `NEG_LARGE / SCALE`

- 保持型数值配置寄存器
- 寄存器模块只负责存储和输出
- 数值意义由 `VPU` 负责解释与使用

## 12. `CYCLES` 与调试寄存器语义

### `CYCLES`

- 只读
- 直接映射：
  - `scheduler.perf_cycles`
- 寄存器模块本身不负责计数

### `DEBUG_Q_TILE / DEBUG_KV_TILE`

- 推荐的只读调试寄存器
- 直接映射：
  - `scheduler.debug_q_tile`
  - `scheduler.debug_kv_tile`

## 13. AXI4-Lite 事务模型

baseline 中采用：

- 简单、非流水化、单事务优先的 AXI4-Lite 从设备模型

不做：

- 多事务排队
- 深流水
- 乱序响应

## 14. 非法/未定义访问语义

对于：

- 未定义地址读写
- 写只读寄存器
- 写保留位

统一定义为：

- 忽略副作用
- 仍返回合法 AXI-Lite 响应

推荐返回：

- `OKAY`

例如：

- 读未定义地址：
  - `RDATA = 0`
  - `RRESP = OKAY`
- 写未定义地址：
  - 忽略
  - `BRESP = OKAY`

## 15. `WSTRB` 语义

支持标准按字节写：

- 保持型寄存器
  - 仅更新 `WSTRB` 选中的字节
- 脉冲型控制位
  - 仅在对应字节被 `WSTRB` 使能且写数据该 bit 为 `1` 时产生脉冲
- 只读寄存器
  - 忽略副作用，但仍返回合法响应

## 16. 读一致性语义

单次读事务只保证：

- 返回该寄存器在当前读响应时刻的稳定值

不保证：

- 多寄存器读形成原子快照

## 17. Reset 语义

### 17.1 `rst_n`

外部复位到来时：

- 清空保持型配置寄存器到默认值
- 清空脉冲控制输出
- 清空 AXI-Lite 内部状态机

### 17.2 `SOFT_RESET`

`SOFT_RESET`：

- 只通过 `ctrl_soft_reset` 输出一个单拍脉冲给执行通路
- 不清空寄存器内容
- 不复位 `fa_axi_lite_regs` 自身

## 18. 脉冲型控制输出语义

以下控制信号全部定义为：

- **单拍脉冲**

包括：

- `ctrl_start_pulse`
- `ctrl_done_clr`
- `ctrl_soft_reset`

当软件写对应位为 `1` 且字节被 `WSTRB` 覆盖时：

- 脉冲只持续一个时钟周期

## 19. 总结

`fa_axi_lite_regs` 是当前系统中的 AXI4-Lite 前端与 CSR 映射层：

- 终止 AXI-Lite 总线
- 保存配置寄存器
- 生成单拍控制脉冲
- 转发 scheduler 的状态给软件
- 不介入执行通路调度

这份规格定义了当前实现阶段稳定的 `AXILiteRegs` 接口与行为边界。
