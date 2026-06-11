import math

from flash_attn_fixed.exp_pwl import exp_pwl_fixed
from flash_attn_fixed.fixed_ops import quantize_float_to_fixed
from flash_attn_fixed.hardware_config import FlashAttentionHardwareConfig


def test_exp_pwl_sample_points() -> None:
    cfg = FlashAttentionHardwareConfig()
    for value in [0.0, -0.125, -0.5, -1.0, -2.0, -4.0, -8.0, -16.0]:
        x_int = quantize_float_to_fixed(value, cfg.score_fmt)
        y = exp_pwl_fixed(x_int, cfg) / cfg.exp_fmt.scale
        ref = math.exp(value)
        err = abs(y - ref)
        print(f"x={value:7.3f} pwl={y:.8f} ref={ref:.8f} err={err:.8f}")
        assert err < 0.01


def test_exp_pwl_positive_clamps_to_one() -> None:
    cfg = FlashAttentionHardwareConfig()
    x_int = quantize_float_to_fixed(0.25, cfg.score_fmt)
    assert exp_pwl_fixed(x_int, cfg) == cfg.exp_fmt.scale
