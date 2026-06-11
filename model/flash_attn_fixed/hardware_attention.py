from __future__ import annotations

from pathlib import Path

from .debug_dump import DebugDumper
from .exp_pwl import exp_pwl_fixed
from .fixed_format import FixedFormat
from .fixed_ops import (
    align_fixed,
    clip_or_assert,
    dequantize_fixed_to_float,
    round_shift_right_signed,
    round_shift_right_unsigned,
    sat,
)
from .hardware_config import FlashAttentionHardwareConfig


def _check_matrix(name: str, matrix: list[list[int]], rows: int, cols: int, fmt: FixedFormat) -> None:
    if len(matrix) != rows:
        raise ValueError(f"{name} must have {rows} rows")
    for row_idx, row in enumerate(matrix):
        if len(row) != cols:
            raise ValueError(f"{name}[{row_idx}] must have {cols} columns")
        for col_idx, value in enumerate(row):
            clip_or_assert(value, fmt, saturate=False)


def normalize_to_q8_8(old_o: int, old_l: int, cfg: FlashAttentionHardwareConfig) -> int:
    """Normalize numerator by denominator and return output-format raw int."""

    if old_l == 0:
        return 0
    sign = old_o < 0
    out_shift = cfg.out_fmt.frac_bits + cfg.l_fmt.frac_bits - cfg.oacc_fmt.frac_bits
    abs_num = abs(old_o)
    if out_shift >= 0:
        abs_num <<= out_shift
    else:
        abs_num = round_shift_right_unsigned(abs_num, -out_shift)
    q_abs = (abs_num + (old_l >> 1)) // old_l
    q = -q_abs if sign else q_abs
    return sat(q, cfg.out_fmt)


def _round_info_formats(cfg: FlashAttentionHardwareConfig) -> dict[str, str]:
    return {
        "S": cfg.s_fmt.label(),
        "S_scaled": cfg.score_fmt.label(),
        "local_m": cfg.m_fmt.label(),
        "old_m": cfg.m_fmt.label(),
        "new_m": cfg.m_fmt.label(),
        "b": cfg.exp_fmt.label(),
        "N": cfg.score_fmt.label(),
        "P": cfg.exp_fmt.label(),
        "local_l": cfg.locall_fmt.label(),
        "old_l": cfg.l_fmt.label(),
        "new_l": cfg.l_fmt.label(),
        "local_o": cfg.localo_fmt.label(),
        "old_o": cfg.oacc_fmt.label(),
        "new_o": cfg.oacc_fmt.label(),
    }


def fixed_point_flash_attention(
    q_raw: list[list[int]],
    k_raw: list[list[int]],
    v_raw: list[list[int]],
    *,
    cfg: FlashAttentionHardwareConfig,
    debug: bool = False,
    dump_debug: bool = False,
    debug_dir: str | Path = "debug_logs",
    dump_hex: bool = True,
) -> list[list[int]]:
    """Run block-wise online-softmax FlashAttention using integer fixed-point ops."""

    n = cfg.len_seq
    d = cfg.head_dim
    _check_matrix("q_raw", q_raw, n, d, cfg.q_fmt)
    _check_matrix("k_raw", k_raw, n, d, cfg.k_fmt)
    _check_matrix("v_raw", v_raw, n, d, cfg.v_fmt)

    dumper = DebugDumper(debug_dir, cfg, dump_hex=dump_hex) if dump_debug else None
    if dumper is not None:
        dumper.dump_config()
        dumper.dump_matrix("input_q_raw.csv", q_raw, cfg.q_fmt)
        dumper.dump_matrix("input_k_raw.csv", k_raw, cfg.k_fmt)
        dumper.dump_matrix("input_v_raw.csv", v_raw, cfg.v_fmt)
        dumper.dump_matrix(
            "input_q_float.csv",
            [[dequantize_fixed_to_float(x, cfg.q_fmt) for x in row] for row in q_raw],
            None,
        )
        dumper.dump_matrix(
            "input_k_float.csv",
            [[dequantize_fixed_to_float(x, cfg.k_fmt) for x in row] for row in k_raw],
            None,
        )
        dumper.dump_matrix(
            "input_v_float.csv",
            [[dequantize_fixed_to_float(x, cfg.v_fmt) for x in row] for row in v_raw],
            None,
        )

    output = [[0 for _ in range(d)] for _ in range(n)]
    scale_shift = cfg.scale_shift

    for q_blk_index, q_blk_start in enumerate(range(0, n, cfg.Br)):
        q_blk_end = min(q_blk_start + cfg.Br, n)
        actual_br = q_blk_end - q_blk_start
        old_m = [0] * actual_br
        old_l = [0] * actual_br
        old_o = [[0] * d for _ in range(actual_br)]
        has_state = [False] * actual_br
        skipped_kv_blocks: list[dict[str, int | str]] = []
        kv_round_index = 0

        if debug:
            print(f"q_block {q_blk_index}: rows {q_blk_start}..{q_blk_end - 1}")

        for kv_block_index, kv_blk_start in enumerate(range(0, n, cfg.Bc)):
            kv_blk_end = min(kv_blk_start + cfg.Bc, n)
            actual_bc = kv_blk_end - kv_blk_start

            if cfg.causal and kv_blk_start > q_blk_end - 1:
                skipped_kv_blocks.append(
                    {
                        "kv_block_index": kv_block_index,
                        "kv_start": kv_blk_start,
                        "kv_end": kv_blk_end,
                        "reason": "fully_future_causal_tile",
                    }
                )
                continue

            old_m_before = old_m.copy()
            old_l_before = old_l.copy()
            old_o_before = [row.copy() for row in old_o]
            row_has_state_before = has_state.copy()

            s_mat = [[0] * actual_bc for _ in range(actual_br)]
            s_scaled = [[0] * actual_bc for _ in range(actual_br)]
            valid_mask = [[0] * actual_bc for _ in range(actual_br)]
            n_mat = [[0] * actual_bc for _ in range(actual_br)]
            p_mat = [[0] * actual_bc for _ in range(actual_br)]
            local_m = [0] * actual_br
            new_m = old_m.copy()
            b_vec = [0] * actual_br
            local_l = [0] * actual_br
            new_l = old_l.copy()
            local_o = [[0] * d for _ in range(actual_br)]
            new_o = [row.copy() for row in old_o]
            row_has_valid = [False] * actual_br

            for r in range(actual_br):
                qi = q_blk_start + r
                valid_scores: list[int] = []
                for c in range(actual_bc):
                    kj = kv_blk_start + c
                    acc = 0
                    for t in range(d):
                        acc += q_raw[qi][t] * k_raw[kj][t]
                    acc = align_fixed(acc, cfg.q_fmt.frac_bits + cfg.k_fmt.frac_bits, cfg.s_fmt)
                    s_mat[r][c] = acc
                    scaled = round_shift_right_signed(acc, scale_shift)
                    scaled = align_fixed(scaled, cfg.s_fmt.frac_bits, cfg.score_fmt)
                    s_scaled[r][c] = scaled
                    valid = (not cfg.causal) or (kj <= qi)
                    valid_mask[r][c] = 1 if valid else 0
                    if valid:
                        valid_scores.append(scaled)
                if valid_scores:
                    row_has_valid[r] = True
                    local_m[r] = align_fixed(max(valid_scores), cfg.score_fmt.frac_bits, cfg.m_fmt)

            for r in range(actual_br):
                if not row_has_valid[r]:
                    continue
                if not has_state[r] or old_l[r] == 0:
                    new_m[r] = local_m[r]
                    b_vec[r] = 0
                else:
                    new_m[r] = max(old_m[r], local_m[r])
                    old_m_score = align_fixed(old_m[r], cfg.m_fmt.frac_bits, cfg.score_fmt)
                    new_m_score = align_fixed(new_m[r], cfg.m_fmt.frac_bits, cfg.score_fmt)
                    delta_m = sat(old_m_score - new_m_score, cfg.score_fmt)
                    b_vec[r] = exp_pwl_fixed(delta_m, cfg)

            for r in range(actual_br):
                if not row_has_valid[r]:
                    continue
                for c in range(actual_bc):
                    if not valid_mask[r][c]:
                        n_mat[r][c] = 0
                        p_mat[r][c] = 0
                        continue
                    new_m_score = align_fixed(new_m[r], cfg.m_fmt.frac_bits, cfg.score_fmt)
                    diff = sat(s_scaled[r][c] - new_m_score, cfg.score_fmt)
                    n_mat[r][c] = diff
                    p_mat[r][c] = exp_pwl_fixed(diff, cfg)
                local_l[r] = align_fixed(sum(p_mat[r]), cfg.exp_fmt.frac_bits, cfg.locall_fmt)

            for r in range(actual_br):
                if not row_has_valid[r]:
                    continue
                if not has_state[r] or old_l[r] == 0:
                    new_l[r] = align_fixed(local_l[r], cfg.locall_fmt.frac_bits, cfg.l_fmt)
                else:
                    oldl_mul = old_l[r] * b_vec[r]
                    oldl_scaled = round_shift_right_unsigned(oldl_mul, cfg.exp_fmt.frac_bits)
                    oldl_scaled = sat(oldl_scaled, cfg.l_fmt)
                    local_l_as_l = align_fixed(local_l[r], cfg.locall_fmt.frac_bits, cfg.l_fmt)
                    new_l[r] = sat(oldl_scaled + local_l_as_l, cfg.l_fmt)

            for r in range(actual_br):
                if not row_has_valid[r]:
                    continue
                for dim in range(d):
                    acc = 0
                    for c in range(actual_bc):
                        kj = kv_blk_start + c
                        prod_pv = p_mat[r][c] * v_raw[kj][dim]
                        prod_pv_q23 = round_shift_right_signed(prod_pv, cfg.v_fmt.frac_bits)
                        acc += prod_pv_q23
                    local_o[r][dim] = align_fixed(acc, cfg.exp_fmt.frac_bits, cfg.localo_fmt)
                    if not has_state[r] or old_l[r] == 0:
                        new_o[r][dim] = align_fixed(local_o[r][dim], cfg.localo_fmt.frac_bits, cfg.oacc_fmt)
                    else:
                        oldo_mul = old_o[r][dim] * b_vec[r]
                        oldo_scaled = round_shift_right_signed(oldo_mul, cfg.exp_fmt.frac_bits)
                        oldo_scaled = sat(oldo_scaled, cfg.oacc_fmt)
                        local_o_as_oacc = align_fixed(local_o[r][dim], cfg.localo_fmt.frac_bits, cfg.oacc_fmt)
                        new_o[r][dim] = sat(oldo_scaled + local_o_as_oacc, cfg.oacc_fmt)

            for r in range(actual_br):
                if row_has_valid[r]:
                    old_m[r] = new_m[r]
                    old_l[r] = new_l[r]
                    old_o[r] = new_o[r].copy()
                    has_state[r] = True

            if dumper is not None:
                round_info = {
                    "q_block_index": q_blk_index,
                    "kv_round_index": kv_round_index,
                    "q_start": q_blk_start,
                    "q_end": q_blk_end,
                    "kv_start": kv_blk_start,
                    "kv_end": kv_blk_end,
                    "actual_Br": actual_br,
                    "actual_Bc": actual_bc,
                    "causal": cfg.causal,
                    "has_any_valid": any(row_has_valid),
                    "row_has_valid": row_has_valid,
                    "row_has_state_before": row_has_state_before,
                    "row_has_state_after": has_state.copy(),
                    "invalid_N_policy": "N is written as 0 for invalid mask positions",
                    "formats": _round_info_formats(cfg),
                }
                tensors = {
                    "S": s_mat,
                    "S_scaled": s_scaled,
                    "valid_mask": valid_mask,
                    "local_m": local_m,
                    "old_m_before": old_m_before,
                    "new_m": new_m,
                    "b": b_vec,
                    "N": n_mat,
                    "P": p_mat,
                    "local_l": local_l,
                    "old_l_before": old_l_before,
                    "new_l": new_l,
                    "local_o": local_o,
                    "old_o_before": old_o_before,
                    "new_o": new_o,
                }
                dumper.dump_round(q_blk_index, kv_round_index, round_info, tensors)

            kv_round_index += 1

        q_block_output: list[list[int]] = []
        for r in range(actual_br):
            out_row: list[int] = []
            for dim in range(d):
                value = normalize_to_q8_8(old_o[r][dim], old_l[r], cfg)
                output[q_blk_start + r][dim] = value
                out_row.append(value)
            q_block_output.append(out_row)

        if dumper is not None:
            q_block_info = {
                "q_block_index": q_blk_index,
                "q_start": q_blk_start,
                "q_end": q_blk_end,
                "actual_Br": actual_br,
                "num_kv_rounds_executed": kv_round_index,
                "skipped_kv_blocks": skipped_kv_blocks,
            }
            dumper.dump_q_block_outputs(q_blk_index, q_block_info, q_block_output)

    if dumper is not None:
        dumper.dump_matrix("output_o_raw.csv", output, cfg.out_fmt)
        dumper.dump_matrix(
            "output_o_float.csv",
            [[dequantize_fixed_to_float(x, cfg.out_fmt) for x in row] for row in output],
            None,
        )

    return output
