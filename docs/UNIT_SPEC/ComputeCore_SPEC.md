# ComputeCore SPEC

## 状态

本文档定义当前 Flash Attention 加速器中 `fa_compute_core` 的规格说明。  
它基于当前已经收敛的 `16x16` 单 shared core 架构，并与 `TOP_SPEC`、`Scheduler_SPEC`、`BufferCluster_SPEC`、`VPU_SPEC` 对齐。

## 1. 模块概述

`fa_compute_core` 是系统中的**共享矩阵乘加核心**。

它只负责两类矩阵计算：

- `QK`
- `PV`

当前架构下，`fa_compute_core` 固定为：

- 单实例
- 单 issue
- 单时刻只执行一种 mode
- 固定 `16x16` 脉动阵列（systolic array）

`fa_compute_core` 不负责：

- softmax
- causal mask
- `P` 的生成或长期缓存
- `m/l/Oacc`
- 最终量化
- DMA / buffer 地址控制

## 2. 模块核心职责

`fa_compute_core` 的核心职责如下：

1. 接收来自 `fa_scheduler` 的 tile 级矩阵任务启动请求。
2. 根据 `core_mode` 选择执行：
   - `QK`
   - `PV`
3. 在 `QK` 模式下：
   - 消费 `Q/K` 输入流
   - 产生完整 `score tile`
4. 在 `PV` 模式下：
   - 先装载 `P`
   - 再消费 `V`
   - 产生完整 `pv tile`
5. 输出高精度乘加结果，不在内部量化。
6. 在最后一个输出 beat 成功握手后产生 `done`。

## 3. 子模块概述

逻辑上建议将 `fa_compute_core` 划分为以下几个子块：

| 子模块 | 子模块功能 |
|---|---|
| `cc_ctrl` | 管理 `start/core_mode/busy/done` 生命周期。 |
| `cc_mode_decode` | 根据 `core_mode` 选择 `QK` 或 `PV` 数据路径。 |
| `cc_qk_datapath` | `QK` 模式的数据流与阵列驱动。 |
| `cc_pv_datapath` | `PV` 模式的数据流与阵列驱动。 |
| `cc_systolic_array` | 固定 `16x16` MAC 脉动阵列。 |
| `cc_output_adapter` | 输出 tile 结果流并生成 `last`。 |

## 4. 顶层端口说明

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | `compute_core` 工作时钟 |
| `rst_n` | input | 1 | 低有效复位 |
| `start` | input | 1 | 启动一次 tile 级矩阵任务 |
| `core_mode` | input | 2 | `QK/PV` 模式选择 |
| `busy` | output | 1 | 当前 tile 级任务执行中 |
| `done` | output | 1 | 当前 tile 级任务完整结束 |
| `q_stream_valid` | input | 1 | `Q` 输入流有效 |
| `q_stream_data` | input | `16 * ELEM_WIDTH` | `Q` 输入流数据 |
| `q_stream_last` | input | 1 | `Q tile` 输入结束 |
| `q_stream_ready` | output | 1 | `Q` 输入流就绪 |
| `k_stream_valid` | input | 1 | `K` 输入流有效 |
| `k_stream_data` | input | `16 * ELEM_WIDTH` | `K` 输入流数据 |
| `k_stream_last` | input | 1 | `K tile` 输入结束 |
| `k_stream_ready` | output | 1 | `K` 输入流就绪 |
| `p_stream_valid` | input | 1 | `P` 输入流有效 |
| `p_stream_data` | input | `16 * ELEM_WIDTH` | `P` 输入流数据 |
| `p_stream_last` | input | 1 | `P tile` 输入结束 |
| `p_stream_ready` | output | 1 | `P` 输入流就绪 |
| `v_stream_valid` | input | 1 | `V` 输入流有效 |
| `v_stream_data` | input | `16 * ELEM_WIDTH` | `V` 输入流数据 |
| `v_stream_last` | input | 1 | `V tile` 输入结束 |
| `v_stream_ready` | output | 1 | `V` 输入流就绪 |
| `score_stream_valid` | output | 1 | `score tile` 输出流有效 |
| `score_stream_data` | output | `16 * ACC_WIDTH` | `score tile` 输出流数据 |
| `score_stream_last` | output | 1 | `score tile` 输出结束 |
| `score_stream_ready` | input | 1 | `score tile` 输出流就绪 |
| `pv_stream_valid` | output | 1 | `pv tile` 输出流有效 |
| `pv_stream_data` | output | `16 * ACC_WIDTH` | `pv tile` 输出流数据 |
| `pv_stream_last` | output | 1 | `pv tile` 输出结束 |
| `pv_stream_ready` | input | 1 | `pv tile` 输出流就绪 |

## 5. 资源模型

`fa_compute_core` 的资源模型固定为：

- 单实例
- 单 issue
- 单 mode

即：

- `QK` 与 `PV` 时分复用同一套 `16x16` 阵列

## 6. 核心计算结构

`fa_compute_core` 采用：

> **固定 `16x16` 脉动阵列（systolic array）**

每个 PE 内执行 MAC。

## 7. 模式语义

### 7.1 `CORE_MODE_QK`

计算：

```text
Q_tile[TILE_BR, HEAD_DIM] x K_tile^T[HEAD_DIM, TILE_BC]
-> score_tile[TILE_BR, TILE_BC]
```

### 7.2 `CORE_MODE_PV`

计算：

```text
P_tile[TILE_BR, TILE_BC] x V_tile[TILE_BC, HEAD_DIM]
-> pv_tile[TILE_BR, HEAD_DIM]
```

## 8. QK 模式数据流

### 数据流范式

- `QK` 模式采用 **output-stationary**

### 输入格式

`q_stream / k_stream` 都采用：

- 按归约维切片的 `16-lane` 流

第 `t` 个 beat：

- `q_stream_data = Q[0][t], Q[1][t], ..., Q[15][t]`
- `k_stream_data = K[0][t], K[1][t], ..., K[15][t]`

### 输出格式

`score_stream` 表示完整 `score tile`：

- 输出顺序：**tile 内 row-major**

## 9. PV 模式数据流

### 数据流范式

- `PV` 模式采用 **P-stationary**

### P 装载语义

在 `PV` 模式下：

- scheduler 只发一次 `start`
- `compute_core` 内部先装载 `P tile`
- 然后再消费 `V tile`
- 最后输出 `pv tile`

### 输入格式

#### `p_stream`

- 按列装载 `P`
- 第 `j` 个 beat：
  - `P[0][j], P[1][j], ..., P[15][j]`

#### `v_stream`

- 按列向量输入 `V[:, n]`
- 第 `n` 个 beat：
  - `V[0][n], V[1][n], ..., V[15][n]`

### 输出格式

`pv_stream` 表示完整 `pv tile`：

- 输出顺序：**按列向量 column-major**

## 10. 数值语义

`fa_compute_core` 输出的是高精度乘加结果：

- `score_stream`
- `pv_stream`

不在内部量化为最终 `Q8.8`。

## 11. `busy/done` 语义

### `busy`

覆盖当前 tile 任务的完整生命周期。

### `done`

定义为：

- 最后一个输出 beat 成功握手后产生

即：
- `QK`：`score_stream_last` 握手后 `done`
- `PV`：`pv_stream_last` 握手后 `done`

## 12. 流接口语义

所有输入输出流严格遵守：

- `valid`
- `ready`
- `last`

未握手时：
- 不推进内部读/写指针
- 输出数据和 `last` 保持稳定

## 13. 参数约束

通过 compile-time parameter 给定：

- `SEQ_LEN`
- `HEAD_DIM`
- `TILE_BR`
- `TILE_BC`
- `ARRAY_DIM`
- `ELEM_WIDTH`
- `ACC_WIDTH`

当前固定约束：

- `ARRAY_DIM = 16`
- `HEAD_DIM % 16 == 0`

## 14. 小 tile 处理

当：

- `TILE_BR < 16`
- `TILE_BC < 16`

时：

- 由上游进行零填充或无效 lane 语义处理
- `compute_core` 本身不增加复杂 lane mask 网络

## 15. Reset 语义

reset 到来时：

- 立即中止当前 tile 任务
- 清除内部运行状态
- `busy = 0`
- `done = 0`
- 输出 `valid = 0`

不保留部分计算上下文。

## 16. 总结

`fa_compute_core` 是当前架构中的共享矩阵乘加核心：

- 固定 `16x16` 脉动阵列
- 单实例、单 issue、单 mode
- `QK` 使用 `output-stationary`
- `PV` 使用 `P-stationary`
- `QK/PV` 时分复用
- 只输出高精度中间结果

这份规格定义了当前实现阶段稳定的 `ComputeCore` 接口与行为边界。
