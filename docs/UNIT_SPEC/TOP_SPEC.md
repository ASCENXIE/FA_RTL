# TOP SPEC

## 状态

本文档定义当前 Flash Attention 加速器 IP 的顶层规格。  
它反映了已经收敛下来的 `16x16` 单 shared core 架构，以及最终统一接口决议表中的接口约束。

## 1. 模块概述

`TOP` 是 Flash Attention 加速器 IP 面向用户的最终集成模块。

`TOP` 是一个**纯集成层**，负责：

- 对外暴露：
  - `clk`
  - `rst_n`
  - `irq`
  - `AXI4-Lite slave`
  - `AXI4 master`
- 例化内部模块
- 建立模块之间的静态连接
- 将系统状态送入 AXI4-Lite 寄存器模块

`TOP` 不负责：

- 状态机
- 复杂仲裁
- 动态 mux / adapter
- DMA 地址生成
- 算术处理
- 数值后处理

## 2. 模块核心职责

`TOP` 的核心职责如下：

1. 对外提供控制面与数据面总线接口。
2. 例化并连接：
   - `fa_axi_lite_regs`
   - `fa_scheduler`
   - `fa_addr_gen`
   - `fa_dma_engine`
   - `fa_buffer_cluster`
   - `fa_compute_core`
   - `fa_vpu`
3. 将 `fa_scheduler` 作为唯一全局主控接入所有从模块。
4. 通过：
   - `scheduler -> addr_gen -> dma`
   的串行控制链驱动 DMA 地址与长度生成。
5. 建立数据主通路：
   - `DMA -> BufferCluster -> ComputeCore -> VPU -> DMA`
   - 以及 `VPU -> ComputeCore` 的 `P` 重放回路
6. 将 `status_busy / status_done / status_error / perf_cycles / debug_*` 统一送入寄存器模块。
7. 生成顶层中断：
   - `irq = cfg_irq_en & status_done`

## 3. 子模块概述

| 子模块 | 子模块功能 |
|---|---|
| `fa_axi_lite_regs` | 提供寄存器访问、配置输出与状态读回。 |
| `fa_scheduler` | 系统唯一全局 tile 级控制主模块。 |
| `fa_addr_gen` | 生成 tile 级 DMA 起始地址与传输字节数。 |
| `fa_dma_engine` | 执行 `Q/K/V` 读入和 `O` 写回。 |
| `fa_buffer_cluster` | 保存 `Q/K/V` tile，并重排后流式输出给 `compute_core`。 |
| `fa_compute_core` | 共享 `16x16` 脉动阵列，执行 `QK/PV` 两类矩阵乘加。 |
| `fa_vpu` | 负责 `score->P`、`pv->Oacc`、`final O`，并持有 `P/m/l/Oacc`。 |

## 4. 顶层参数

`TOP` 采用 compile-time parameter 配置问题规模。

推荐参数：

- `SEQ_LEN`
- `HEAD_DIM`
- `TILE_BR`
- `TILE_BC`
- `ARRAY_DIM`
- `ELEM_WIDTH`
- `ACC_WIDTH`

当前架构约束：

- `ARRAY_DIM = 16`
- `TILE_BR <= 16`
- `TILE_BC <= 16`
- `SEQ_LEN % TILE_BR == 0`
- `SEQ_LEN % TILE_BC == 0`
- `HEAD_DIM % 16 == 0`

这些参数通过 parameter override 下传给各子模块，不作为运行时普通输入端口传递。

## 5. 顶层端口说明

### 5.1 时钟 / 复位 / 中断

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | 顶层工作时钟 |
| `rst_n` | input | 1 | 顶层低有效复位 |
| `irq` | output | 1 | 中断输出，定义为 `cfg_irq_en & status_done` |

### 5.2 AXI4-Lite Slave 接口

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `s_axil_awaddr` | input | 32 | AXI4-Lite 写地址 |
| `s_axil_awvalid` | input | 1 | AXI4-Lite 写地址有效 |
| `s_axil_awready` | output | 1 | AXI4-Lite 写地址就绪 |
| `s_axil_wdata` | input | 32 | AXI4-Lite 写数据 |
| `s_axil_wstrb` | input | 4 | AXI4-Lite 写字节使能 |
| `s_axil_wvalid` | input | 1 | AXI4-Lite 写数据有效 |
| `s_axil_wready` | output | 1 | AXI4-Lite 写数据就绪 |
| `s_axil_bresp` | output | 2 | AXI4-Lite 写响应 |
| `s_axil_bvalid` | output | 1 | AXI4-Lite 写响应有效 |
| `s_axil_bready` | input | 1 | AXI4-Lite 写响应就绪 |
| `s_axil_araddr` | input | 32 | AXI4-Lite 读地址 |
| `s_axil_arvalid` | input | 1 | AXI4-Lite 读地址有效 |
| `s_axil_arready` | output | 1 | AXI4-Lite 读地址就绪 |
| `s_axil_rdata` | output | 32 | AXI4-Lite 读数据 |
| `s_axil_rresp` | output | 2 | AXI4-Lite 读响应 |
| `s_axil_rvalid` | output | 1 | AXI4-Lite 读响应有效 |
| `s_axil_rready` | input | 1 | AXI4-Lite 读响应就绪 |

### 5.3 AXI4 Master 接口

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `m_axi_awaddr` | output | `MEM_ADDR_WIDTH` | AXI 写地址 |
| `m_axi_awlen` | output | 8 | 写 burst 长度 |
| `m_axi_awsize` | output | 3 | 写 burst 每 beat 字节数编码 |
| `m_axi_awburst` | output | 2 | 写 burst 类型 |
| `m_axi_awvalid` | output | 1 | 写地址有效 |
| `m_axi_awready` | input | 1 | 写地址就绪 |
| `m_axi_wdata` | output | `MEM_DATA_WIDTH` | AXI 写数据 |
| `m_axi_wstrb` | output | `MEM_DATA_WIDTH/8` | 写字节使能 |
| `m_axi_wlast` | output | 1 | 写 burst 最后一个 beat |
| `m_axi_wvalid` | output | 1 | 写数据有效 |
| `m_axi_wready` | input | 1 | 写数据就绪 |
| `m_axi_bresp` | input | 2 | 写响应 |
| `m_axi_bvalid` | input | 1 | 写响应有效 |
| `m_axi_bready` | output | 1 | 写响应就绪 |
| `m_axi_araddr` | output | `MEM_ADDR_WIDTH` | AXI 读地址 |
| `m_axi_arlen` | output | 8 | 读 burst 长度 |
| `m_axi_arsize` | output | 3 | 读 burst 每 beat 字节数编码 |
| `m_axi_arburst` | output | 2 | 读 burst 类型 |
| `m_axi_arvalid` | output | 1 | 读地址有效 |
| `m_axi_arready` | input | 1 | 读地址就绪 |
| `m_axi_rdata` | input | `MEM_DATA_WIDTH` | AXI 读数据 |
| `m_axi_rresp` | input | 2 | 读响应 |
| `m_axi_rlast` | input | 1 | 读 burst 最后一个 beat |
| `m_axi_rvalid` | input | 1 | 读数据有效 |
| `m_axi_rready` | output | 1 | 读数据就绪 |

## 6. 顶层内部连接决议

### 6.1 Scheduler -> AddrGen

`TOP` 内部采用：

- `addrgen_start`
- `addrgen_mem_sel[1:0]`
- `addrgen_tile_idx`

`fa_addr_gen` 输出：

- `dma_addr`
- `dma_bytes`
- `done`

### 6.2 Scheduler -> DMA

DMA 控制统一为：

- `dma_start`
- `dma_op`
- `dma_busy`
- `dma_done`
- `dma_error`

### 6.3 Scheduler -> BufferCluster

buffer 控制统一为：

- `buf_start`
- `buf_op[2:0]`
- `buf_pingpong_sel`
- `buf_word_count`
- `buf_busy`
- `buf_done`

### 6.4 Scheduler -> ComputeCore

shared core 控制统一为：

- `core_start`
- `core_mode`
- `core_busy`
- `core_done`

### 6.5 Scheduler -> VPU

VPU 控制统一为：

- `vpu_start`
- `vpu_op`
- `vpu_q_tile_idx`
- `vpu_kv_tile_idx`
- `vpu_busy`
- `vpu_done`

## 7. 数据通路决议

### 7.1 输入矩阵通路

- `DMA -> BufferCluster`
- `BufferCluster -> ComputeCore`

其中：
- `Q/K/V` 写入时按 row-major tile 存储
- 重排在 stream 输出阶段完成

### 7.2 矩阵乘加与中间状态通路

- `ComputeCore(QK)` 输出 `score_stream`
- `VPU` 消费 `score_stream` 生成并缓存 `P`
- `VPU` 在 `PV` 阶段重放 `p_stream`
- `ComputeCore(PV)` 输出 `pv_stream`
- `VPU` 消费 `pv_stream` 更新 `Oacc`

### 7.3 最终输出通路

- `VPU_FINALIZE_O` 输出 `o_stream`
- `DMA` 接收 `o_stream`
- 写回外存

## 8. ComputeCore 与 VPU 接口最终决议

### 8.1 ComputeCore

保留**类型化流端口**：

- 输入：
  - `q_stream_*`
  - `k_stream_*`
  - `p_stream_*`
  - `v_stream_*`
- 输出：
  - `score_stream_*`
  - `pv_stream_*`

不采用统一 `in_a/in_b/out` 抽象端口，以避免把 mux/select 逻辑推回 `TOP`。

### 8.2 VPU

同样保留**类型化流端口**：

- 输入：
  - `score_stream_*`
  - `pv_stream_*`
- 输出：
  - `p_stream_*`
  - `o_stream_*`

## 9. BufferCluster 最终决议

- `Q`：单缓冲
- `K`：双缓冲
- `V`：双缓冲
- `buf_op` 宽度固定为 `3 bit`
- `buf_pingpong_sel` 仅对 `K/V` bank 操作有效
- `BufferCluster` 只保存 `Q/K/V`

## 10. 参数合法性检查

`TOP` 应显式加入 parameter 合法性检查：

- `SEQ_LEN > 0`
- `HEAD_DIM > 0`
- `TILE_BR > 0`
- `TILE_BC > 0`
- `SEQ_LEN % TILE_BR == 0`
- `SEQ_LEN % TILE_BC == 0`
- `TILE_BR <= ARRAY_DIM`
- `TILE_BC <= ARRAY_DIM`
- `HEAD_DIM % ARRAY_DIM == 0`

## 10.1 baseline 连续 tile 布局约束

虽然软件可通过 CSR 写入 `STRIDE_BYTES`，当前 baseline 真正支持的合法运行配置要求：

```text
stride_bytes == HEAD_DIM * ELEM_BYTES
```

也就是：

- tile 在外存中必须按连续布局存放
- 当前不支持带 padding 的逐行跨 stride tile 访存

带 padding 的 stride 作为后续增强版预留，不属于当前 baseline 保证范围。

## 11. Reset 与状态决议

### 11.1 Reset

- `rst_n`
  - 复位整个 IP
- `SOFT_RESET`
  - 只复位执行通路
  - 不清空 AXI4-Lite 配置寄存器

### 11.2 状态来源

以下系统状态统一由 `Scheduler` 产生：

- `status_idle`
- `status_busy`
- `status_done`
- `status_error`
- `perf_cycles`
- `debug_q_tile`
- `debug_kv_tile`

`TOP` 不再做额外状态组合。

## 12. 总结

`TOP` 是当前架构中的最终集成层：

- 纯集成层
- 不做复杂控制逻辑
- 统一连接：
  - Scheduler
  - AddrGen
  - DMA
  - BufferCluster
  - ComputeCore
  - VPU
- 保持 tile 级控制与类型化数据通路

这份规格定义了当前实现阶段的稳定顶层契约。
