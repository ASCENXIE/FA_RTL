from __future__ import annotations

import argparse
from pathlib import Path

from flash_attn_fixed import (
    compute_error_metrics,
    fixed_point_flash_attention,
    generate_random_qkv,
    golden_attention_fp32,
    load_experiment_config,
)
from flash_attn_fixed.debug_dump import DebugDumper
from flash_attn_fixed.stats import print_format_summary, print_memory_summary


DEFAULT_CONFIG = Path(__file__).with_name("experiment_config.json")


def parse_args() -> argparse.Namespace:
    """Parse the optional config file path for a fixed-point attention experiment."""

    parser = argparse.ArgumentParser(description="Run fixed-point FlashAttention experiment")
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help="JSON experiment config path. Defaults to experiment_config.json.",
    )
    return parser.parse_args()


def main() -> int:
    """Run golden and fixed-point models using a JSON experiment config."""

    args = parse_args()
    exp_cfg = load_experiment_config(args.config)
    cfg = exp_cfg.hardware
    q_raw, k_raw, v_raw = generate_random_qkv(
        cfg,
        seed=exp_cfg.seed,
        value_range=exp_cfg.value_range,
    )
    golden = golden_attention_fp32(q_raw, k_raw, v_raw, cfg=cfg)
    fixed = fixed_point_flash_attention(
        q_raw,
        k_raw,
        v_raw,
        cfg=cfg,
        debug=exp_cfg.model_debug_print,
        dump_debug=exp_cfg.dump_debug,
        debug_dir=exp_cfg.debug_dir,
        dump_hex=exp_cfg.dump_hex,
    )
    metrics = compute_error_metrics(golden, fixed, cfg.out_fmt)

    meets_target = (
        metrics.mean_abs_error <= exp_cfg.mean_abs_error_target
        and metrics.max_abs_error <= exp_cfg.max_abs_error_target
    )

    if exp_cfg.print_summary:
        print_format_summary(cfg)
        print_memory_summary(cfg)
        print("Error metrics")
        print(f"  MAE           : {metrics.mean_abs_error:.8f}")
        print(f"  Max abs error : {metrics.max_abs_error:.8f}")
        print(f"  RMSE          : {metrics.rmse:.8f}")
        print(f"  Meets target  : {meets_target}")
        if exp_cfg.dump_debug:
            print(f"Debug logs written to: {exp_cfg.debug_dir}")

    if exp_cfg.dump_debug:
        dumper = DebugDumper(exp_cfg.debug_dir, cfg, dump_hex=exp_cfg.dump_hex, clean=False)
        dumper.dump_inputs_outputs(q_raw, k_raw, v_raw, fixed, golden, metrics)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
