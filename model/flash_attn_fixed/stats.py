from __future__ import annotations

import math
from dataclasses import dataclass

from .fixed_format import FixedFormat
from .fixed_ops import dequantize_fixed_to_float
from .hardware_config import FlashAttentionHardwareConfig


@dataclass(frozen=True)
class ErrorMetrics:
    """Error summary between an FP32 reference and fixed-point raw output."""

    mean_abs_error: float
    max_abs_error: float
    rmse: float

    def to_dict(self) -> dict[str, float]:
        """Serialize metrics for JSON debug logs."""

        return {
            "mean_abs_error": self.mean_abs_error,
            "max_abs_error": self.max_abs_error,
            "rmse": self.rmse,
        }


def compute_error_metrics(
    ref_float: list[list[float]],
    test_raw: list[list[int]],
    out_fmt: FixedFormat,
) -> ErrorMetrics:
    """Compute MAE, max absolute error, and RMSE."""

    if len(ref_float) != len(test_raw):
        raise ValueError("row count mismatch")
    total_abs = 0.0
    total_sq = 0.0
    max_abs = 0.0
    count = 0
    for row_idx, (ref_row, test_row) in enumerate(zip(ref_float, test_raw)):
        if len(ref_row) != len(test_row):
            raise ValueError(f"column count mismatch on row {row_idx}")
        for ref, raw in zip(ref_row, test_row):
            test = dequantize_fixed_to_float(raw, out_fmt)
            err = abs(float(ref) - test)
            total_abs += err
            total_sq += err * err
            max_abs = max(max_abs, err)
            count += 1
    if count == 0:
        raise ValueError("empty matrices cannot be compared")
    return ErrorMetrics(
        mean_abs_error=total_abs / count,
        max_abs_error=max_abs,
        rmse=math.sqrt(total_sq / count),
    )


def _bits_to_bytes(bits: int) -> int:
    return (bits + 7) // 8


def _matrix_bytes(rows: int, cols: int, fmt: FixedFormat) -> int:
    return _bits_to_bytes(rows * cols * fmt.total_bits)


def print_format_summary(cfg: FlashAttentionHardwareConfig) -> None:
    """Print the default format used by each major datapath variable."""

    print("Fixed-point format summary")
    rows = [
        ("Q", cfg.q_fmt),
        ("K", cfg.k_fmt),
        ("V", cfg.v_fmt),
        ("O", cfg.out_fmt),
        ("Q*K product", cfg.prod_qk_fmt),
        ("S", cfg.s_fmt),
        ("score/local_m/new_m", cfg.score_fmt),
        ("log2e", cfg.log2e_fmt),
        ("exp/P/b", cfg.exp_fmt),
        ("local_l", cfg.locall_fmt),
        ("old_l/new_l", cfg.l_fmt),
        ("local_o", cfg.localo_fmt),
        ("old_o/new_o", cfg.oacc_fmt),
    ]
    for name, fmt in rows:
        print(f"  {name:18s}: {fmt.label()} ({fmt.total_bits} bits, frac={fmt.frac_bits})")


def print_memory_summary(cfg: FlashAttentionHardwareConfig) -> None:
    """Print key memory footprints for baseline and tiled datapaths."""

    n = cfg.len_seq
    d = cfg.head_dim
    print("Memory summary")
    print(f"  Q matrix bytes              : {_matrix_bytes(n, d, cfg.q_fmt)}")
    print(f"  K matrix bytes              : {_matrix_bytes(n, d, cfg.k_fmt)}")
    print(f"  V matrix bytes              : {_matrix_bytes(n, d, cfg.v_fmt)}")
    print(f"  O matrix bytes              : {_matrix_bytes(n, d, cfg.out_fmt)}")
    print(f"  S tile bytes                : {_matrix_bytes(cfg.Br, cfg.Bc, cfg.s_fmt)}")
    print(f"  P tile bytes                : {_matrix_bytes(cfg.Br, cfg.Bc, cfg.exp_fmt)}")
    print(f"  old_m storage bytes         : {_matrix_bytes(cfg.Br, 1, cfg.m_fmt)}")
    print(f"  old_l storage bytes         : {_matrix_bytes(cfg.Br, 1, cfg.l_fmt)}")
    print(f"  old_o storage bytes         : {_matrix_bytes(cfg.Br, d, cfg.oacc_fmt)}")
    print(f"  full attention matrix bytes : {_matrix_bytes(n, n, cfg.exp_fmt)}")
    print(f"  tile score matrix bytes     : {_matrix_bytes(cfg.Br, cfg.Bc, cfg.score_fmt)}")
