from flash_attn_fixed.data_gen import generate_random_qkv
from flash_attn_fixed.golden_attention import golden_attention_fp32
from flash_attn_fixed.hardware_attention import fixed_point_flash_attention
from flash_attn_fixed.hardware_config import FlashAttentionHardwareConfig
from flash_attn_fixed.stats import compute_error_metrics


def _run_case(
    *,
    len_seq: int,
    head_dim: int,
    Br: int,
    Bc: int,
    causal: bool,
    seed: int,
    max_mae: float,
    max_err: float,
) -> None:
    cfg = FlashAttentionHardwareConfig(
        len_seq=len_seq,
        head_dim=head_dim,
        Br=Br,
        Bc=Bc,
        causal=causal,
    )
    q_raw, k_raw, v_raw = generate_random_qkv(cfg, seed=seed)
    golden = golden_attention_fp32(q_raw, k_raw, v_raw, cfg=cfg)
    fixed = fixed_point_flash_attention(q_raw, k_raw, v_raw, cfg=cfg)
    metrics = compute_error_metrics(golden, fixed, cfg.out_fmt)
    print(
        f"LEN={len_seq} d={head_dim} causal={causal} "
        f"MAE={metrics.mean_abs_error:.8f} "
        f"max={metrics.max_abs_error:.8f} RMSE={metrics.rmse:.8f}"
    )
    assert metrics.mean_abs_error <= max_mae
    assert metrics.max_abs_error <= max_err


def test_hardware_attention_small_noncausal() -> None:
    _run_case(
        len_seq=8,
        head_dim=4,
        Br=2,
        Bc=2,
        causal=False,
        seed=1,
        max_mae=0.05,
        max_err=0.15,
    )


def test_hardware_attention_small_causal() -> None:
    _run_case(
        len_seq=8,
        head_dim=4,
        Br=2,
        Bc=2,
        causal=True,
        seed=2,
        max_mae=0.05,
        max_err=0.15,
    )


def test_hardware_attention_baseline() -> None:
    _run_case(
        len_seq=256,
        head_dim=64,
        Br=16,
        Bc=16,
        causal=True,
        seed=42,
        max_mae=0.03,
        max_err=0.10,
    )
