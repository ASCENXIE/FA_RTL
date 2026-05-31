# Flash Attention Accelerator Architecture

## Status

This document records the current accepted architecture for the Flash Attention IP. The design has been converged to a `16x16` single-core architecture because project priority is implementation simplicity and stable end-to-end realization before aggressive micro-architectural optimization.

## Design Targets

- Workload: single-head SDPA
- Fixed baseline:
  - `S = 256`
  - `d = 64`
  - `Q/K/V/O` shape = `[256, 64]`
- Data format:
  - `Q/K/V/O`: signed `Q8.8`
  - dot-product accumulator: `>= 40 bits`
- External interfaces:
  - `AXI4-Lite` control slave
  - `AXI4` master for DMA
- Key constraints:
  - total equivalent gate count `< 2M GE`
  - single attention latency `< 300k cycles`

## Chosen Top-Level Architecture

The current design uses one shared `16x16` matrix core and one VPU:

```text
AXI4-Lite -> fa_axi_lite_regs -> fa_scheduler
                               -> fa_addr_gen

DDR/AXI4 <-> fa_dma_engine <-> fa_buffer_cluster
                                  |    |    |
                                  |    |    +--> v_stream ---+
                                  |    +------> k_stream ---+|
                                  +-----------> q_stream --+||
                                                          fa_compute_core
                                                               |      |
                                                    score_stream      pv_stream
                                                               |      |
                                                               +--> fa_vpu --> o_stream --> fa_dma_engine
                                                                     |
                                                                     +--> p_stream --> fa_compute_core
```

`TOP.v` is the final user-visible IP top and only instantiates the required modules plus their interconnect.

## Why This Architecture

The project is a competition implementation task where realization priority is higher than architectural aggressiveness.

Reasons for selecting the single shared `16x16` core:

- fewer moving parts than a multi-stage dual-array pipeline
- smaller scheduler/control risk
- lower verification burden
- lower external memory traffic than an `8x8`-tile dual-core streaming scheme
- still provides a clear path to the cycle target

The design intentionally keeps later optimization room, but the baseline architecture favors simplicity first.

## Top Module Boundary

`TOP.v` exposes:

- `clk`
- `rst_n`
- `irq`
- one `AXI4-Lite` slave interface
- one `AXI4` master interface

Interface choices:

- `AXI4-Lite`: `32-bit` address, `32-bit` data
- `AXI4` master: `64-bit` address, `128-bit` data
- control plane: `start / done / busy / error`
- data plane: `valid / ready`

## Instantiated Modules

`TOP.v` currently instantiates exactly these modules:

- `fa_axi_lite_regs`
- `fa_scheduler`
- `fa_addr_gen`
- `fa_dma_engine`
- `fa_buffer_cluster`
- `fa_compute_core`
- `fa_vpu`

## Module Responsibilities

### `fa_axi_lite_regs`

Responsibilities:

- host-visible control and status registers
- decode `START`
- expose `SOFT_RESET`, `IRQ_EN`, `CAUSAL_EN`
- expose DMA base addresses and numerical constants
- report `BUSY`, `DONE`, `ERROR`, and `CYCLES`

Notes:

- `DONE` is treated as write-one-to-clear
- `seq_len` and `head_dim` are fixed internally for the baseline and are not currently software-programmable

### `fa_scheduler`

Responsibilities:

- the only top-level execution master
- sequences tile-level operations
- drives:
  - address generation
  - DMA reads and writes
  - buffer fill operations
  - shared compute-core launches
  - VPU launches
- tracks performance counters and tile progress

Current implementation intent:

- tile-level control only
- no row-level or beat-level control in the scheduler
- baseline schedule favors correctness and simplicity over aggressive overlap

### `fa_addr_gen`

Responsibilities:

- compute memory addresses for `Q/K/V/O`
- use `64-bit` base addresses
- apply `stride_bytes`
- convert tile index and transfer kind into DMA address and byte count

It stays separate from DMA so that layout policy and transfer execution remain decoupled.

### `fa_dma_engine`

Responsibilities:

- single DMA block for both read and write traffic
- read `Q/K/V` from external memory
- send read payloads into `fa_buffer_cluster`
- receive final `O` as a stream from `fa_vpu`
- write `O` back to external memory

The top level exposes only one AXI master port. Internal read/write arbitration stays inside DMA.

### `fa_buffer_cluster`

Responsibilities:

- hold tile-local `Q/K/V` data only
- accept DMA writes for `Q/K/V`
- provide streaming access for the compute core:
  - `q_stream`
  - `k_stream`
  - `v_stream`

Important boundary:

- `fa_buffer_cluster` does not own `m`, `l`, `Oacc`, or final `O`
- it is a storage and streaming-adaptation block, not a global controller

### `fa_compute_core`

Responsibilities:

- one shared `16x16` systolic matmul core
- time-multiplexed between two operations:
  - `QK`: `Q_tile * K_tile^T`
  - `PV`: `P_tile * V_tile`
- consume:
  - `q_stream`
  - `k_stream`
  - `v_stream`
  - `p_stream`
- produce:
  - `score_stream`
  - `pv_stream`

Important boundary:

- one physical compute engine only
- operation selected by `core_mode`
- no softmax logic inside the compute core

### `fa_vpu`

Responsibilities:

- vector-domain processing around the shared compute core
- consume `score_stream`
- apply:
  - scale
  - causal mask
  - row max
  - exponent approximation
  - row sum / reciprocal support
- produce:
  - `p_stream` for the shared compute core in `PV` mode
- consume `pv_stream`
- maintain internal runtime state:
  - `m`
  - `l`
  - `Oacc`
- perform final normalize
- emit final `O` through `o_stream`

Important boundary:

- `fa_vpu` owns private numerical state that does not need external visibility
- final `O` is streamed directly to DMA, not written back into `fa_buffer_cluster`

## Dataflow

The baseline execution flow for one attention run is:

1. Host programs registers and asserts `START`.
2. `fa_scheduler` loads one `Q` tile into `fa_buffer_cluster`.
3. `fa_scheduler` issues `VPU_INIT` for the current `Q` tile.
4. For each `K/V` tile:
   - `fa_scheduler` loads `K`
   - `fa_scheduler` loads `V`
   - `fa_scheduler` launches `fa_compute_core` in `QK` mode
   - `fa_vpu` consumes `score_stream` and emits `p_stream`
   - `fa_scheduler` launches `fa_compute_core` in `PV` mode
   - `fa_vpu` consumes `pv_stream` and updates `m/l/Oacc`
5. After all `K/V` tiles finish, `fa_scheduler` launches `VPU_FINAL`.
6. `fa_vpu` streams final `O` into `fa_dma_engine`.
7. `fa_dma_engine` writes `O` back to memory.
8. `fa_scheduler` advances to the next `Q` tile or finishes the run.

## Control-Plane Rules

The top-level control style is intentionally simple:

- coarse-grain module control:
  - `start`
  - `busy`
  - `done`
  - `error`
- streaming payload links:
  - `valid`
  - `ready`
  - `data`
  - `last`

This keeps `TOP.v` readable and lowers implementation risk.

## Register Set

The mandatory baseline registers are:

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x00` | `CTRL` | RW | `START`, `SOFT_RESET`, `IRQ_EN` |
| `0x04` | `STATUS` | RO/W1C | `BUSY`, `DONE`, `ERROR` |
| `0x08` | `CFG` | RW | `CAUSAL_EN` |
| `0x14` | `Q_BASE_L` | RW | Q base low 32 bits |
| `0x18` | `Q_BASE_H` | RW | Q base high 32 bits |
| `0x1C` | `K_BASE_L` | RW | K base low 32 bits |
| `0x20` | `K_BASE_H` | RW | K base high 32 bits |
| `0x24` | `V_BASE_L` | RW | V base low 32 bits |
| `0x28` | `V_BASE_H` | RW | V base high 32 bits |
| `0x2C` | `O_BASE_L` | RW | O base low 32 bits |
| `0x30` | `O_BASE_H` | RW | O base high 32 bits |
| `0x34` | `STRIDE_BYTES` | RW | row stride in bytes |
| `0x38` | `NEG_LARGE` | RW | mask fill value approximation |
| `0x3C` | `SCALE` | RW | `1 / sqrt(d)` |
| `0x40` | `CYCLES` | RO | cycle counter for the current or last run |

## Current Fixed Baseline Assumptions

The current top-level snapshot assumes:

- `seq_len = 256`
- `head_dim = 64`
- `tile_br = 16`
- `tile_bc = 16`
- `Q/K/V/O` all use the same `stride_bytes`
- row-major storage
- no full `K/V` cache
- `m/l/Oacc` are internal to `fa_vpu`
- final `O` is streamed from `fa_vpu` directly to `fa_dma_engine`

## Items Deliberately Left Open

The following are still implementation choices below the top-level boundary:

- exact buffer banking inside `fa_buffer_cluster`
- exact burst packaging in DMA
- exp / reciprocal approximation method inside `fa_vpu`
- whether later revisions overlap `K/V` prefetch with compute
- whether the physical `16x16` core is internally composed of four `8x8` PE clusters

## Summary

The current architecture is a competition-oriented `16x16` single-core Flash Attention design:

- one shared `16x16` compute core
- one VPU for softmax, accumulation, and finalization
- one scheduler as the only global controller
- one DMA engine for all external memory traffic
- tile-local `Q/K/V` buffering only
- private `m/l/Oacc` state inside `fa_vpu`

This is the architecture that `TOP.v` now reflects.
