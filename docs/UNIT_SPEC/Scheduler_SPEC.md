# Scheduler SPEC

## 状态

本文档定义当前 Flash Attention 加速器中 `fa_scheduler` 的规格说明。  
它基于当前已经收敛的 `16x16` 单 shared core 架构，并与 `TOP_SPEC`、`AddrGen_SPEC`、`BufferCluster_SPEC`、`ComputeCore_SPEC`、`VPU_SPEC`、`DMAEngine_SPEC` 对齐。

## 1. 模块概述

`fa_scheduler` 是整个系统中**唯一的全局 tile 级控制主模块**。

它负责组织一次完整 attention run 的执行流程，并驱动：

- `fa_addr_gen`
- `fa_dma_engine`
- `fa_buffer_cluster`
- `fa_compute_core`
- `fa_vpu`

`fa_scheduler` 不负责：

- 矩阵乘加
- softmax / 向量计算
- DMA 地址算术
- buffer 内部微地址生成
- row/beat 级控制

baseline 实现模型为：

- **单主 FSM**
- **显式上下文寄存器**
- **tile 级命令**

## 2. 模块核心职责

`fa_scheduler` 的核心职责如下：

1. 接收 `start` 并启动一次 attention run。
2. 维护当前执行上下文：
   - `cur_q_tile_idx`
   - `cur_kv_tile_idx`
   - `phase_state`
   - `kv_active_bank`
   - `kv_prefetch_bank`
   - `kv_prefetch_valid`
3. 按 tile 粒度推进以下主流程：
   - `LOAD_Q`
   - `VPU_INIT`
   - `KV_LOOP`
   - `VPU_FINAL`
   - `STORE_O`
4. 在 `KV_LOOP` 中组织：
   - `LOAD_K`
   - `LOAD_V`
   - `ARM_QK_PATH`
   - `RUN_QK`
   - `WAIT_VPU_SCORE`
   - `ARM_PV_PATH`
   - `RUN_PV`
   - `WAIT_VPU_ACCUM`
5. 管理 `K/V` 双缓冲与显式 `swap`
6. 在 `causal_en=1` 时执行 tile 级 skip 判定
7. 生成系统状态：
   - `status_idle`
   - `status_busy`
   - `status_done`
   - `status_error`
   - `perf_cycles`
   - `debug_q_tile`
   - `debug_kv_tile`

## 3. 子模块概述

逻辑上建议将 `fa_scheduler` 划分为以下子块：

| 子模块 | 子模块功能 |
|---|---|
| `sched_run_ctrl` | 管理 run 生命周期、`busy/done/error`、`done_clr`、soft reset。 |
| `sched_context_regs` | 维护 tile 索引、bank 状态和 phase 上下文。 |
| `sched_phase_fsm` | 主状态机，负责 phase 顺序推进。 |
| `sched_issue_ctrl` | 向下游模块发出 tile 级 `start/op` 命令。 |
| `sched_status_dbg` | 生成性能计数和软件可见调试状态。 |

## 4. 顶层端口说明

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | scheduler 工作时钟 |
| `rst_n` | input | 1 | 低有效复位 |
| `start` | input | 1 | 启动一次 attention run |
| `done_clr` | input | 1 | 清除完成锁存态 |
| `causal_en` | input | 1 | 使能 causal tile 级 skip |
| `addrgen_start` | output | 1 | 启动一次地址生成 |
| `addrgen_mem_sel` | output | 2 | 选择 `Q/K/V/O` 地址类型 |
| `addrgen_tile_idx` | output | `TILE_INDEX_WIDTH` | 当前地址生成请求对应的 tile 编号 |
| `addrgen_done` | input | 1 | 地址生成完成 |
| `dma_start` | output | 1 | 启动一次 DMA 操作 |
| `dma_op` | output | 2 | DMA 操作类型：`LOAD_Q / LOAD_K / LOAD_V / STORE_O` |
| `dma_busy` | input | 1 | DMA 正忙 |
| `dma_done` | input | 1 | DMA 当前操作完成 |
| `dma_error` | input | 1 | DMA 上报错误 |
| `buf_start` | output | 1 | 启动一次 buffer 操作 |
| `buf_op` | output | 3 | buffer 操作类型 |
| `buf_pingpong_sel` | output | 1 | K/V bank 选择 |
| `buf_word_count` | output | 8 | 当前 buffer 操作字数或 beat 数 |
| `buf_busy` | input | 1 | buffer 正忙 |
| `buf_done` | input | 1 | buffer 操作完成 |
| `core_start` | output | 1 | 启动一次 compute core 操作 |
| `core_mode` | output | 2 | `QK / PV` 模式选择 |
| `core_busy` | input | 1 | compute core 正忙 |
| `core_done` | input | 1 | compute core 操作完成 |
| `vpu_start` | output | 1 | 启动一次 VPU 操作 |
| `vpu_op` | output | 3 | `INIT / SCORE_TO_P / ACCUM_PV / FINALIZE_O` |
| `vpu_q_tile_idx` | output | `TILE_INDEX_WIDTH` | 送给 VPU 的当前 `q_tile` 编号 |
| `vpu_kv_tile_idx` | output | `TILE_INDEX_WIDTH` | 送给 VPU 的当前 `kv_tile` 编号 |
| `vpu_busy` | input | 1 | VPU 正忙 |
| `vpu_done` | input | 1 | VPU 操作完成 |
| `status_idle` | output | 1 | 当前空闲，可接受新 run |
| `status_busy` | output | 1 | 当前 run 正在执行 |
| `status_done` | output | 1 | 当前或最近一次 run 已完整完成 |
| `status_error` | output | 1 | 当前或最近一次 run 发生错误 |
| `perf_cycles` | output | 32 | 当前或最近一次 run 的端到端周期数 |
| `debug_q_tile` | output | 8 | 当前主执行上下文 `q_tile_idx` |
| `debug_kv_tile` | output | 8 | 当前主执行上下文 `kv_tile_idx` |

## 5. 控制粒度与接口风格

- 仅做 **tile 级控制**
- 不涉足 row/beat 级控制
- 所有从模块统一采用：
  - 单拍 `start`
  - `busy`
  - `done`

## 6. 主执行流程

每个 `q_tile` 的 baseline 生命周期如下：

1. `LOAD_Q`
2. `VPU_INIT`
3. `KV_LOOP`
4. `VPU_FINAL`
5. `STORE_O`

### 6.1 `LOAD_Q`

`LOAD_Q` 是一个**复合 phase**，由：

- `DMA_LOAD_Q`
- `BUF_FILL_Q`

配对执行组成。

完成条件：

- `dma_done`
- `buf_done`

都完成。

### 6.2 `KV_LOOP`

每个 `kv_tile` 的处理顺序固定为：

1. `LOAD_K`
2. `LOAD_V`
3. `ARM_QK_PATH`
4. `RUN_QK`
5. `WAIT_VPU_SCORE`
6. `ARM_PV_PATH`
7. `RUN_PV`
8. `WAIT_VPU_ACCUM`
9. `SWAP_KV`（若需要）

### 6.3 `LOAD_K / LOAD_V`

`LOAD_K` 与 `LOAD_V` 都是复合 phase，分别由：

- `DMA_LOAD_K` + `BUF_FILL_K`
- `DMA_LOAD_V` + `BUF_FILL_V`

配对执行组成。

完成条件：

- `dma_done`
- `buf_done`

都完成。

## 7. Buffer Stream 与 Compute/VPU 的配对并发关系

### 7.1 `ARM_QK_PATH`

`RUN_QK` 之前必须先完成：

- 启动 `VPU_SCORE_TO_P`
- 启动 `BUF_STREAM_Q`
- 启动 `BUF_STREAM_K`

也就是说：

- `Q/K` 的流式输出
- `ComputeCore(QK)` 的执行
- `VPU_SCORE_TO_P` 对 `score_stream` 的消费

在行为上形成一组：

> **先 arm 消费者，再启动生产者**

的配对并发关系。

### 7.2 `RUN_QK`

`RUN_QK` 负责真正启动 `compute_core` 的 `QK` 模式。

其发射条件只检查直接依赖：

- `Q ready`
- `active K ready`
- `compute_core idle`
- 当前 tile 不是 causal skip tile

### 7.3 `WAIT_VPU_SCORE`

等待条件：

- `vpu_done`

其语义为：

- 当前 `P tile` 已完整写入 `P buffer`

## 8. `P` 重放与 PV 路径

### 8.1 `ARM_PV_PATH`

`RUN_PV` 前必须完成：

- 启动 `BUF_STREAM_V`

同时：

- `P tile` 已在 `WAIT_VPU_SCORE` 结束时准备好

### 8.2 `P` 重放语义

`P buffer` 的重放：

- **不新增独立 scheduler phase**
- **不要求 scheduler 再额外发一次 `vpu_start`**

而是：

- 作为 `RUN_PV` 的隐式子行为
- 在 `RUN_PV` 期间由 `VPU` 自主从 `P buffer` 重放 `p_stream`

### 8.3 `RUN_PV`

`RUN_PV` 负责真正启动 `compute_core` 的 `PV` 模式。

其发射条件只检查直接依赖：

- `P ready`
- `active V ready`
- `compute_core idle`

### 8.4 `WAIT_VPU_ACCUM`

等待条件：

- `vpu_done`

其语义为：

- 当前 `pv tile` 已完整并入 `Oacc`

## 9. K/V 双缓冲与预取重叠

baseline 中：

- `Q` 不预取重叠
- `K/V` 支持双缓冲与预取重叠

仅支持：

- `1 active K/V bank`
- `1 prefetch K/V bank`

`swap` 规则：

- 仅在当前 tile pair 的 `WAIT_VPU_ACCUM` 完成后允许执行
- 且 `prefetch K/V bank` 已 ready

## 10. VPU 调度边界

- `VPU_INIT`
  - 每个 `q_tile` 必须显式执行
- `VPU_SCORE_TO_P`
  - 在 `ARM_QK_PATH` 中被启动
- `VPU_ACCUM_PV`
  - 作为 `RUN_PV` 的消费者在 `ARM_PV_PATH/RUN_PV` 链路中工作
- `VPU_FINALIZE_O`
  - 仅在当前 `q_tile` 最后一个合法 `kv_tile` 的 `WAIT_VPU_ACCUM` 完成后触发

## 11. causal 语义

当 `causal_en=1` 时：

- 若 `kv_tile_idx > q_tile_idx`
  - 整 tile 跳过
- 若 `kv_tile_idx <= q_tile_idx`
  - 正常进入计算流程

tile 内 causal mask：

- 由 `VPU_SCORE_TO_P` 处理

因此 scheduler 必须向 VPU 显式提供：

- `q_tile_idx`
- `kv_tile_idx`

## 12. 完成与错误语义

### 12.1 `STORE_O`

`STORE_O` 的完成条件为：

- `dma_done`

### 12.2 全局 `status_done`

全局 `status_done` 置位条件为：

- 最后一个 `q_tile` 的 `STORE_O` 完成

即最终结果已完整写回外存。

### 12.3 `status_error`

baseline 中 `status_error` 来源至少包括：

- `dma_error`
- scheduler 检测到的非法控制状态

## 13. `done_clr` 与 `SOFT_RESET`

### 13.1 `done_clr`

- 只清除 `status_done`
- 不承担 abort/cancel 功能

### 13.2 `SOFT_RESET`

- 立即中止当前 run
- 清空执行状态
- 直接回到 `IDLE`

## 14. `perf_cycles` 与调试状态

### `perf_cycles`

定义为：

- 从接受 `start`
- 到最后一个 `STORE_O` 的 `dma_done`

的端到端总周期数。

### `debug_q_tile/debug_kv_tile`

定义为：

- 当前主执行上下文的 tile 索引

不表示预取槽位或内部瞬时状态。

## 15. 参数与位宽边界

当前仍有若干固定宽度接口：

- `TILE_INDEX_WIDTH`
- `buf_word_count`
- `debug_q_tile`
- `debug_kv_tile`

因此当前 baseline 的参数支持范围默认受这些位宽限制。  
若后续扩大参数空间，应同步扩大对应位宽或改为自动推导。

## 16. 总结

`fa_scheduler` 是当前系统中唯一的全局 tile 级控制主模块：

- 单主 FSM
- 显式上下文寄存器
- 使用“先 arm 消费者，再启动生产者”的配对并发 phase 语义
- 驱动 `AddrGen / DMA / Buffer / ComputeCore / VPU`
- 负责 `K/V` 双缓冲与预取重叠
- 汇总系统状态并对软件可见

这份规格定义了当前实现阶段稳定的 `Scheduler` 接口与行为边界。
