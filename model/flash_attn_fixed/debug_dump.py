from __future__ import annotations

import csv
import json
import shutil
from pathlib import Path
from typing import Any

from .fixed_format import FixedFormat
from .fixed_ops import dequantize_fixed_to_float
from .hardware_config import FlashAttentionHardwareConfig
from .stats import ErrorMetrics


def int_to_twos_complement_hex(value: int, width: int) -> str:
    """Format ``value`` as a width-bit two's-complement hexadecimal string."""

    if width <= 0:
        raise ValueError("width must be positive")
    mask = (1 << width) - 1
    encoded = int(value) & mask
    digits = (width + 3) // 4
    return f"0x{encoded:0{digits}x}"


class DebugDumper:
    """Write stable CSV/JSON logs for RTL-oriented datapath comparison."""

    def __init__(
        self,
        root_dir: str | Path,
        cfg: FlashAttentionHardwareConfig,
        dump_hex: bool = True,
        *,
        clean: bool = True,
    ):
        self.root_dir = Path(root_dir)
        self.cfg = cfg
        self.dump_hex = dump_hex
        if clean and self.root_dir.exists():
            shutil.rmtree(self.root_dir)
        self.root_dir.mkdir(parents=True, exist_ok=True)

    def _path(self, path: str | Path) -> Path:
        path = Path(path)
        if path.is_absolute():
            return path
        return self.root_dir / path

    def dump_json(self, path: str | Path, data: dict[str, Any]) -> None:
        """Write a JSON file below the debug root."""

        out_path = self._path(path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")

    def dump_config(self) -> None:
        """Dump the full hardware configuration."""

        self.dump_json("config.json", self.cfg.to_dict())

    def dump_matrix(
        self,
        path: str | Path,
        matrix,
        fmt: FixedFormat | None = None,
        *,
        col_name: str = "col",
    ) -> None:
        """Dump a 2-D matrix as CSV with optional fixed-width hex."""

        out_path = self._path(path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            header = ["row", col_name, "value"]
            if self.dump_hex and fmt is not None:
                header.append("hex")
            writer.writerow(header)
            for row_idx, row in enumerate(matrix):
                for col_idx, value in enumerate(row):
                    record = [row_idx, col_idx, value]
                    if self.dump_hex and fmt is not None:
                        record.append(int_to_twos_complement_hex(int(value), fmt.total_bits))
                    writer.writerow(record)

    def dump_vector(
        self,
        path: str | Path,
        vector,
        fmt: FixedFormat | None = None,
    ) -> None:
        """Dump a 1-D vector as CSV with optional fixed-width hex."""

        out_path = self._path(path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            header = ["index", "value"]
            if self.dump_hex and fmt is not None:
                header.append("hex")
            writer.writerow(header)
            for idx, value in enumerate(vector):
                record = [idx, value]
                if self.dump_hex and fmt is not None:
                    record.append(int_to_twos_complement_hex(int(value), fmt.total_bits))
                writer.writerow(record)

    def dump_round(
        self,
        q_block_index: int,
        kv_round_index: int,
        round_info: dict[str, Any],
        tensors: dict[str, Any],
    ) -> None:
        """Dump all tensors for one Q-block/KV-tile update."""

        base = Path(f"q_block_{q_block_index:03d}") / f"kv_round_{kv_round_index:03d}"
        self.dump_json(base / "round_info.json", round_info)
        fmt_map: dict[str, FixedFormat | None] = {
            "S": self.cfg.s_fmt,
            "S_scaled": self.cfg.score_fmt,
            "valid_mask": None,
            "local_m": self.cfg.m_fmt,
            "old_m_before": self.cfg.m_fmt,
            "new_m": self.cfg.m_fmt,
            "b": self.cfg.exp_fmt,
            "N": self.cfg.score_fmt,
            "P": self.cfg.exp_fmt,
            "local_l": self.cfg.locall_fmt,
            "old_l_before": self.cfg.l_fmt,
            "new_l": self.cfg.l_fmt,
            "local_o": self.cfg.localo_fmt,
            "old_o_before": self.cfg.oacc_fmt,
            "new_o": self.cfg.oacc_fmt,
        }
        vectors = {
            "local_m",
            "old_m_before",
            "new_m",
            "b",
            "local_l",
            "old_l_before",
            "new_l",
        }
        dim_matrices = {"local_o", "old_o_before", "new_o"}
        for name, tensor in tensors.items():
            fmt = fmt_map.get(name)
            if name in vectors:
                self.dump_vector(base / f"{name}.csv", tensor, fmt)
            elif name in dim_matrices:
                self.dump_matrix(base / f"{name}.csv", tensor, fmt, col_name="dim")
            else:
                self.dump_matrix(base / f"{name}.csv", tensor, fmt)

    def dump_q_block_outputs(
        self,
        q_block_index: int,
        q_block_info: dict[str, Any],
        output_raw: list[list[int]],
    ) -> None:
        """Dump final raw and float outputs for one Q block."""

        base = Path(f"q_block_{q_block_index:03d}")
        self.dump_json(base / "q_block_info.json", q_block_info)
        self.dump_matrix(base / "q_block_output_raw.csv", output_raw, self.cfg.out_fmt, col_name="dim")
        output_float = [
            [dequantize_fixed_to_float(value, self.cfg.out_fmt) for value in row]
            for row in output_raw
        ]
        self.dump_matrix(base / "q_block_output_float.csv", output_float, None, col_name="dim")

    def dump_inputs_outputs(
        self,
        q_raw,
        k_raw,
        v_raw,
        o_raw,
        golden_o_float,
        metrics: ErrorMetrics,
    ) -> None:
        """Dump full-run inputs, outputs, golden values, and error summary."""

        self.dump_config()
        self.dump_matrix("input_q_raw.csv", q_raw, self.cfg.q_fmt)
        self.dump_matrix("input_k_raw.csv", k_raw, self.cfg.k_fmt)
        self.dump_matrix("input_v_raw.csv", v_raw, self.cfg.v_fmt)
        self.dump_matrix(
            "input_q_float.csv",
            [[dequantize_fixed_to_float(x, self.cfg.q_fmt) for x in row] for row in q_raw],
            None,
        )
        self.dump_matrix(
            "input_k_float.csv",
            [[dequantize_fixed_to_float(x, self.cfg.k_fmt) for x in row] for row in k_raw],
            None,
        )
        self.dump_matrix(
            "input_v_float.csv",
            [[dequantize_fixed_to_float(x, self.cfg.v_fmt) for x in row] for row in v_raw],
            None,
        )
        self.dump_matrix("output_o_raw.csv", o_raw, self.cfg.out_fmt)
        self.dump_matrix(
            "output_o_float.csv",
            [[dequantize_fixed_to_float(x, self.cfg.out_fmt) for x in row] for row in o_raw],
            None,
        )
        self.dump_matrix("golden_o_float.csv", golden_o_float, None)
        summary = metrics.to_dict()
        summary["meets_mae_target"] = metrics.mean_abs_error <= 0.03
        summary["meets_max_error_target"] = metrics.max_abs_error <= 0.10
        summary["meets_competition_target"] = (
            summary["meets_mae_target"] and summary["meets_max_error_target"]
        )
        self.dump_json("error_summary.json", summary)
