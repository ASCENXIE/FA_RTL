from __future__ import annotations

import random

from .fixed_ops import quantize_float_to_fixed
from .hardware_config import FlashAttentionHardwareConfig


def generate_random_qkv(
    cfg: FlashAttentionHardwareConfig,
    seed: int = 42,
    value_range: tuple[float, float] = (-1.0, 1.0),
) -> tuple[list[list[int]], list[list[int]], list[list[int]]]:
    """Generate random float Q/K/V values and quantize them to configured formats."""

    lo, hi = value_range
    if lo > hi:
        raise ValueError("value_range must be ordered as (min, max)")
    rng = random.Random(seed)

    def make_matrix(fmt):
        return [
            [quantize_float_to_fixed(rng.uniform(lo, hi), fmt) for _ in range(cfg.head_dim)]
            for _ in range(cfg.len_seq)
        ]

    return make_matrix(cfg.q_fmt), make_matrix(cfg.k_fmt), make_matrix(cfg.v_fmt)
