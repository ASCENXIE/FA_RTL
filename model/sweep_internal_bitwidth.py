from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable

from flash_attn_fixed import (
    FlashAttentionHardwareConfig,
    FixedFormat,
    compute_error_metrics,
    fixed_point_flash_attention,
    generate_random_qkv,
    golden_attention_fp32,
    load_experiment_config,
)


DEFAULT_CONFIG = Path(__file__).with_name("experiment_config.json")
DEFAULT_OUTPUT_DIR = Path(__file__).with_name("sweep_results")


@dataclass(frozen=True)
class Candidate:
    candidate_id: str
    cfg: FlashAttentionHardwareConfig
    score_frac: int
    prob_frac: int
    total_internal_bits: int


def parse_int_list(spec: str) -> list[int]:
    values: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            start_s, end_s = part.split(":", 1)
            start = int(start_s)
            end = int(end_s)
            step = 1 if end >= start else -1
            values.extend(range(start, end + step, step))
        else:
            values.append(int(part))
    return list(dict.fromkeys(values))


def make_format(name: str, *, signed: bool, int_bits: int, frac_bits: int) -> FixedFormat:
    if int_bits <= 0:
        raise ValueError(f"{name}: int_bits must be positive")
    if frac_bits < 0:
        raise ValueError(f"{name}: frac_bits must be non-negative")
    return FixedFormat(
        name=name,
        signed=signed,
        total_bits=int_bits + frac_bits,
        frac_bits=frac_bits,
    )


def internal_bit_total(cfg: FlashAttentionHardwareConfig) -> int:
    formats = (
        cfg.s_fmt,
        cfg.score_fmt,
        cfg.m_fmt,
        cfg.log2e_fmt,
        cfg.exp_fmt,
        cfg.locall_fmt,
        cfg.l_fmt,
        cfg.localo_fmt,
        cfg.oacc_fmt,
    )
    return sum(fmt.total_bits for fmt in formats)


def make_candidate(
    base: FlashAttentionHardwareConfig,
    *,
    score_frac: int,
    prob_frac: int,
    s_int: int,
    score_int: int,
    log2e_int: int,
    exp_int: int,
    locall_int: int,
    l_int: int,
    localo_int: int,
    oacc_int: int,
) -> Candidate:
    if score_frac < 3:
        raise ValueError("score_frac must be at least 3 for the 8-segment PWL exp")
    cfg = replace(
        base,
        s_fmt=make_format(f"Q{s_int}.{score_frac}", signed=True, int_bits=s_int, frac_bits=score_frac),
        score_fmt=make_format(
            f"Q{score_int}.{score_frac}",
            signed=True,
            int_bits=score_int,
            frac_bits=score_frac,
        ),
        m_fmt=make_format(
            f"Q{score_int}.{score_frac}",
            signed=True,
            int_bits=score_int,
            frac_bits=score_frac,
        ),
        log2e_fmt=make_format(
            f"Q{log2e_int}.{score_frac}",
            signed=True,
            int_bits=log2e_int,
            frac_bits=score_frac,
        ),
        exp_fmt=make_format(f"UQ{exp_int}.{prob_frac}", signed=False, int_bits=exp_int, frac_bits=prob_frac),
        locall_fmt=make_format(
            f"UQ{locall_int}.{prob_frac}",
            signed=False,
            int_bits=locall_int,
            frac_bits=prob_frac,
        ),
        l_fmt=make_format(f"UQ{l_int}.{prob_frac}", signed=False, int_bits=l_int, frac_bits=prob_frac),
        localo_fmt=make_format(
            f"Q{localo_int}.{prob_frac}",
            signed=True,
            int_bits=localo_int,
            frac_bits=prob_frac,
        ),
        oacc_fmt=make_format(
            f"Q{oacc_int}.{prob_frac}",
            signed=True,
            int_bits=oacc_int,
            frac_bits=prob_frac,
        ),
    )
    return Candidate(
        candidate_id=f"score_f{score_frac}_prob_f{prob_frac}",
        cfg=cfg,
        score_frac=score_frac,
        prob_frac=prob_frac,
        total_internal_bits=internal_bit_total(cfg),
    )


def make_candidates(args: argparse.Namespace, base: FlashAttentionHardwareConfig) -> list[Candidate]:
    candidates = [
        make_candidate(
            base,
            score_frac=score_frac,
            prob_frac=prob_frac,
            s_int=args.s_int,
            score_int=args.score_int,
            log2e_int=args.log2e_int,
            exp_int=args.exp_int,
            locall_int=args.locall_int,
            l_int=args.l_int,
            localo_int=args.localo_int,
            oacc_int=args.oacc_int,
        )
        for score_frac in parse_int_list(args.score_fracs)
        for prob_frac in parse_int_list(args.prob_fracs)
    ]
    return sorted(candidates, key=lambda item: (item.total_internal_bits, item.score_frac, item.prob_frac))


def format_labels(cfg: FlashAttentionHardwareConfig) -> dict[str, str]:
    return {
        "s_fmt": cfg.s_fmt.label(),
        "score_fmt": cfg.score_fmt.label(),
        "m_fmt": cfg.m_fmt.label(),
        "log2e_fmt": cfg.log2e_fmt.label(),
        "exp_fmt": cfg.exp_fmt.label(),
        "locall_fmt": cfg.locall_fmt.label(),
        "l_fmt": cfg.l_fmt.label(),
        "localo_fmt": cfg.localo_fmt.label(),
        "oacc_fmt": cfg.oacc_fmt.label(),
    }


def seed_cases(
    cfg: FlashAttentionHardwareConfig,
    seeds: Iterable[int],
    value_range: tuple[float, float],
) -> list[tuple[int, list[list[int]], list[list[int]], list[list[int]], list[list[float]]]]:
    cases = []
    for seed in seeds:
        q_raw, k_raw, v_raw = generate_random_qkv(cfg, seed=seed, value_range=value_range)
        golden = golden_attention_fp32(q_raw, k_raw, v_raw, cfg=cfg)
        cases.append((seed, q_raw, k_raw, v_raw, golden))
    return cases


def evaluate_candidate(
    candidate: Candidate,
    cases: list[tuple[int, list[list[int]], list[list[int]], list[list[int]], list[list[float]]]],
    *,
    mean_target: float,
    max_target: float,
) -> dict[str, object]:
    per_seed: list[dict[str, float | int]] = []
    worst_mae = 0.0
    worst_max = 0.0
    worst_rmse = 0.0
    error = ""

    try:
        for seed, q_raw, k_raw, v_raw, golden in cases:
            fixed = fixed_point_flash_attention(
                q_raw,
                k_raw,
                v_raw,
                cfg=candidate.cfg,
                debug=False,
                dump_debug=False,
            )
            metrics = compute_error_metrics(golden, fixed, candidate.cfg.out_fmt)
            worst_mae = max(worst_mae, metrics.mean_abs_error)
            worst_max = max(worst_max, metrics.max_abs_error)
            worst_rmse = max(worst_rmse, metrics.rmse)
            per_seed.append(
                {
                    "seed": seed,
                    "mean_abs_error": metrics.mean_abs_error,
                    "max_abs_error": metrics.max_abs_error,
                    "rmse": metrics.rmse,
                }
            )
    except Exception as exc:  # Keep a failed candidate visible in the sweep output.
        error = f"{type(exc).__name__}: {exc}"

    passed = not error and worst_mae <= mean_target and worst_max <= max_target
    row: dict[str, object] = {
        "candidate_id": candidate.candidate_id,
        "passed": passed,
        "error": error,
        "score_frac": candidate.score_frac,
        "prob_frac": candidate.prob_frac,
        "total_internal_bits": candidate.total_internal_bits,
        "worst_mean_abs_error": worst_mae,
        "worst_max_abs_error": worst_max,
        "worst_rmse": worst_rmse,
        "per_seed": per_seed,
    }
    row.update(format_labels(candidate.cfg))
    return row


def write_results(output_dir: Path, rows: list[dict[str, object]]) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "internal_bitwidth_sweep.json"
    csv_path = output_dir / "internal_bitwidth_sweep.csv"

    json_path.write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")

    csv_fields = [
        "candidate_id",
        "passed",
        "error",
        "total_internal_bits",
        "score_frac",
        "prob_frac",
        "worst_mean_abs_error",
        "worst_max_abs_error",
        "worst_rmse",
        "s_fmt",
        "score_fmt",
        "m_fmt",
        "log2e_fmt",
        "exp_fmt",
        "locall_fmt",
        "l_fmt",
        "localo_fmt",
        "oacc_fmt",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=csv_fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in csv_fields})

    return json_path, csv_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sweep internal fixed-point datapath formats while keeping Q/K/V/O fixed."
    )
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--seeds", default="42", help="Comma list or inclusive ranges, e.g. 42 or 0:9")
    parser.add_argument(
        "--value-range",
        default=None,
        help="Override data.value_range as min,max. Example: -4,4 or -128,127.99609375",
    )
    parser.add_argument("--score-fracs", default="16,14,12,10,8")
    parser.add_argument("--prob-fracs", default="23,20,18,16,14,12,10")
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument("--stop-after-first-pass", action="store_true")

    parser.add_argument("--s-int", type=int, default=8)
    parser.add_argument("--score-int", type=int, default=5)
    parser.add_argument("--log2e-int", type=int, default=2)
    parser.add_argument("--exp-int", type=int, default=1)
    parser.add_argument("--locall-int", type=int, default=5)
    parser.add_argument("--l-int", type=int, default=9)
    parser.add_argument("--localo-int", type=int, default=6)
    parser.add_argument("--oacc-int", type=int, default=10)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    exp_cfg = load_experiment_config(args.config)
    seeds = parse_int_list(args.seeds)
    candidates = make_candidates(args, exp_cfg.hardware)
    if args.value_range is None:
        value_range = exp_cfg.value_range
    else:
        min_s, max_s = args.value_range.split(",", 1)
        value_range = (float(min_s), float(max_s))
    cases = seed_cases(exp_cfg.hardware, seeds, value_range)

    rows: list[dict[str, object]] = []
    for candidate in candidates:
        row = evaluate_candidate(
            candidate,
            cases,
            mean_target=exp_cfg.mean_abs_error_target,
            max_target=exp_cfg.max_abs_error_target,
        )
        rows.append(row)
        if args.stop_after_first_pass and row["passed"]:
            break

    rows.sort(
        key=lambda row: (
            not bool(row["passed"]),
            int(row["total_internal_bits"]),
            float(row["worst_mean_abs_error"]),
            float(row["worst_max_abs_error"]),
        )
    )
    json_path, csv_path = write_results(args.output_dir, rows)

    passing = [row for row in rows if row["passed"]]
    print(f"Tested {len(rows)} candidates over seeds {seeds}.")
    print(f"Value range: [{value_range[0]}, {value_range[1]}]")
    print(f"Passing candidates: {len(passing)}")
    print(f"JSON: {json_path}")
    print(f"CSV : {csv_path}")
    if passing:
        print("")
        print(f"Top {min(args.top, len(passing))} passing candidates:")
        for row in passing[: args.top]:
            print(
                "  "
                f"{row['candidate_id']:20s} "
                f"bits={row['total_internal_bits']:3d} "
                f"MAE={row['worst_mean_abs_error']:.6f} "
                f"MAX={row['worst_max_abs_error']:.6f} "
                f"score={row['score_fmt']} exp={row['exp_fmt']} "
                f"l={row['l_fmt']} oacc={row['oacc_fmt']}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
