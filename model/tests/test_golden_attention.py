import math

from flash_attn_fixed.data_gen import generate_random_qkv
from flash_attn_fixed.golden_attention import golden_attention_fp32
from flash_attn_fixed.hardware_config import FlashAttentionHardwareConfig


def _run_case(causal: bool) -> None:
    cfg = FlashAttentionHardwareConfig(len_seq=8, head_dim=4, Br=2, Bc=2, causal=causal)
    q_raw, k_raw, v_raw = generate_random_qkv(cfg, seed=123)
    out = golden_attention_fp32(q_raw, k_raw, v_raw, cfg=cfg)
    assert len(out) == cfg.len_seq
    assert all(len(row) == cfg.head_dim for row in out)
    assert all(not math.isnan(value) for row in out for value in row)


def test_golden_attention_small_noncausal() -> None:
    _run_case(causal=False)


def test_golden_attention_small_causal() -> None:
    _run_case(causal=True)
