# VPU SPEC

## 状态

本文档定义当前 Flash Attention 加速器中 `fa_vpu` 的规格说明。  
它基于当前已经收敛的 `16x16` 单 shared core 架构，并与 `TOP_SPEC`、`Scheduler_SPEC`、`ComputeCore_SPEC` 最终统一接口决议保持一致。

## 1. 模块概述

`fa_vpu` 是系统中的**向量与非线性处理核心**。

它负责：

- `score -> P`
- `pv -> Oacc`
- `final normalize -> O`

并持有全部 attention 中间向量状态：

- `P`
- `m`
- `l`
- `Oacc`

`fa_vpu` 不负责：

- 任何矩阵乘加
- `Q/K/V` tile 存储
- DMA 地址生成
- 外存写回执行

## 2. 模块核心职责

`fa_vpu` 的核心职责如下：

1. 接收来自 `fa_scheduler` 的 tile 级向量任务启动请求。
2. 根据 `vpu_op` 执行：
   - `VPU_INIT`
   - `VPU_SCORE_TO_P`
   - `VPU_ACCUM_PV`
   - `VPU_FINALIZE_O`
3. 在 `INIT` 中初始化：
   - `m`
   - `l`
   - `Oacc`
4. 在 `SCORE_TO_P` 中：
   - 消费 `score tile`
   - 执行 `scale / mask / row max / exp / row sum`
   - 生成并缓存 `P tile`
5. 在 `ACCUM_PV` 中：
   - 消费 `pv tile`
   - 更新 `Oacc`
6. 在 `FINALIZE_O` 中：
   - 读取 `Oacc / l`
   - 执行最终归一化
   - 量化为 `Q8.8`
   - 通过 `o_stream` 输出完整 `O tile`
7. 在 `PV` 阶段从 `P buffer` 重放 `p_stream` 给 `compute_core`

## 3. 子模块概述

逻辑上建议将 `fa_vpu` 划分为以下子块：

| 子模块 | 子模块功能 |
|---|---|
| `vpu_ctrl` | 管理 `start/op/busy/done` 生命周期。 |
| `vpu_score_pipe` | 执行 `score -> P` 的向量数值路径。 |
| `vpu_p_buffer` | 保存 `P tile` 并支持按列重放。 |
| `vpu_state_buffer` | 保存 `m / l / Oacc`。 |
| `vpu_accum_pipe` | 执行 `pv -> Oacc` 路径。 |
| `vpu_finalize_pipe` | 执行最终归一化和量化。 |
| `vpu_output_adapter` | 组织 `p_stream` 与 `o_stream` 输出顺序和 `last`。 |

## 4. 顶层端口说明

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | `VPU` 工作时钟 |
| `rst_n` | input | 1 | 低有效复位 |
| `start` | input | 1 | 启动一次 VPU 操作 |
| `vpu_op` | input | 3 | 操作类型：`INIT / SCORE_TO_P / ACCUM_PV / FINALIZE_O` |
| `busy` | output | 1 | 当前 VPU 操作执行中 |
| `done` | output | 1 | 当前 VPU 操作完成 |
| `q_tile_idx` | input | `TILE_INDEX_WIDTH` | 当前 `q_tile` 编号 |
| `kv_tile_idx` | input | `TILE_INDEX_WIDTH` | 当前 `kv_tile` 编号 |
| `score_stream_valid` | input | 1 | `score tile` 输入流有效 |
| `score_stream_data` | input | `16 * ACC_WIDTH` | `score tile` 输入流数据 |
| `score_stream_last` | input | 1 | `score tile` 输入结束 |
| `score_stream_ready` | output | 1 | `score tile` 输入流就绪 |
| `pv_stream_valid` | input | 1 | `pv tile` 输入流有效 |
| `pv_stream_data` | input | `16 * ACC_WIDTH` | `pv tile` 输入流数据 |
| `pv_stream_last` | input | 1 | `pv tile` 输入结束 |
| `pv_stream_ready` | output | 1 | `pv tile` 输入流就绪 |
| `p_stream_valid` | output | 1 | `P tile` 输出流有效 |
| `p_stream_data` | output | `16 * ELEM_WIDTH` | `P tile` 输出流数据 |
| `p_stream_last` | output | 1 | `P tile` 输出结束 |
| `p_stream_ready` | input | 1 | `P tile` 输出流就绪 |
| `o_stream_valid` | output | 1 | 最终 `O tile` 输出流有效 |
| `o_stream_data` | output | `DMA_DATA_WIDTH` | 最终 `O tile` 输出流数据 |
| `o_stream_last` | output | 1 | 最终 `O tile` 输出结束 |
| `o_stream_ready` | input | 1 | 最终 `O tile` 输出流就绪 |
| `neg_large` | input | `CFG_DATA_WIDTH` | mask 使用的负大数常量 |
| `scale` | input | `CFG_DATA_WIDTH` | `1/sqrt(d)` 缩放常量 |

## 5. 内部状态集合

`fa_vpu` 内部必须显式包含以下状态：

- `P tile buffer`
- `m buffer`
- `l buffer`
- `Oacc buffer`

## 6. 状态作用域

### 6.1 `P buffer`

- 作用域：**tile pair 级**
- 即当前 `q_tile × kv_tile`

### 6.2 `m / l / Oacc`

- 作用域：**q_tile 级**
- 跨越当前 `q_tile` 的所有合法 `kv_tile`
- 直到 `FINALIZE_O` 完成后释放/覆盖

## 7. 操作语义

### 7.1 `VPU_INIT`

职责：

- 初始化当前 `q_tile` 的：
  - `m`
  - `l`
  - `Oacc`

建议初始化：

- `m = NEG_LARGE`
- `l = 0`
- `Oacc = 0`

不初始化 `P buffer`。

### 7.2 `VPU_SCORE_TO_P`

职责：

- 消费当前 `score tile`
- 执行：
  - `scale`
  - `causal mask`
  - row max
  - `exp`
  - row sum / reciprocal
- 生成当前 `P tile`
- 将 `P tile` 完整写入内部 `P buffer`

完成条件：

- `P buffer` 已完整写好

### 7.3 `VPU_ACCUM_PV`

职责：

- 消费当前 `pv tile`
- 将其并入当前 `q_tile` 的累计状态

对外抽象上主要更新：

- `Oacc`

实现上允许同时维护与 online softmax 相关的 `m/l` 派生状态，但不直接产生最终 `O`。

### 7.4 `VPU_FINALIZE_O`

职责：

- 读取 `Oacc / l`
- 完成最终归一化
- 量化为 `Q8.8`
- 通过 `o_stream` 输出完整 `O tile`

完成条件：

- 最后一个 `o_stream` beat 成功握手之后

## 8. 输入流语义

### 8.1 `score_stream`

仅在 `VPU_SCORE_TO_P` 中有效。

语义：

- 输入为 `score tile`
- 逻辑顺序：**tile 内 row-major**
- 位宽：`16 * ACC_WIDTH`

### 8.2 `pv_stream`

仅在 `VPU_ACCUM_PV` 中有效。

语义：

- 输入为 `pv tile`
- 逻辑顺序：**按列向量 column-major**
- 位宽：`16 * ACC_WIDTH`

## 9. `P` 的输出语义

`P` 不在 `SCORE_TO_P` 阶段实时透传。

而是：

- `SCORE_TO_P` 只负责生成并缓存 `P`
- `PV` 阶段由 `VPU` 从 `P buffer` 重放 `p_stream`

### `p_stream` 语义

- 去向：`compute_core(PV)`
- 位宽：`16 * ELEM_WIDTH`
- 顺序：**按列重放**

第 `j` 个 beat：

- `P[0][j], P[1][j], ..., P[15][j]`

当 `TILE_BR < 16` 时：

- `p_stream` 仍保持固定 `16-lane` 位宽
- 对于 `row >= TILE_BR` 的 lane：
  - 由 `VPU` 输出零值或按无效 lane 语义处理
- `compute_core` 不应依赖这些 lane 承载有效数据

## 10. `O` 的输出语义

### `o_stream`

- 去向：`DMA`
- 承载最终 `O tile`
- 位宽：`DMA_DATA_WIDTH`
- 顺序：**row-major**

`pv_stream` 是 column-major，中间经过 `Oacc` 缓冲与最终格式整理后，`o_stream` 输出为 row-major。

当 `TILE_BR < 16` 时：

- `o_stream` 仍保持固定 `DMA_DATA_WIDTH`
- 输出 beat 总数只覆盖真实 `O tile` 的有效元素
- 不要求为不存在的行插入伪数据或额外填充行

## 11. causal 支持

`fa_vpu` 负责 tile 内 causal mask。

因此在 `VPU_SCORE_TO_P` 中，必须接收：

- `q_tile_idx`
- `kv_tile_idx`

用于判断：

- 当前是否为对角 tile
- 是否需要在 tile 内应用 causal mask

## 12. `busy/done` 语义

### 12.1 `busy`

覆盖当前 `vpu_op` 的完整生命周期。

### 12.2 `done`

按操作类型定义：

- `VPU_INIT`
  - `m/l/Oacc` 初始化完成后 `done`
- `VPU_SCORE_TO_P`
  - `P tile` 已完整写入 `P buffer` 后 `done`
- `VPU_ACCUM_PV`
  - 当前 `pv tile` 已完整并入 `Oacc` 后 `done`
- `VPU_FINALIZE_O`
  - 最后一个 `o_stream` beat 成功握手后 `done`

## 13. 流协议语义

`score_stream`、`pv_stream`、`p_stream`、`o_stream` 全部严格遵守：

- `valid`
- `ready`
- `last`

规则：

- 未握手不前进
- 若 `valid=1` 且 `ready=0`
  - 当前数据与 `last` 必须保持稳定

## 14. 输出可见性边界

以下内容全部是 `VPU` 私有状态，不对外暴露显式数据端口：

- `P`
- `m`
- `l`
- `Oacc`

它们不应被：

- `TOP`
- `Scheduler`
- `DMA`
- `BufferCluster`

直接读写。

## 15. Reset 语义

reset 到来时：

- 立即中止当前 VPU 操作
- 清空：
  - `P buffer`
  - `m`
  - `l`
  - `Oacc`
- `busy = 0`
- `done = 0`
- `p_stream_valid = 0`
- `o_stream_valid = 0`

不保留部分 tile 上下文。

## 16. 总结

`fa_vpu` 是当前架构中的向量与非线性处理核心：

- 负责 `score -> P`
- 负责 `pv -> Oacc`
- 负责 `final normalize -> O`
- 保存 `P / m / l / Oacc`
- 使用类型化输入流：
  - `score_stream`
  - `pv_stream`
- 使用类型化输出流：
  - `p_stream`
  - `o_stream`

这份规格定义了当前实现阶段稳定的 `VPU` 接口与行为边界。
