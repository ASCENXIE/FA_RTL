from __future__ import annotations

from .fixed_ops import align_fixed, quantize_float_to_fixed, round_shift_right_signed, round_shift_right_unsigned, sat
from .hardware_config import FlashAttentionHardwareConfig

LOG2E_REAL = 1.4426950408889634
LOG2E_Q2_16 = 94548

INTERCEPT_Q23 = [
    8388608,
    7692387,
    7053950,
    6468501,
    5931642,
    5439339,
    4987896,
    4573921,
]

SLOPE_Q23 = [
    -5569764,
    -5107496,
    -4683595,
    -4294875,
    -3938418,
    -3611545,
    -3311802,
    -3036936,
]


def _log2e_int(cfg: FlashAttentionHardwareConfig) -> int:
    if cfg.log2e_fmt.total_bits == 18 and cfg.log2e_fmt.frac_bits == 16 and cfg.log2e_fmt.signed:
        return LOG2E_Q2_16
    return quantize_float_to_fixed(LOG2E_REAL, cfg.log2e_fmt)


def exp_pwl_fixed(x_int: int, cfg: FlashAttentionHardwareConfig) -> int:
    """Approximate exp(x) for score-format inputs and return exp-format raw int."""

    exp_one = 1 << cfg.exp_fmt.frac_bits
    clamp_min = round(cfg.exp_clamp_min_real * cfg.score_fmt.scale)

    if x_int >= 0:
        return sat(exp_one, cfg.exp_fmt)
    if x_int <= clamp_min:
        return 0

    z_mul = int(x_int) * _log2e_int(cfg)
    z_pre = round_shift_right_signed(z_mul, cfg.log2e_fmt.frac_bits)
    z_int = sat(z_pre, cfg.score_fmt)

    t_int = -z_int
    frac_mask = (1 << cfg.score_fmt.frac_bits) - 1
    integer_part = t_int >> cfg.score_fmt.frac_bits
    frac = t_int & frac_mask

    segment = frac >> (cfg.score_fmt.frac_bits - 3)
    delta_q16 = frac & ((1 << (cfg.score_fmt.frac_bits - 3)) - 1)

    prod_q39 = SLOPE_Q23[segment] * delta_q16
    prod_q23 = round_shift_right_signed(prod_q39, cfg.score_fmt.frac_bits)
    two_minus_f_q23 = INTERCEPT_Q23[segment] + prod_q23
    two_minus_f_q23 = min(max(two_minus_f_q23, 0), 1 << 23)

    if integer_part >= 24:
        y_q23 = 0
    else:
        y_q23 = round_shift_right_unsigned(two_minus_f_q23, integer_part)
    return align_fixed(y_q23, 23, cfg.exp_fmt)
