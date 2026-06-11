from pathlib import Path

from flash_attn_fixed.experiment_config import load_experiment_config


def test_default_experiment_config_loads() -> None:
    cfg_path = Path(__file__).resolve().parents[1] / "experiment_config.json"
    exp_cfg = load_experiment_config(cfg_path)
    assert exp_cfg.hardware.len_seq == 256
    assert exp_cfg.hardware.head_dim == 64
    assert exp_cfg.hardware.Br == 16
    assert exp_cfg.hardware.Bc == 16
    assert exp_cfg.dump_debug is True
    assert exp_cfg.print_summary is False
    assert exp_cfg.hardware.q_fmt.name == "Q8.8"
    assert exp_cfg.hardware.oacc_fmt.total_bits == 39
