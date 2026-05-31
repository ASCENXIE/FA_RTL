# DMAEngine SPEC

## 状态

本文档定义当前 Flash Attention 加速器中 `fa_dma_engine` 的规格说明。  
它基于当前已经收敛的 `16x16` 单 shared core 架构，并与 `TOP_SPEC`、`Scheduler_SPEC`、`AddrGen_SPEC`、`BufferCluster_SPEC`、`VPU_SPEC` 的接口和行为保持一致。

## 1. 模块概述

`fa_dma_engine` 是系统中的**tile 级 DMA 执行器与 AXI 协议适配器**。

它负责：

- 读取外存中的 `Q/K/V tile`
- 将读回的数据以流形式交给 `buffer_cluster`
- 接收来自 `VPU` 的最终 `O tile`
- 将 `O tile` 写回外存

`fa_dma_engine` 不负责：

- 生成 tile 地址
- 决定下一步搬运哪个 tile
- 管理 buffer bank 切换
- 进行任何 attention 数值计算

从职责上看，它是一个：

> **面向 tile 级任务的 DMA 读写执行模块，对外保持 tile 抽象，对内完成 AXI burst/beat 级协议处理**

## 2. 模块核心职责

`fa_dma_engine` 的核心职责如下：

1. 接收来自 `fa_scheduler` 的 tile 级 DMA 请求：
   - `dma_start`
   - `dma_op`
   - `dma_addr`
   - `dma_bytes`
2. 根据 `dma_op` 执行以下操作之一：
   - `DMA_LOAD_Q`
   - `DMA_LOAD_K`
   - `DMA_LOAD_V`
   - `DMA_STORE_O`
3. 对读操作：
   - 发起 AXI 读请求
   - 接收读回数据
   - 通过 `dma_w_*` 流接口把数据送入 `buffer_cluster`
4. 对写操作：
   - 从 `o_stream_*` 接收最终 `O tile`
   - 必要时先写入内部写回缓冲
   - 发起 AXI 写事务并提交到外存
5. 在单 tile 请求超过单个 AXI burst 能力时：
   - 在模块内部自动拆分为多个连续 burst
6. 对外以：
   - `busy`
   - `done`
   - `error`
   表示当前 tile 级 DMA 任务状态

## 3. 子模块概述

虽然 `fa_dma_engine` 可以实现成一个 RTL 模块，但逻辑上建议拆分为以下几个子块：

| 子模块 | 子模块功能 |
|---|---|
| `dma_req_latch` | 锁存 tile 级 DMA 请求：`dma_op / dma_addr / dma_bytes`。 |
| `dma_read_ctrl` | 管理 `LOAD_Q/K/V` 的 AXI 读地址、读数据接收和 beat 计数。 |
| `dma_write_ctrl` | 管理 `STORE_O` 的 AXI 写地址、写数据发送和写响应处理。 |
| `dma_burst_splitter` | 把 tile 级请求拆分成多个 AXI burst（若需要）。 |
| `dma_read_stream_if` | 将 AXI 读回数据组织为 `dma_w_*` 输出给 `buffer_cluster`。 |
| `dma_write_stream_if` | 从 `o_stream_*` 接收数据并组织为 AXI 写数据流。 |
| `dma_wb_buffer` | 保存至少 1 个 `O tile` 深度的内部写回缓冲/FIFO。 |
| `dma_status_ctrl` | 生成 `busy/done/error`，管理任务完成和错误状态。 |

## 4. 子模块功能说明

| 子模块 | 核心状态/信号 | 功能说明 |
|---|---|---|
| `dma_req_latch` | `dma_op_latched`, `dma_addr_latched`, `dma_bytes_latched` | 在接受 `start` 时锁存本次 tile 级请求参数。 |
| `dma_read_ctrl` | `is_read_op`, `ar_issue`, `r_beat_cnt` | 执行 `LOAD_Q/K/V` 的 AXI 读路径。 |
| `dma_write_ctrl` | `is_write_op`, `aw_issue`, `w_beat_cnt`, `b_wait` | 执行 `STORE_O` 的 AXI 写路径。 |
| `dma_burst_splitter` | `burst_addr`, `burst_bytes`, `burst_beats` | 当单 tile 超过单 burst 能力时，内部自动拆分多个 burst。 |
| `dma_read_stream_if` | `dma_w_valid/data/last`, `dma_w_ready` | 把读回数据流式交付给 `buffer_cluster`。 |
| `dma_write_stream_if` | `o_stream_valid/data/last`, `o_stream_ready` | 从 `VPU` 接收最终 `O tile`。 |
| `dma_wb_buffer` | `wb_fifo`, `wb_count` | 解耦 `VPU_FINALIZE_O` 输出和 AXI 写回节奏。 |
| `dma_status_ctrl` | `busy`, `done`, `error` | 统一管理任务生命周期与异常结束。 |

## 5. 工作粒度与资源模型

`fa_dma_engine` 的工作粒度固定为：

- **tile 级**

资源模型固定为：

- 单实例
- 单 issue
- 单时刻只执行一个 tile 级 DMA 操作

即：

- 不支持同时处理多个 tile 级请求
- 不在 baseline 中暴露读写双 issue 逻辑通道

## 6. 顶层端口说明

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | DMA 模块工作时钟 |
| `rst_n` | input | 1 | 低有效复位 |
| `start` | input | 1 | 启动一次 tile 级 DMA 请求 |
| `dma_op` | input | 2 | DMA 操作类型：`LOAD_Q/K/V/STORE_O` |
| `dma_addr` | input | `MEM_ADDR_WIDTH` | 当前 tile 的外存起始地址 |
| `dma_bytes` | input | `DMA_BYTES_WIDTH` | 当前 tile 的总传输字节数 |
| `busy` | output | 1 | 当前 tile 级 DMA 任务执行中 |
| `done` | output | 1 | 当前 tile 级 DMA 任务完整完成 |
| `error` | output | 1 | 当前 tile 级 DMA 任务失败 |
| `buf_w_valid` | output | 1 | 写入 `buffer_cluster` 的数据有效 |
| `buf_w_kind` | output | `BUF_KIND_WIDTH` | 当前写入数据属于 `Q/K/V` 哪一类 |
| `buf_w_data` | output | `DMA_DATA_WIDTH` | 写入 `buffer_cluster` 的数据 |
| `buf_w_last` | output | 1 | 当前 tile 写入 `buffer_cluster` 的最后一个 beat |
| `buf_w_ready` | input | 1 | `buffer_cluster` 写入就绪 |
| `o_stream_valid` | input | 1 | 来自 `VPU` 的 `O tile` 输出有效 |
| `o_stream_data` | input | `DMA_DATA_WIDTH` | 来自 `VPU` 的 `O tile` 输出数据 |
| `o_stream_last` | input | 1 | `O tile` 最后一个输出 beat |
| `o_stream_ready` | output | 1 | DMA 对 `O tile` 输入就绪 |
| `m_axi_awaddr` | output | `MEM_ADDR_WIDTH` | AXI 写地址 |
| `m_axi_awlen` | output | 8 | AXI 写 burst 长度 |
| `m_axi_awsize` | output | 3 | AXI 写 burst beat 大小编码 |
| `m_axi_awburst` | output | 2 | AXI 写 burst 类型 |
| `m_axi_awvalid` | output | 1 | AXI 写地址有效 |
| `m_axi_awready` | input | 1 | AXI 写地址就绪 |
| `m_axi_wdata` | output | `DMA_DATA_WIDTH` | AXI 写数据 |
| `m_axi_wstrb` | output | `DMA_DATA_WIDTH/8` | AXI 写字节使能 |
| `m_axi_wlast` | output | 1 | AXI 写 burst 最后一个 beat |
| `m_axi_wvalid` | output | 1 | AXI 写数据有效 |
| `m_axi_wready` | input | 1 | AXI 写数据就绪 |
| `m_axi_bresp` | input | 2 | AXI 写响应 |
| `m_axi_bvalid` | input | 1 | AXI 写响应有效 |
| `m_axi_bready` | output | 1 | AXI 写响应就绪 |
| `m_axi_araddr` | output | `MEM_ADDR_WIDTH` | AXI 读地址 |
| `m_axi_arlen` | output | 8 | AXI 读 burst 长度 |
| `m_axi_arsize` | output | 3 | AXI 读 burst beat 大小编码 |
| `m_axi_arburst` | output | 2 | AXI 读 burst 类型 |
| `m_axi_arvalid` | output | 1 | AXI 读地址有效 |
| `m_axi_arready` | input | 1 | AXI 读地址就绪 |
| `m_axi_rdata` | input | `DMA_DATA_WIDTH` | AXI 读数据 |
| `m_axi_rresp` | input | 2 | AXI 读响应 |
| `m_axi_rlast` | input | 1 | AXI 读 burst 最后一个 beat |
| `m_axi_rvalid` | input | 1 | AXI 读数据有效 |
| `m_axi_rready` | output | 1 | AXI 读数据就绪 |

## 7. `dma_op` 语义

`dma_op[1:0]` 建议编码如下：

| 编码 | 含义 |
|---|---|
| `2'b00` | `DMA_LOAD_Q` |
| `2'b01` | `DMA_LOAD_K` |
| `2'b10` | `DMA_LOAD_V` |
| `2'b11` | `DMA_STORE_O` |

## 8. 任务锁存语义

在接受 `start` 时，`fa_dma_engine` 必须锁存：

- `dma_op`
- `dma_addr`
- `dma_bytes`

在当前 tile 级任务完成之前，这些锁存值保持不变。

## 9. 读任务语义

读类任务包括：

- `DMA_LOAD_Q`
- `DMA_LOAD_K`
- `DMA_LOAD_V`

### 9.1 目标

- 从外存读取一个完整 tile
- 通过 `buf_w_*` 接口送入 `buffer_cluster`

### 9.2 `buf_w_kind`

`buf_w_kind` 只对读类任务有效：

- `LOAD_Q -> Q`
- `LOAD_K -> K`
- `LOAD_V -> V`

在 `STORE_O` 时，`buf_w_kind` 无意义。

### 9.3 完成条件

读类任务的 `done` 定义为：

> 当前 tile 的最后一个读回 beat 已成功通过 `buf_w_*` 交付给 `buffer_cluster`

也就是不只要求 AXI 读回结束，还要求数据已成功进入 `buffer_cluster`。

## 10. 写任务语义

写类任务只有：

- `DMA_STORE_O`

### 10.1 目标

- 从 `o_stream_*` 接收完整 `O tile`
- 通过 AXI 写回外存

### 10.2 写回缓冲

`fa_dma_engine` 必须包含：

- 至少 **1 个 `O tile` 深度** 的内部写回缓冲/FIFO

用于解耦：

- `VPU_FINALIZE_O` 的输出节奏
- AXI 写回节奏

### 10.3 完成条件

写类任务的 `done` 定义为：

> 最后一个 `o_stream` beat 已成功接收，且 AXI 写事务已提交完成

因此 `done` 不得早于 AXI 写提交完成。

## 11. 连续 tile 布局约束

当前 baseline 中，`fa_dma_engine` 只支持：

> **tile 在外存中连续可搬运**

即要求：

```text
stride_bytes == HEAD_DIM * ELEM_BYTES
```

也就是说：

- 当前不支持带 padding 的逐行跨 stride tile 搬运
- 不支持逐行 micro-burst 跳 stride 访问

这个约束与当前 `AddrGen` 的单 `dma_addr + dma_bytes` 模型一致。

## 12. AXI burst 拆分语义

虽然对上层 DMA 请求是 tile 级的，但 DMA 内部必须支持：

> **将单个 tile 级请求自动拆分为多个 AXI burst**

当：

- `dma_bytes` 超过单个 AXI burst 能力

时，内部自动拆分多个连续 burst。

这种拆分：

- 对 `scheduler` 不可见
- 对 `addr_gen` 不可见
- 对上层完全透明

## 13. 流接口语义

### 13.1 读回送 `buffer_cluster`

`buf_w_*` 严格遵守：

- `valid`
- `ready`
- `last`

规则：

- 只有 `valid & ready` 才算该 beat 成功交付
- `last` 标记当前 tile 的最后一个写入 beat

### 13.2 从 `VPU` 接收 `O`

`o_stream_*` 严格遵守：

- `valid`
- `ready`
- `last`

规则：

- 只有 `valid & ready` 才算该 beat 成功接收
- `last` 标记当前 `O tile` 的最后一个输出 beat

## 14. 内部读写路径区分

虽然对外是一个统一 DMA 模块，但内部应显式区分：

- 读任务执行路径
- 写任务执行路径

也就是说实现上建议有独立的：

- 读状态机
- 写状态机语义

但这种区分不需要额外暴露到顶层接口。

## 15. 错误语义

`error` 定义为：

> 当前 tile 级 DMA 任务失败的锁存信号

触发来源包括：

- AXI 读响应异常
- AXI 写响应异常
- 关键 AXI 通道协议错误

一旦发生：

- 当前任务失败
- 进入错误态
- `error` 保持为 1

baseline 中 `done` 不应与错误完成混淆。

## 16. Reset 语义

reset 到来时：

- 立即丢弃当前 tile 级 DMA 任务
- 清空：
  - `dma_op` latch
  - `dma_addr` latch
  - `dma_bytes` latch
  - beat / burst 计数器
  - 读写执行状态
- 回到 idle

输出恢复到：

- `busy = 0`
- `done = 0`
- `error = 0`
- `buf_w_valid = 0`
- `m_axi_*valid = 0`

## 17. 总结

`fa_dma_engine` 是当前系统中的 tile 级 DMA 执行器与 AXI 协议适配器：

- tile 级请求
- tile 级完成
- 单实例、单 issue
- 读侧把 `Q/K/V` 送入 `buffer_cluster`
- 写侧从 `VPU` 接收最终 `O`
- 内部负责 burst 切分与 AXI 协议细节
- baseline 只支持连续 tile 布局

这份规格定义了当前实现阶段稳定的 `DMAEngine` 接口与行为边界。
