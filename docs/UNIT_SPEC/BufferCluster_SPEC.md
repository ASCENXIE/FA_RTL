# BufferCluster SPEC

## 状态

本文档定义当前 Flash Attention 加速器中 `fa_buffer_cluster` 的规格说明。  
它基于当前已经收敛的 `16x16` 单 core 架构，并与 `TOP_SPEC`、`Scheduler_SPEC`、`ComputeCore_SPEC` 一致。

## 1. 模块概述

`fa_buffer_cluster` 是系统中的**输入矩阵 tile 存储与流输出适配模块**。

它只负责：

- 保存 `Q/K/V` tile
- 接收 DMA 写入
- 根据 `compute_core` 需要的格式重排数据
- 以流形式将 `Q/K/V` 输出给 `fa_compute_core`

它不负责：

- 保存 `P`
- 保存 `m/l/Oacc`
- 保存 `O`
- softmax 或任何数值计算
- 全局调度决策
- DMA 地址控制

从职责上看，`fa_buffer_cluster` 是：

> **输入矩阵 tile 存储 + 数据重排 + 阵列友好流输出适配层**

## 2. 模块核心职责

`fa_buffer_cluster` 的核心职责如下：

1. 接收来自 `fa_dma_engine` 的 `Q/K/V` tile 写入数据。
2. 在内部保存：
   - `Q` 单缓冲
   - `K` 双缓冲
   - `V` 双缓冲
3. 维护本地 buffer 的有效性和 bank 角色状态。
4. 在执行 `BUF_STREAM_*` 命令时：
   - 将内部 row-major tile 数据重排
   - 输出为 `compute_core` 所需的流格式
5. 在执行 `BUF_SWAP_KV` 时：
   - 更新 `K/V` 的 active/prefetch bank 角色
6. 支持：
   - `active K/V` 读出
   - `prefetch K/V` 写入
   的并发重叠
7. 通过 `busy/done` 响应 scheduler 的 tile 级命令

## 3. 子模块概述

虽然 `fa_buffer_cluster` 可实现为一个 RTL 模块，但逻辑上建议拆分为以下几个子块：

| 子模块 | 子模块功能 |
|---|---|
| `bc_ctrl` | 解析 `buf_start/buf_op`，管理 `busy/done` 生命周期。 |
| `bc_q_store` | 管理 `Q` 单缓冲的写入、有效位与读出。 |
| `bc_k_store` | 管理 `K` 双缓冲的写入、有效位与 bank 角色。 |
| `bc_v_store` | 管理 `V` 双缓冲的写入、有效位与 bank 角色。 |
| `bc_reorder_qk` | 将 `Q/K` row-major tile 重排成 `QK` 所需输入流格式。 |
| `bc_reorder_v` | 将 `V` row-major tile 重排成 `PV` 所需列向量流格式。 |
| `bc_dma_write_if` | 处理 DMA 写入握手与写指针推进。 |
| `bc_stream_read_if` | 处理 stream 输出握手与读指针推进。 |

## 4. 子模块功能说明

| 子模块 | 核心状态/信号 | 功能说明 |
|---|---|---|
| `bc_ctrl` | `buf_op`, `busy`, `done` | 统一管理 tile 级操作生命周期。 |
| `bc_q_store` | `q_mem`, `q_valid` | 保存当前 `Q tile`，单缓冲。 |
| `bc_k_store` | `k_bank0`, `k_bank1`, `k_valid[1:0]`, `k_active_bank` | 保存 `K tile` 双缓冲与 bank 角色。 |
| `bc_v_store` | `v_bank0`, `v_bank1`, `v_valid[1:0]`, `v_active_bank` | 保存 `V tile` 双缓冲与 bank 角色。 |
| `bc_reorder_qk` | `q_stream`, `k_stream` | 把 `Q/K` 重排为归约维切片的 16-lane 流。 |
| `bc_reorder_v` | `v_stream` | 把 `V` 重排为列向量 16-lane 流。 |
| `bc_dma_write_if` | `dma_w_valid/ready/data/last`, `wr_ptr` | DMA 写入接口，写指针只在握手成功时推进。 |
| `bc_stream_read_if` | `stream_valid/ready/data/last`, `rd_ptr` | stream 输出接口，读指针只在握手成功时推进。 |

## 5. 资源组织

`fa_buffer_cluster` 内部资源组织固定如下：

- `Q`：单缓冲
- `K`：双缓冲
- `V`：双缓冲

即逻辑上至少包含：

- `q_buf`
- `k_buf_bank0`
- `k_buf_bank1`
- `v_buf_bank0`
- `v_buf_bank1`

## 6. 数据归属边界

`fa_buffer_cluster` 只处理：

- `Q`
- `K`
- `V`

它不保存：

- `P`
- `m`
- `l`
- `Oacc`
- `O`

这些数据分别属于：

- `VPU`
- `DMA writeback buffer`
- 外部内存

## 7. 写入来源与输出目标

### 7.1 写入来源

`Q/K/V` 的写入来源唯一限定为：

- `fa_dma_engine`

不接受来自：

- `fa_vpu`
- `fa_compute_core`
- 其他模块

### 7.2 输出目标

`Q/K/V` 的流输出目标唯一限定为：

- `fa_compute_core`

不直接输出到：

- `fa_vpu`
- `fa_dma_engine`
- 其他模块

## 8. 控制粒度

`fa_buffer_cluster` 只接受 **tile 级命令**。

scheduler 对它只发：

- `buf_start`
- `buf_op`
- `buf_pingpong_sel`
- `buf_word_count`

不发：

- 行地址
- beat 级 lane 控制
- 逐拍 bank 选择

## 9. 顶层端口说明

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | `buffer_cluster` 工作时钟 |
| `rst_n` | input | 1 | 低有效复位 |
| `start` | input | 1 | 启动一次 tile 级 buffer 操作 |
| `buf_op` | input | 3 | buffer 操作类型 |
| `buf_pingpong_sel` | input | 1 | `K/V` bank 选择 |
| `word_count` | input | 8 | 当前操作的字数或 beat 数 |
| `busy` | output | 1 | 当前 buffer 操作执行中 |
| `done` | output | 1 | 当前 buffer 操作完成 |
| `dma_w_valid` | input | 1 | DMA 写入数据有效 |
| `dma_w_kind` | input | `BUF_KIND_WIDTH` | 指示写入的是 `Q/K/V` 哪一类数据 |
| `dma_w_data` | input | `DMA_DATA_WIDTH` | DMA 写入数据 |
| `dma_w_last` | input | 1 | 当前 tile 写入最后一个 beat |
| `dma_w_ready` | output | 1 | DMA 写入就绪 |
| `q_stream_valid` | output | 1 | `Q` 输出流有效 |
| `q_stream_data` | output | `16 * ELEM_WIDTH` | `Q` 输出流数据 |
| `q_stream_last` | output | 1 | `Q tile` 输出结束 |
| `q_stream_ready` | input | 1 | `Q` 输出流就绪 |
| `k_stream_valid` | output | 1 | `K` 输出流有效 |
| `k_stream_data` | output | `16 * ELEM_WIDTH` | `K` 输出流数据 |
| `k_stream_last` | output | 1 | `K tile` 输出结束 |
| `k_stream_ready` | input | 1 | `K` 输出流就绪 |
| `v_stream_valid` | output | 1 | `V` 输出流有效 |
| `v_stream_data` | output | `16 * ELEM_WIDTH` | `V` 输出流数据 |
| `v_stream_last` | output | 1 | `V tile` 输出结束 |
| `v_stream_ready` | input | 1 | `V` 输出流就绪 |

## 10. 操作集合

`buf_op[2:0]` 的正式操作集合如下：

| 编码 | 含义 |
|---|---|
| `3'b000` | `BUF_FILL_Q` |
| `3'b001` | `BUF_FILL_K` |
| `3'b010` | `BUF_FILL_V` |
| `3'b011` | `BUF_STREAM_Q` |
| `3'b100` | `BUF_STREAM_K` |
| `3'b101` | `BUF_STREAM_V` |
| `3'b110` | `BUF_SWAP_KV` |
| `3'b111` | 保留 |

## 11. `buf_pingpong_sel` 语义

`buf_pingpong_sel` 仅对 `K/V` bank 相关操作有效。

### 有效操作

- `BUF_FILL_K`
- `BUF_FILL_V`
- `BUF_STREAM_K`
- `BUF_STREAM_V`

### 无关操作

- `BUF_FILL_Q`
- `BUF_STREAM_Q`

### `BUF_SWAP_KV`

对 `BUF_SWAP_KV` 而言，`swap` 的语义由操作本身定义，`buf_pingpong_sel` 可视为无关或保留。

## 12. 内部状态模型

### 12.1 `Q`

`Q` 为单缓冲，仅维护：

- `q_valid`

### 12.2 `K/V`

`K/V` 为双缓冲，必须显式区分：

- `valid`
- `active`

即：

- `k_valid[1:0]`
- `v_valid[1:0]`
- `k_active_bank`
- `v_active_bank`

其中：

- `valid` 表示该 bank 已完整写入一份 tile
- `active` 表示当前计算阶段应使用哪一个 bank

## 13. 存储布局

`Q/K/V` 在写入时均采用统一的：

> **row-major tile 存储布局**

即：

- 写入时不做数据重排
- 内部不采用转置式存储

## 14. 数据重排策略

`fa_buffer_cluster` 采用：

> **写入时不重排，输出流时重排**

也就是：

- DMA 写入时，只按 row-major tile 存起来
- 执行 `BUF_STREAM_*` 时，再根据目标 stream 协议做重排

## 15. 输出流格式

### 15.1 `Q stream`

`Q` 的输出流格式应匹配 `compute_core` 的 `QK` 输入协议：

- 按归约维切片
- 每拍 `16 lane`
- lane 对应 16 行 query 在同一归约维位置上的值

### 15.2 `K stream`

`K` 的输出流格式同样匹配 `QK` 输入协议：

- 按归约维切片
- 每拍 `16 lane`
- lane 对应 16 行 key 在同一归约维位置上的值

### 15.3 `V stream`

`V` 的输出流格式匹配 `PV` 输入协议：

- 按列向量输出
- 每拍 `16 lane`
- lane 对应 16 行在同一列特征位置上的值

这些输出顺序是：

> **协议级硬约束**

不是可自由变更的内部实现细节。

## 16. `BUF_STREAM_*` 完成语义

一次 `BUF_STREAM_*` 操作对应输出一个完整 tile 的流。

完成条件为：

> 当前 tile 的最后一个输出 beat 成功握手之后

也就是：

- `valid & ready`
- 且该 beat 为 `last`

之后本次操作才 `done`。

## 17. `BUF_FILL_*` 完成语义

一次 `BUF_FILL_*` 操作的完成条件为：

> 当前 tile 的最后一个 DMA 写入 beat 成功握手之后

也就是：

- `dma_w_valid & dma_w_ready`
- 且该 beat 为 `dma_w_last`

此后该 tile 才算完整可用。

## 18. `BUF_SWAP_KV` 完成语义

`BUF_SWAP_KV` 是一个控制类操作，不涉及数据搬运。

它的完成条件定义为：

> active/prefetch bank 角色切换完成后立即 `done`

即：

- 更新内部 bank 角色指针
- 立即完成

## 19. 并发能力

`fa_buffer_cluster` 必须支持受控并发：

- `active K/V bank` 读出
- `prefetch K/V bank` 写入

可以并发进行。

但不允许：

- 同一 bank 同时被读和写
- 同一 bank 出现读写冲突

## 20. 流协议语义

### 20.1 写侧（DMA）

DMA 写入侧必须严格遵守：

- `valid`
- `ready`
- `data`
- `last`

规则：

- 写指针只在 `valid & ready` 时推进
- `last` 标记当前 tile 写入尾 beat

### 20.2 读侧（stream 输出）

stream 读出侧也必须严格遵守：

- `valid`
- `ready`
- `data`
- `last`

规则：

- 读指针只在 `valid & ready` 时推进
- 若 `valid=1` 且 `ready=0`
  - `data/last` 必须保持稳定

## 21. Ready 与调度边界

`fa_buffer_cluster` 负责维护本地数据状态事实，包括：

- `q_valid`
- `k_valid`
- `v_valid`
- active/prefetch bank 角色

但它不负责：

- 何时进入 `QK`
- 何时进入 `PV`
- 何时进入下一 tile
- 何时执行全局 phase 切换

这些都属于：

- `fa_scheduler`

的职责。

## 22. 总结

`fa_buffer_cluster` 是当前架构中的输入矩阵 tile 存储与流适配模块：

- 只处理 `Q/K/V`
- `Q` 单缓冲，`K/V` 双缓冲
- 支持 `K/V` active/prefetch 并发
- 写入时保持 row-major 存储
- 输出时根据 `QK/PV` 协议重排
- 以 tile 级命令和标准流协议工作

这份规格已经足够支撑后续 top-down RTL 编码。*** End Patch
***
End Patch
