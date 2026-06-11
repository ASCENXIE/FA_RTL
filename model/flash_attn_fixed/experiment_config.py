from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .fixed_format import FixedFormat
from .hardware_config import FlashAttentionHardwareConfig

FORMAT_FIELDS = (
    "q_fmt",
    "k_fmt",
    "v_fmt",
    "out_fmt",
    "prod_qk_fmt",
    "s_fmt",
    "score_fmt",
    "m_fmt",
    "log2e_fmt",
    "exp_fmt",
    "locall_fmt",
    "l_fmt",
    "localo_fmt",
    "oacc_fmt",
)


@dataclass(frozen=True)
class ExperimentConfig:
    """Top-level experiment settings loaded from JSON."""

    hardware: FlashAttentionHardwareConfig
    seed: int
    value_range: tuple[float, float]
    model_debug_print: bool
    dump_debug: bool
    debug_dir: str
    dump_hex: bool
    print_summary: bool
    mean_abs_error_target: float
    max_abs_error_target: float


def fixed_format_from_dict(name_hint: str, data: dict[str, Any]) -> FixedFormat:
    """Build a ``FixedFormat`` from a JSON dictionary."""

    missing = {"signed", "total_bits", "frac_bits"} - set(data)
    if missing:
        raise ValueError(f"{name_hint} is missing required keys: {sorted(missing)}")
    return FixedFormat(
        name=str(data.get("name", name_hint)),
        signed=bool(data["signed"]),
        total_bits=int(data["total_bits"]),
        frac_bits=int(data["frac_bits"]),
    )


def hardware_config_from_dict(data: dict[str, Any]) -> FlashAttentionHardwareConfig:
    """Build the hardware config from scalar fields and editable format entries."""

    base = FlashAttentionHardwareConfig()
    scalar_fields = (
        "len_seq",
        "head_dim",
        "Br",
        "Bc",
        "causal",
        "saturate",
        "use_rounding",
        "exp_clamp_min_real",
    )
    kwargs: dict[str, Any] = {field: data.get(field, getattr(base, field)) for field in scalar_fields}

    formats = data.get("formats", {})
    if not isinstance(formats, dict):
        raise ValueError("hardware.formats must be a dictionary")

    for field in FORMAT_FIELDS:
        fmt_data = formats.get(field, data.get(field))
        if fmt_data is None:
            kwargs[field] = getattr(base, field)
        else:
            if not isinstance(fmt_data, dict):
                raise ValueError(f"{field} must be a dictionary")
            kwargs[field] = fixed_format_from_dict(field, fmt_data)

    return FlashAttentionHardwareConfig(**kwargs)


def load_experiment_config(path: str | Path) -> ExperimentConfig:
    """Load an experiment JSON file and return typed settings."""

    cfg_path = Path(path)
    raw = json.loads(cfg_path.read_text(encoding="utf-8"))
    hardware = hardware_config_from_dict(raw.get("hardware", {}))

    data = raw.get("data", {})
    value_range_raw = data.get("value_range", [-1.0, 1.0])
    if len(value_range_raw) != 2:
        raise ValueError("data.value_range must contain exactly two numbers")

    debug = raw.get("debug", {})
    report = raw.get("report", {})
    targets = raw.get("targets", {})
    return ExperimentConfig(
        hardware=hardware,
        seed=int(data.get("seed", 42)),
        value_range=(float(value_range_raw[0]), float(value_range_raw[1])),
        model_debug_print=bool(debug.get("model_debug_print", False)),
        dump_debug=bool(debug.get("dump_debug", True)),
        debug_dir=str(debug.get("debug_dir", "debug_logs/run_001")),
        dump_hex=bool(debug.get("dump_hex", True)),
        print_summary=bool(report.get("print_summary", False)),
        mean_abs_error_target=float(targets.get("mean_abs_error", 0.03)),
        max_abs_error_target=float(targets.get("max_abs_error", 0.10)),
    )
