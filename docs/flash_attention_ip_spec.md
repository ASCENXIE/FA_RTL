# Spec: Flash Attention SDPA Accelerator IP

## Objective

Build a single-head Flash Attention accelerator IP that computes:

`O = softmax((Q * K^T) / sqrt(d) + mask) * V`

with fixed problem size `S = 256`, `d = 64`, and matrix shapes:

- `Q[256][64]`
- `K[256][64]`
- `V[256][64]`
- `O[256][64]`

The accelerator shall expose:

- an `AXI4-Lite` control/status interface for configuration and run control
- an `AXI4 Master` data interface used by a DMA engine to fetch `Q/K/V` and store `O`

The IP microarchitecture is split into:

- compute array
- address generation
- task scheduler

## Assumptions

These assumptions are applied in the first implementation pass.

1. The IP targets a single attention head only.
2. `Q`, `K`, `V`, and `O` are stored in row-major order.
3. The element format for `Q/K/V/O` is signed `Q8.8` packed in 16-bit words.
4. The host provides 64-bit physical base addresses for `Q/K/V/O`.
5. The master data path is `128-bit AXI4`, so each beat carries `8` Q8.8 elements.
6. `row_stride` is expressed in bytes and means the distance between the starts of two adjacent rows.
7. Default contiguous stride is `64 * 2 = 128 bytes`.
8. `causal_mask` is optional and controlled by a register bit.
9. The initial RTL drop focuses on a compilable control-plane skeleton plus a documented datapath contract. The cycle model is included, while the arithmetic datapath will be filled in incrementally.

## Tech Stack

- SystemVerilog RTL
- AXI4-Lite control slave
- AXI4 master DMA shell
- Icarus Verilog (`iverilog -g2012`) for syntax and smoke simulation
- Python 3.10 reference model for SDPA verification

## Commands

- RTL compile: `iverilog -g2012 -s tb_fa_axilite_smoke -o out/tb_fa_axilite_smoke.vvp RTL/TOP.v RTL/src/*.sv tb/tb_fa_axilite_smoke.sv`
- RTL run: `vvp out/tb_fa_axilite_smoke.vvp`
- Python reference tests: `python tb/run_reference_tests.py`

## Project Structure

- `RTL/TOP.v`: integration wrapper used as the user-facing top module
- `RTL/include/fa_pkg.sv`: shared parameters, register map, constants
- `RTL/src/fa_axi_lite_regs.sv`: AXI4-Lite register block
- `RTL/src/fa_scheduler.sv`: tile-level execution control
- `RTL/src/fa_addr_gen.sv`: tile address generation
- `RTL/src/fa_dma_engine_stub.sv`: AXI4 master shell and timing-model DMA
- `RTL/src/fa_compute_core.sv`: datapath shell and timing-model compute engine
- `RTL/src/fa_top.sv`: top-level integration
- `tb/tb_fa_axilite_smoke.sv`: AXI4-Lite start/done smoke test
- `tb/fa_reference.py`: numerical SDPA golden model and vector dump helpers
- `tb/run_reference_tests.py`: random and causal-mask verification driver
- `docs/flash_attention_ip_spec.md`: this specification

## Architecture

### Dataflow

The baseline microarchitecture uses tiled Flash Attention:

- query tile size `Br = 16`
- key/value tile size `Bc = 16`
- feature depth chunk `Dv = 64`

For each query tile:

1. DMA loads one `Q` tile into local SRAM.
2. For every `K/V` tile:
   - DMA loads `K` and `V` tiles.
   - compute array evaluates `Q_tile * K_tile^T`.
   - online softmax state is updated per query row:
     - running max `m_i`
     - running normalization factor `l_i`
     - running output accumulator `acc_i[d]`
3. DMA writes one `O` tile back to memory.

### Module Responsibilities

#### Compute Array

- Contract-first shell in the initial RTL drop.
- Target architecture: `16 x 16` score tile engine with `64`-deep dot-product reduction.
- Recommended internal accumulator width:
  - multiply result: `32 bits`
  - dot-product accumulator: `40 bits`
  - output accumulation: `40+ bits`

#### Address Generation

- Converts base address, row stride, tile index, and element width into addresses.
- Supports padded pitches through byte-based stride registers.
- Generates:
  - `Q` tile base address
  - `K` tile base address
  - `V` tile base address
  - `O` tile base address

#### Task Scheduler

- Sequences tile execution.
- Skips masked future tiles when `causal_mask` is enabled.
- Drives DMA requests and compute launches.
- Tracks performance counters and tile progress.

### Register Map

All registers are 32-bit and aligned on 4-byte boundaries. The table below is the mandatory baseline register set. Optional debug or tuning registers may be added later without changing these definitions.

| Address | Name | Access | Description |
|---|---|---|---|
| `0x00` | `CTRL` | RW | `bit0 START` (write `1` to launch), `bit1 SOFT_RESET`, `bit2 IRQ_EN` |
| `0x04` | `STATUS` | RO/W1C | `bit0 BUSY`, `bit1 DONE` (write `1` to clear), `bit2 ERROR` |
| `0x08` | `CFG` | RW | `bit0 CAUSAL_EN`, other bits reserved |
| `0x14` | `Q_BASE_L` | RW | lower 32 bits of Q base address |
| `0x18` | `Q_BASE_H` | RW | upper 32 bits of Q base address |
| `0x1C` | `K_BASE_L` | RW | lower 32 bits of K base address |
| `0x20` | `K_BASE_H` | RW | upper 32 bits of K base address |
| `0x24` | `V_BASE_L` | RW | lower 32 bits of V base address |
| `0x28` | `V_BASE_H` | RW | upper 32 bits of V base address |
| `0x2C` | `O_BASE_L` | RW | lower 32 bits of O base address |
| `0x30` | `O_BASE_H` | RW | upper 32 bits of O base address |
| `0x34` | `STRIDE_BYTES` | RW | row stride in bytes, default `d * 2 = 128` |
| `0x38` | `NEG_LARGE` | RW | `-inf` approximation used by masking, stored in fixed-point register format |
| `0x3C` | `SCALE` | RW | `1 / sqrt(d)` scaling constant used before softmax |
| `0x40` | `CYCLES` | RO | cycle count for the current or most recent attention run |

### Row Stride Semantics

`stride_bytes` is the byte offset from the first byte of row `i` to the first byte of row `i+1`.

Examples:

- contiguous `Q[256][64]` in Q8.8: `stride_bytes = 64 * 2 = 128`
- row-padded storage with 16 bytes padding: `stride_bytes = 144`
- submatrix view in a wider parent tensor: stride equals parent row pitch

For the baseline, the same stride register is applied to `Q/K/V/O`, because all four tensors share the same fixed `256 x 64` row-major layout. This register exists so the accelerator can operate on packed or padded layouts without host-side repacking.

## Performance Model

The intended architecture uses:

- `Br = 16`
- `Bc = 16`
- score array size `16 x 16`
- `128-bit` AXI master

At `S = 256`, `d = 64`:

- number of query tiles = `16`
- number of key/value tiles per query tile = `16`
- total score tiles = `256`

Rough cycle budget for the target datapath:

- score tile MAC phase: about `64 cycles`
- online softmax/update phase: about `24 cycles`
- output accumulation phase: about `64 cycles`
- per-tile control overhead: about `8 cycles`

Estimated compute cycles:

`256 * (64 + 24 + 64 + 8) = 40,960 cycles`

Rough DMA budget with one beat per cycle:

- total traffic: `Q + K + V + O`
- expected DMA cycles: `60k - 90k cycles` depending on burst packing and stride usage

Expected total: below `300k cycles` with overlap margin still available for implementation detail.

### Gate Count Direction

The target `16 x 16` score array is expected to stay within the `2M gate` envelope if:

- local SRAMs map to memory macros or FPGA block RAMs
- exp/inv units use LUT or piecewise approximation rather than full floating-point
- control and DMA logic remain scalar and shared

This spec does not claim gate closure yet. Final synthesis data is required.

## Code Style

SystemVerilog style guideline for this project:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= IDLE;
  end else begin
    state <= state_n;
  end
end

always_comb begin
  state_n = state;
  unique case (state)
    IDLE: if (start) state_n = RUN;
    RUN:  if (done)  state_n = IDLE;
    default: state_n = IDLE;
  endcase
end
```

Conventions:

- use `snake_case` for signals and registers
- use `UPPER_CASE` for parameters and states
- keep one clear responsibility per module
- prefer explicit widths for all arithmetic and counters

## Testing Strategy

### RTL Smoke

- verify AXI4-Lite register write/read flow
- verify `START -> BUSY -> DONE` control path
- verify `CAUSAL_EN` changes scheduler behavior at the tile-control level

### Numerical Reference

- generate random `Q/K/V` tensors in signed Q8.8
- compare fixed-point IO path against floating-point golden SDPA
- acceptance:
  - `mean_abs_error(O) <= 0.03`
  - `max_abs_error(O) <= 0.10`

### Corner Cases

- causal mask enabled
- stride set to contiguous and padded values
- diagonal tile and strictly masked future tile behavior

## Boundaries

- Always:
  - keep the RTL synthesizable unless a file is explicitly marked as a simulation helper
  - keep control-plane logic compiling with `iverilog -g2012`
  - document all numerical-format assumptions
- Ask first:
  - changes to tile sizes that affect software-visible register semantics
  - adding floating-point units
  - widening AXI bus interfaces beyond the baseline
- Never:
  - silently change Q/K/V/O memory layout
  - hardcode host physical addresses
  - remove verification checks just to make smoke tests pass

## Success Criteria

1. AXI4-Lite register programming and start/done flow work in simulation.
2. The repository contains a documented and compilable RTL architecture split into:
   - compute array
   - address generation
   - task scheduler
3. The Python golden model can generate random vectors and causal-mask cases and check the requested error bounds.
4. The architecture and timing model clearly support a path to `< 300k cycles`.

## Open Questions

1. Should the production AXI4 master support only contiguous bursts, or also row-by-row microbursts for non-contiguous stride?
2. Should `seq_len` remain fixed at `256` in hardware, or should shorter effective lengths be supported via `CFG0.seq_len`?
3. Does the final IP need an interrupt output, or is register polling sufficient?
4. Is the intended implementation target FPGA, ASIC, or both?
