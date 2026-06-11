from __future__ import annotations

import math
from dataclasses import dataclass, field, fields

from .fixed_format import (
    Q2_16,
    Q8_8,
    Q12_23,
    Q16_16,
    Q16_23,
    Q22_16,
    UQ1_23,
    UQ5_23,
    UQ9_23,
    FixedFormat,
)


@dataclass(frozen=True)
class FlashAttentionHardwareConfig:
    """Configuration for the fixed-point FlashAttention datapath model."""

    len_seq: int = 256
    head_dim: int = 64
    Br: int = 16
    Bc: int = 16
    causal: bool = True

    q_fmt: FixedFormat = field(default_factory=lambda: Q8_8)
    k_fmt: FixedFormat = field(default_factory=lambda: Q8_8)
    v_fmt: FixedFormat = field(default_factory=lambda: Q8_8)
    out_fmt: FixedFormat = field(default_factory=lambda: Q8_8)

    prod_qk_fmt: FixedFormat = field(default_factory=lambda: Q16_16)
    s_fmt: FixedFormat = field(default_factory=lambda: Q22_16)
    score_fmt: FixedFormat = field(default_factory=lambda: Q22_16)
    m_fmt: FixedFormat = field(default_factory=lambda: Q22_16)

    log2e_fmt: FixedFormat = field(default_factory=lambda: Q2_16)
    exp_fmt: FixedFormat = field(default_factory=lambda: UQ1_23)

    locall_fmt: FixedFormat = field(default_factory=lambda: UQ5_23)
    l_fmt: FixedFormat = field(default_factory=lambda: UQ9_23)

    localo_fmt: FixedFormat = field(default_factory=lambda: Q12_23)
    oacc_fmt: FixedFormat = field(default_factory=lambda: Q16_23)

    saturate: bool = True
    use_rounding: bool = True
    exp_clamp_min_real: float = -16.0

    def __post_init__(self) -> None:
        if self.len_seq <= 0 or self.head_dim <= 0:
            raise ValueError("len_seq and head_dim must be positive")
        if self.Br <= 0 or self.Bc <= 0:
            raise ValueError("Br and Bc must be positive")

    @property
    def scale_shift(self) -> int:
        """Return log2(sqrt(head_dim)) when it can be implemented as a shift."""

        sqrt_d = math.isqrt(self.head_dim)
        if sqrt_d * sqrt_d != self.head_dim or sqrt_d & (sqrt_d - 1):
            raise NotImplementedError(
                "Only head_dim values with power-of-two sqrt are shift-scaled"
            )
        return sqrt_d.bit_length() - 1

    def to_dict(self) -> dict[str, object]:
        """Serialize scalar parameters and fixed-point formats."""

        data: dict[str, object] = {}
        for item in fields(self):
            value = getattr(self, item.name)
            if isinstance(value, FixedFormat):
                data[item.name] = value.to_dict()
            else:
                data[item.name] = value
        data["scale_shift"] = self.scale_shift
        return data
