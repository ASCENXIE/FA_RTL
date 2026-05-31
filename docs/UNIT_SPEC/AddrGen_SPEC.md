# AddrGen SPEC

## 状态

本文档定义当前 Flash Attention 加速器中 `fa_addr_gen` 的规格说明。  
它基于当前已经收敛的 `16x16` 单 shared core 架构，并与 `TOP_SPEC`、`Scheduler_SPEC` 的最终统一接口决议保持一致。

## 1. 模块概述

`fa_addr_gen` 是一个**片外 DMA 地址与传输字节数生成模块**。

它根据 scheduler 给出的 tile 级请求，生成：

- `dma_addr`
- `dma_bytes`

`fa_addr_gen` 的职责只限于：

- 片外地址生成
- tile 级传输字节数生成

它不负责：

- row 级地址流
- beat 级地址流
- AXI burst 拆分
- 片内 buffer 寻址
- compute_core / VPU 内部索引

## 2. 模块核心职责

`fa_addr_gen` 的核心职责如下：

1. 接收 scheduler 发出的单个 tile 级地址请求。
2. 根据 `mem_sel` 选择当前目标张量：
   - `Q`
   - `K`
   - `V`
   - `O`
3. 根据 `tile_idx` 计算当前 tile 的起始行。
4. 根据：
   - `base_addr`
   - `stride_bytes`
   - `start_row`
   生成 `dma_addr`
5. 根据：
   - `tile_rows`
   - `HEAD_DIM`
   - `ELEM_BYTES`
   生成 `dma_bytes`
6. 在固定短延迟后给出结果，并通过 `done` 表示完成。

## 3. 子模块概述

逻辑上建议将 `fa_addr_gen` 划分为以下子块：

| 子模块 | 子模块功能 |
|---|---|
| `arg_req_latch` | 锁存一次 tile 级请求。 |
| `arg_mem_decode` | 根据 `mem_sel` 选择目标张量的 base 地址和 tile 高度。 |
| `arg_row_calc` | 根据 `tile_idx` 计算起始行。 |
| `arg_addr_calc` | 根据地址公式生成 `dma_addr`。 |
| `arg_size_calc` | 根据 tile 尺寸和 `HEAD_DIM` 生成 `dma_bytes`。 |
| `arg_resp_ctrl` | 组织输出保持与 `done` 生成。 |

## 4. 顶层端口说明

| 端口名 | 端口方向 | 端口位宽 | 端口功能 |
|---|---|---:|---|
| `clk` | input | 1 | `AddrGen` 工作时钟 |
| `rst_n` | input | 1 | 低有效复位 |
| `start` | input | 1 | 启动一次 tile 级地址生成请求 |
| `mem_sel` | input | 2 | 选择目标张量：`Q/K/V/O` |
| `tile_idx` | input | `TILE_INDEX_WIDTH` | 当前 tile 编号 |
| `q_base` | input | 64 | `Q` 基地址 |
| `k_base` | input | 64 | `K` 基地址 |
| `v_base` | input | 64 | `V` 基地址 |
| `o_base` | input | 64 | `O` 基地址 |
| `stride_bytes` | input | 32 | 行 stride，单位字节 |
| `dma_addr` | output | 64 | 当前 tile 对应的 DMA 起始地址 |
| `dma_bytes` | output | `DMA_BYTES_WIDTH` | 当前 tile 对应的 DMA 总传输字节数 |
| `done` | output | 1 | 当前地址生成请求完成 |

## 5. 参数

`fa_addr_gen` 通过 compile-time parameter 获得静态尺寸配置：

- `SEQ_LEN`
- `HEAD_DIM`
- `TILE_BR`
- `TILE_BC`
- `ELEM_BYTES`
- `TILE_INDEX_WIDTH`
- `DMA_BYTES_WIDTH`

这些量不通过运行时普通输入端口传递。

## 6. 输入语义

### 6.1 `tile_idx`

`tile_idx` 始终表示：

> 当前是第几个 tile

不是行号，也不是字节偏移。

### 6.2 `stride_bytes`

当前架构中：

- `Q/K/V/O` 共用一条 `stride_bytes`

不再保留：

- `q_stride`
- `k_stride`
- `v_stride`
- `o_stride`

## 7. mem_sel 语义

建议编码如下：

| 编码 | 含义 |
|---|---|
| `2'b00` | `Q` |
| `2'b01` | `K` |
| `2'b10` | `V` |
| `2'b11` | `O` |

## 8. tile_rows 选择规则

由 `mem_sel` 自动决定：

- `Q/O`
  - `tile_rows = TILE_BR`
- `K/V`
  - `tile_rows = TILE_BC`

不需要 scheduler 再额外提供运行时 tile 高度。

## 9. 地址与长度公式

### 9.1 起始行

```text
start_row = tile_idx * tile_rows
```

### 9.2 起始地址

```text
dma_addr = base_addr + start_row * stride_bytes
```

### 9.3 传输字节数

```text
dma_bytes = tile_rows * HEAD_DIM * ELEM_BYTES
```

其中：

- `ELEM_BYTES = ELEM_WIDTH / 8`
- 当前 `Q8.8` baseline 下通常为 `2`

## 10. 当前 baseline 下的说明

在当前 baseline 中：

- `TILE_BR = 16`
- `TILE_BC = 16`
- `HEAD_DIM = 64`
- `ELEM_BYTES = 2`

因此：

- `Q/K/V/O` 四类 tile 的 `dma_bytes` 都相同
- 为 `16 * 64 * 2 = 2048 bytes`

但规格中仍然按 `mem_sel` 逻辑定义，不直接写死常数语义。

## 10.1 连续 tile 布局约束

虽然 `AddrGen` 对外只输出单个：

- `dma_addr`
- `dma_bytes`

当前 baseline 只有在以下条件成立时，这种抽象才对完整 tile 搬运是充分的：

```text
stride_bytes == HEAD_DIM * ELEM_BYTES
```

也就是：

- tile 在外存中必须连续布局
- 当前不支持带 padding 的逐行跨 stride tile 访存

## 11. `dma_bytes` 位宽

`dma_bytes` 的位宽不固定写死，而由 parameter 自动推导。

建议：

```text
MAX_TILE_ROWS   = max(TILE_BR, TILE_BC)
MAX_TILE_BYTES  = MAX_TILE_ROWS * HEAD_DIM * ELEM_BYTES
DMA_BYTES_WIDTH = ceil(log2(MAX_TILE_BYTES + 1))
```

## 12. 接口风格

`fa_addr_gen` 采用：

- 单拍 `start`
- 固定短延迟
- 单拍 `done`

建议语义：

- 第 `N` 拍接受 `start`
- 第 `N+1` 拍产生：
  - `dma_addr`
  - `dma_bytes`
  - `done`

## 13. 输出保持语义

当本次请求完成后：

- `dma_addr`
- `dma_bytes`

应保持稳定，直到下一次新的 `start` 覆盖它们。

## 14. 非职责范围

`fa_addr_gen` 不负责：

- row 级地址序列输出
- beat 级地址推进
- AXI burst 切分
- 片内地址生成
- 越界裁剪
- error 输出

## 15. 合法性与错误边界

运行时 tile 合法性不由 `AddrGen` 负责检查。

合法性来源于：

1. parameter 合法性检查
2. scheduler 提供的合法 `tile_idx`

baseline 中：

- `fa_addr_gen` 不提供独立 `error` 输出

## 16. 复位语义

reset 到来时：

- 清空内部请求状态
- `done = 0`
- 输出回到已定义空值

不保留任何上下文状态。

## 17. 总结

`fa_addr_gen` 是当前系统中的 tile 级片外地址生成模块：

- 单 tile 请求
- 单 tile 地址/字节数响应
- 单 `tile_idx`
- 单 `stride_bytes`
- compile-time 参数化
- 输出保持稳定直到下一次请求覆盖

这份规格定义了当前实现阶段稳定的 `AddrGen` 接口与行为边界。
