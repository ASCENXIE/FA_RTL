# `fa_dma_engine` 规格说明

## 1. 模块概述

`fa_dma_engine` 是 Flash Attention 加速器中的 tile 级 DMA 执行模块与 AXI Master 协议适配模块。

该模块接收上游 `fa_scheduler` 或地址生成/调度逻辑给出的单次 DMA 请求，根据请求中的 `dma_op`、`dma_addr` 和 `dma_bytes` 完成一次 tile 级搬运操作。对于 Q/K/V 输入 tile，DMA 从外部内存读取数据并写入 `buffer_cluster`；对于 O 输出 tile，DMA 从已经存放 O 结果的输出 buffer 读取数据，并写回外部内存。

`fa_dma_engine` 不负责生成 Q/K/V/O 的具体地址，也不保存 Q/K/V/O 的 base address。Q/K/V/O 地址的选择由上游 `scheduler`、`addr_gen` 或 CSR 配置路径完成。DMA 只执行当前被发起的单个 `dma_op` 请求。

`fa_dma_engine` 不直接接收计算通路的 O 输出流。计算通路应先将 O tile 写入输出 buffer，并在 O tile 可写回后通知 `scheduler`。随后由 `scheduler` 发起 `DMA_STORE_O` 请求，DMA 再从输出 buffer 读取 O tile 并写回外存。

baseline 设计中，`fa_dma_engine` 采用单实例、单 issue 模型。同一时刻只接受并执行一个 tile 级 DMA 请求。

## 2. 接口说明

### 2.1 时钟与复位

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `clk` | input | 1 | DMA 模块工作时钟。控制逻辑、buffer 访问接口和 AXI Master 接口均同步于该时钟。 |
| `rst_n` | input | 1 | 低有效复位。复位内部状态、锁存的请求参数、计数器和输出状态。 |

### 2.2 Scheduler 请求接口

该接口用于接收上游发起的单次 tile 级 DMA 请求。

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `start` | input | 1 | 启动一次 DMA 请求。`start` 为单周期脉冲，仅在 `busy == 0` 时被接受。 |
| `dma_op` | input | 2 | DMA 操作类型，编码见第 4.1 节。 |
| `dma_addr` | input | `MEM_ADDR_WIDTH` | 当前 DMA 请求的外部内存起始地址。DMA 不解释该地址属于 Q、K、V 还是 O，只按 `dma_op` 执行。 |
| `dma_bytes` | input | `DMA_BYTES_WIDTH` | 当前 DMA 请求的总传输字节数。 |
| `busy` | output | 1 | 当前 DMA 请求正在执行。 |
| `done` | output | 1 | 当前 DMA 请求正常完成的单周期脉冲。 |
| `error` | output | 1 | 错误状态。发生 AXI 响应异常、非法参数或协议检查失败后置 1，并保持到复位。 |

### 2.3 写入 `buffer_cluster` 的读回接口

该接口只在 `DMA_LOAD_Q`、`DMA_LOAD_K` 和 `DMA_LOAD_V` 请求中有效，用于把从外部内存读回的数据交付给 `buffer_cluster`。

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `buf_w_valid` | output | 1 | 写入 `buffer_cluster` 的数据有效。 |
| `buf_w_ready` | input | 1 | `buffer_cluster` 可以接收当前 beat。 |
| `buf_w_kind` | output | `BUF_KIND_WIDTH` | 当前 beat 的数据类别，由 `dma_op` 派生，取值为 `BUF_Q`、`BUF_K` 或 `BUF_V`。 |
| `buf_w_data` | output | `DMA_DATA_WIDTH` | 写入 `buffer_cluster` 的数据。 |
| `buf_w_last` | output | 1 | 当前 tile 的最后一个 beat。该信号是 tile-level last，不是 AXI burst-level last。 |

### 2.4 O 输出 buffer 读接口

该接口只在 `DMA_STORE_O` 请求中有效，用于从已经写好的 O 输出 buffer 读取数据。DMA 不直接连接计算通路的 O 输出流，也不判断 O tile 是否已经计算完成；该依赖关系由 `scheduler` 保证。

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `o_buf_r_en` | output | 1 | DMA 向 O 输出 buffer 发起一次读请求。 |
| `o_buf_r_addr` | output | `O_BUF_ADDR_WIDTH` | O 输出 buffer 的 beat 地址或 word index。baseline 中从 0 开始按 beat 递增。 |
| `o_buf_r_data` | input | `DMA_DATA_WIDTH` | 从 O 输出 buffer 读出的数据。 |
| `o_buf_r_valid` | input | 1 | `o_buf_r_data` 有效。对于固定读延迟 SRAM，可由 buffer 侧根据读延迟生成。 |

说明：如果实际实现中的 O buffer 与 Q/K/V buffer 统一在 `buffer_cluster` 内部，以上端口可以映射为 `buffer_cluster` 的 O buffer read port。若系统存在多 bank O buffer，bank 选择应由 `scheduler/buffer_cluster` 在 DMA 外部管理，或作为后续版本的扩展字段加入；baseline DMA 顶层不定义独立的 `o_bank_id`。

### 2.5 AXI Master 写接口

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `m_axi_awaddr` | output | `MEM_ADDR_WIDTH` | AXI 写地址。 |
| `m_axi_awlen` | output | 8 | AXI 写 burst 长度，表示 beat 数减 1。 |
| `m_axi_awsize` | output | 3 | AXI 写 beat 大小编码，baseline 固定为 `log2(DMA_DATA_WIDTH/8)`。 |
| `m_axi_awburst` | output | 2 | AXI 写 burst 类型，baseline 固定为 `INCR`。 |
| `m_axi_awvalid` | output | 1 | AXI 写地址有效。 |
| `m_axi_awready` | input | 1 | AXI 写地址就绪。 |
| `m_axi_wdata` | output | `DMA_DATA_WIDTH` | AXI 写数据。 |
| `m_axi_wstrb` | output | `DMA_DATA_WIDTH/8` | AXI 写字节使能。baseline 合法请求中所有 beat 均为全字节有效。 |
| `m_axi_wlast` | output | 1 | 当前 AXI 写 burst 的最后一个 beat。 |
| `m_axi_wvalid` | output | 1 | AXI 写数据有效。 |
| `m_axi_wready` | input | 1 | AXI 写数据就绪。 |
| `m_axi_bresp` | input | 2 | AXI 写响应。 |
| `m_axi_bvalid` | input | 1 | AXI 写响应有效。 |
| `m_axi_bready` | output | 1 | AXI 写响应就绪。 |

### 2.6 AXI Master 读接口

| 信号名 | 方向 | 位宽 | 说明 |
|---|---:|---:|---|
| `m_axi_araddr` | output | `MEM_ADDR_WIDTH` | AXI 读地址。 |
| `m_axi_arlen` | output | 8 | AXI 读 burst 长度，表示 beat 数减 1。 |
| `m_axi_arsize` | output | 3 | AXI 读 beat 大小编码，baseline 固定为 `log2(DMA_DATA_WIDTH/8)`。 |
| `m_axi_arburst` | output | 2 | AXI 读 burst 类型，baseline 固定为 `INCR`。 |
| `m_axi_arvalid` | output | 1 | AXI 读地址有效。 |
| `m_axi_arready` | input | 1 | AXI 读地址就绪。 |
| `m_axi_rdata` | input | `DMA_DATA_WIDTH` | AXI 读数据。 |
| `m_axi_rresp` | input | 2 | AXI 读响应。 |
| `m_axi_rlast` | input | 1 | 当前 AXI 读 burst 的最后一个 beat。 |
| `m_axi_rvalid` | input | 1 | AXI 读数据有效。 |
| `m_axi_rready` | output | 1 | AXI 读数据就绪。 |

## 3. 功能行为

### 3.1 DMA 请求模型

`fa_dma_engine` 的基本工作单位是一次 tile 级 DMA 请求。一次请求由以下输入描述：

```text
start + dma_op + dma_addr + dma_bytes
```

当 `start` 在空闲状态下为 1 时，模块接受请求，锁存 `dma_op`、`dma_addr` 和 `dma_bytes`，并开始执行。当前请求完成或出错前，锁存值保持不变。

`fa_dma_engine` 不决定 Q/K/V/O 的搬运顺序。典型系统中，`scheduler` 会按算法需要依次发起若干请求，例如：

```text
DMA_LOAD_Q  @ q_tile_addr
DMA_LOAD_K  @ k_tile_addr
DMA_LOAD_V  @ v_tile_addr
DMA_STORE_O @ o_tile_addr
```

对 DMA 而言，上述四次是四个独立请求。DMA 顶层接口不展开 `q_addr`、`k_addr`、`v_addr`、`o_addr`。

对于 `DMA_STORE_O`，`scheduler` 必须保证对应 O tile 已经由计算通路写入 O 输出 buffer，并且在 DMA 写回期间该 O buffer 内容保持稳定。

### 3.2 请求接受与状态语义

`start` 只在 `busy == 0` 且 `error == 0` 时被接受。

当请求被接受后：

- `busy` 置 1；
- `done` 保持为 0；
- DMA 根据锁存的 `dma_op` 选择外存读路径或 O buffer 写回路径；
- 新的 `start` 在 `busy == 1` 时被忽略。

当请求正常完成后：

- `busy` 清 0；
- `done` 拉高 1 个周期；
- `error` 保持为 0。

当请求失败后：

- `busy` 清 0；
- `done` 不产生；
- `error` 置 1 并保持到 `rst_n` 复位。

### 3.3 读请求语义

读类请求包括：

- `DMA_LOAD_Q`
- `DMA_LOAD_K`
- `DMA_LOAD_V`

读请求的目标是从 `dma_addr` 开始读取连续的 `dma_bytes` 字节，并通过 `buf_w_*` 接口交付给 `buffer_cluster`。

读请求行为如下：

- DMA 发起一个或多个 AXI 读 burst。
- AXI 读回的每个 beat 按顺序通过 `buf_w_data` 输出。
- `buf_w_kind` 由 `dma_op` 决定：`LOAD_Q` 输出 `BUF_Q`，`LOAD_K` 输出 `BUF_K`，`LOAD_V` 输出 `BUF_V`。
- 只有 `buf_w_valid && buf_w_ready` 为 1 时，该 beat 才算成功交付。
- `buf_w_last` 只在当前 tile 的最后一个成功交付 beat 上拉高。

读请求的 `done` 条件是：

> 当前请求的最后一个读回 beat 已经成功通过 `buf_w_*` 交付给 `buffer_cluster`，并且所有相关 AXI 读响应均为 `OKAY`。

因此，读请求的 `done` 不得早于数据进入 `buffer_cluster`。

### 3.4 写请求语义

写类请求只有：

- `DMA_STORE_O`

写请求的目标是从 O 输出 buffer 读取连续的 `dma_bytes` 字节，并从 `dma_addr` 开始写回外部内存。

写请求行为如下：

- `DMA_STORE_O` 被接受时，DMA 认为目标 O tile 已经完整存放在 O 输出 buffer 中。
- DMA 通过 `o_buf_r_en/o_buf_r_addr` 按 beat 顺序读取 O buffer。
- `o_buf_r_addr` 从当前 tile 的起始 beat index 开始，baseline 中为 0，并随成功读取的 beat 递增。
- 当 `o_buf_r_valid == 1` 时，`o_buf_r_data` 被 DMA 接收，并按顺序写入 AXI 写通道。
- DMA 必须根据 AXI 写通道背压控制 O buffer 读请求节奏，不能因为 `m_axi_wready` 低而丢失已读出的 O 数据。
- 写请求的 tile 结束位置由 `dma_bytes` 和内部 beat 计数确定，不依赖外部 `last` 信号。

写请求的 `done` 条件是：

> 当前请求对应的全部 O buffer beat 均已被 DMA 读取，并且所有 AXI 写事务均收到 `OKAY` 写响应。

因此，写请求的 `done` 不得早于外部内存写提交完成。

### 3.5 AXI burst 行为

`fa_dma_engine` 对上游保持 tile 级请求抽象，对 AXI 总线使用 burst 事务完成传输。

baseline AXI 行为如下：

- 只使用 `INCR` burst。
- `ARSIZE/AWSIZE` 固定对应 `DMA_DATA_WIDTH/8` 字节。
- 单个 burst 最大长度不超过 256 beat。
- 当 `dma_bytes` 超过单个 burst 能力时，DMA 内部自动拆分为多个连续 burst。
- 如果请求跨越 AXI 4KB 边界，DMA 必须在 4KB 边界处拆分 burst，不发起跨 4KB 边界的单个 burst。
- burst 拆分对 `scheduler`、`addr_gen`、`buffer_cluster` 和计算通路均不可见。
- `m_axi_rlast/m_axi_wlast` 表示 AXI burst 的最后一个 beat；`buf_w_last` 表示读入 tile 请求的最后一个 beat；`DMA_STORE_O` 的 tile 结束由 `dma_bytes` 计数确定。

baseline 只支持 full-beat 对齐传输：

```text
dma_addr 按 DMA_DATA_WIDTH/8 字节对齐
dma_bytes > 0
dma_bytes 是 DMA_DATA_WIDTH/8 的整数倍
```

如果请求参数不满足上述约束，模块应进入错误状态，不应发起部分有效 beat 的 AXI 访问。

### 3.6 背压与数据保持

`buf_w_*` 采用标准 `valid/ready` 握手语义。O buffer 读接口采用请求/有效返回语义。

对读请求：

- 当 `buf_w_valid == 1` 且 `buf_w_ready == 0` 时，DMA 必须保持当前 `buf_w_data`、`buf_w_kind` 和 `buf_w_last` 不变，直到握手成功。
- DMA 可以通过拉低 `m_axi_rready` 或使用内部缓冲处理 `buffer_cluster` 的背压。

对写请求：

- DMA 只能在自身有能力保存返回数据时发起 `o_buf_r_en`。
- 一旦 `o_buf_r_valid == 1`，对应 `o_buf_r_data` 必须被 DMA 保留，并最终写入 AXI 写通道。
- 当 AXI 写通道背压较强时，DMA 应暂停继续读取 O buffer，或使用内部缓冲吸收已读出的数据。

DMA 必须保证背压不会导致数据丢失、重复或乱序。

### 3.7 错误与复位语义

`error` 是保持型状态。以下情况会使 `error` 置 1：

- 任意 AXI 读 beat 的 `RRESP` 不是 `OKAY`；
- 任意 AXI 写响应 `BRESP` 不是 `OKAY`；
- AXI 读 burst 的 `RLAST` 与内部 beat 计数不一致；
- O buffer 返回数据数量与 `dma_bytes` 推导出的 beat 数不一致；
- `dma_op` 编码非法；
- `dma_addr` 或 `dma_bytes` 不满足 baseline 对齐约束。

发生错误后，当前请求失败，`busy` 清 0，`done` 不应产生。`error` 保持为 1，直到 `rst_n` 被拉低复位。

当 `rst_n` 被拉低时：

- 当前 DMA 请求被丢弃；
- 锁存的 `dma_op/dma_addr/dma_bytes` 被清空；
- 内部 burst/beat 计数器被清空；
- 读写执行状态回到空闲；
- `busy = 0`；
- `done = 0`；
- `error = 0`；
- `buf_w_valid = 0`；
- `o_buf_r_en = 0`；
- 所有 AXI `valid` 输出为 0。

## 4. 操作编码与参数

### 4.1 `dma_op` 编码

`dma_op[1:0]` 编码如下。

| 编码 | 名称 | 类型 | 说明 |
|---|---|---|---|
| `2'b00` | `DMA_LOAD_Q` | read | 从 `dma_addr` 读取 Q tile，并以 `BUF_Q` 写入 `buffer_cluster`。 |
| `2'b01` | `DMA_LOAD_K` | read | 从 `dma_addr` 读取 K tile，并以 `BUF_K` 写入 `buffer_cluster`。 |
| `2'b10` | `DMA_LOAD_V` | read | 从 `dma_addr` 读取 V tile，并以 `BUF_V` 写入 `buffer_cluster`。 |
| `2'b11` | `DMA_STORE_O` | write | 从 O 输出 buffer 读取 O tile，并写回 `dma_addr`。 |

### 4.2 参数

| 参数名 | 说明 |
|---|---|
| `MEM_ADDR_WIDTH` | 外部内存地址宽度。 |
| `DMA_DATA_WIDTH` | AXI 数据宽度，同时也是 `buf_w_data` 和 `o_buf_r_data` 的宽度。 |
| `DMA_BYTES_WIDTH` | `dma_bytes` 的位宽。 |
| `BUF_KIND_WIDTH` | `buf_w_kind` 的位宽。 |
| `O_BUF_ADDR_WIDTH` | O 输出 buffer 读地址宽度。 |
| `MAX_BURST_BEATS` | 单个 AXI burst 的最大 beat 数，baseline 不超过 256。 |

### 4.3 布局约束

baseline 中，一个 DMA 请求只描述一段连续外部内存区域：

```text
[dma_addr, dma_addr + dma_bytes)
```

因此 baseline 不支持以下访问模式：

- 带 padding 的二维 tile 逐行跨 stride 搬运；
- 每行单独 micro-burst 的跳 stride 访问；
- 非连续 scatter/gather 访问；
- byte-level partial beat 搬运。

如果系统需要支持带 stride 的 tile，应该由上游 `addr_gen/scheduler` 拆成多个连续 DMA 请求，或者在后续版本中扩展 DMA 请求接口。

## 5. 接口字段补充说明

### 5.1 `start`、`busy` 与 `done`

`start` 是请求发起脉冲，不是保持型配置位。DMA 只在空闲且无错误状态下接受 `start`。

`busy` 是当前请求执行中的状态信号。`busy == 1` 时，上游不应修改当前请求相关输入并再次发起 `start`。

`done` 是单周期完成脉冲。若系统需要软件可轮询的保持型完成状态，应由 DMA 外部状态逻辑锁存 `done`，并通过 CSR 清除。

### 5.2 `dma_addr` 与 `dma_op`

`dma_addr` 是当前请求的外存起始地址。DMA 不根据地址判断其属于 Q/K/V/O。

Q/K/V/O 的语义由 `dma_op` 表达：

- 对 `DMA_LOAD_Q/K/V`，`dma_addr` 是输入 tile 的读取地址；
- 对 `DMA_STORE_O`，`dma_addr` 是输出 tile 的写回地址。

### 5.3 `buf_w_kind`

`buf_w_kind` 只在读类请求中有效。它由 `dma_op` 派生，用于告诉 `buffer_cluster` 当前读回数据应写入 Q、K 还是 V 相关 buffer。

在 `DMA_STORE_O` 请求中，`buf_w_valid` 必须为 0，`buf_w_kind` 无意义。

### 5.4 O 输出 buffer 读接口

O tile 的产生和存储不属于 `fa_dma_engine` 的职责。计算通路应先把完整 O tile 写入 O 输出 buffer；当该 tile 可写回时，计算通路或 buffer 控制逻辑通知 `scheduler`，再由 `scheduler` 发起 `DMA_STORE_O`。

`DMA_STORE_O` 执行期间，DMA 通过 `o_buf_r_en/o_buf_r_addr` 主动读取 O buffer。O buffer 侧通过 `o_buf_r_valid/o_buf_r_data` 返回数据。DMA 不接收 `o_stream_valid/o_stream_ready/o_stream_last` 形式的计算输出流。

### 5.5 `last` 信号

`buf_w_last` 表示当前读入 tile 请求的最后一个交付给 `buffer_cluster` 的数据 beat。

AXI 的 `m_axi_rlast/m_axi_wlast` 表示当前 AXI burst 的最后一个 beat。一个 tile 请求可能拆分为多个 AXI burst，因此 tile-level last 与 burst-level last 不能混用。

`DMA_STORE_O` 不依赖外部 `last` 输入。写回 tile 的最后一个 beat 由 `dma_bytes` 和内部计数器确定。

## 6. 系统集成模型

典型执行流程如下：

1. 上游 CSR/地址生成逻辑根据软件配置得到 Q/K/V/O 的 tile 地址。
2. `scheduler` 在 DMA 空闲时发起 `DMA_LOAD_Q` 请求，传入当前 Q tile 的 `dma_addr` 和 `dma_bytes`。
3. DMA 从外存读取 Q tile，并以 `BUF_Q` 写入 `buffer_cluster`，完成后产生 `done`。
4. `scheduler` 继续发起 `DMA_LOAD_K` 和 `DMA_LOAD_V` 请求。
5. 计算通路使用 `buffer_cluster` 中的 Q/K/V 数据完成计算，并将最终 O tile 写入 O 输出 buffer。
6. O tile 写入完成后，计算通路或 O buffer 控制逻辑通知 `scheduler`。
7. `scheduler` 在确认 O tile 已经可写回后，发起 `DMA_STORE_O` 请求，传入 O tile 的外存写回地址和字节数。
8. DMA 从 O 输出 buffer 读取 O tile，并通过 AXI 写回外存，写响应正常返回后产生 `done`。

`fa_dma_engine` 只保证单个请求内的数据搬运正确性和 AXI 协议适配。多次请求之间的顺序、依赖关系、buffer bank 选择、O tile 可写回判断和 tile 调度策略由 `scheduler` 及其上游控制逻辑负责。
