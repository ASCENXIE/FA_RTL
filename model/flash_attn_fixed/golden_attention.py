from __future__ import annotations

import math

from .fixed_format import FixedFormat
from .fixed_ops import dequantize_fixed_to_float
from .hardware_config import FlashAttentionHardwareConfig


def _check_matrix(name: str, matrix: list[list[int]], rows: int, cols: int) -> None:
    if len(matrix) != rows:
        raise ValueError(f"{name} must have {rows} rows")
    for row_idx, row in enumerate(matrix):
        if len(row) != cols:
            raise ValueError(f"{name}[{row_idx}] must have {cols} columns")


def _check_range(name: str, matrix: list[list[int]], fmt: FixedFormat) -> None:
    for row_idx, row in enumerate(matrix):
        for col_idx, value in enumerate(row):
            if value < fmt.min_int or value > fmt.max_int:
                raise ValueError(
                    f"{name}[{row_idx}][{col_idx}]={value} outside {fmt.name}"
                )


def golden_attention_fp32(
    q_raw: list[list[int]],
    k_raw: list[list[int]],
    v_raw: list[list[int]],
    *,
    cfg: FlashAttentionHardwareConfig,
) -> list[list[float]]:
    """Compute formula-level FP32 attention from raw fixed-point Q/K/V inputs."""

    n = cfg.len_seq
    d = cfg.head_dim
    _check_matrix("q_raw", q_raw, n, d)
    _check_matrix("k_raw", k_raw, n, d)
    _check_matrix("v_raw", v_raw, n, d)
    _check_range("q_raw", q_raw, cfg.q_fmt)
    _check_range("k_raw", k_raw, cfg.k_fmt)
    _check_range("v_raw", v_raw, cfg.v_fmt)

    q = [[dequantize_fixed_to_float(x, cfg.q_fmt) for x in row] for row in q_raw]
    k = [[dequantize_fixed_to_float(x, cfg.k_fmt) for x in row] for row in k_raw]
    v = [[dequantize_fixed_to_float(x, cfg.v_fmt) for x in row] for row in v_raw]

    inv_sqrt_d = 1.0 / math.sqrt(float(d))
    out: list[list[float]] = []
    for i in range(n):
        scores: list[float] = []
        for j in range(n):
            if cfg.causal and j > i:
                scores.append(float("-inf"))
                continue
            dot = 0.0
            for t in range(d):
                dot += q[i][t] * k[j][t]
            scores.append(dot * inv_sqrt_d)

        row_max = max(scores)
        exp_scores = [0.0 if s == float("-inf") else math.exp(s - row_max) for s in scores]
        row_sum = sum(exp_scores)
        probs = [x / row_sum for x in exp_scores]

        out_row: list[float] = []
        for dim in range(d):
            acc = 0.0
            for j in range(n):
                acc += probs[j] * v[j][dim]
            out_row.append(acc)
        out.append(out_row)
    return out
