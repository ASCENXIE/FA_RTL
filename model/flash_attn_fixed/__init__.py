"""Fixed-point FlashAttention-style reference model."""

from .data_gen import generate_random_qkv
from .exp_pwl import exp_pwl_fixed
from .experiment_config import ExperimentConfig, load_experiment_config
from .fixed_format import FixedFormat
from .golden_attention import golden_attention_fp32
from .hardware_attention import fixed_point_flash_attention
from .hardware_config import FlashAttentionHardwareConfig
from .stats import ErrorMetrics, compute_error_metrics

__all__ = [
    "ErrorMetrics",
    "ExperimentConfig",
    "FixedFormat",
    "FlashAttentionHardwareConfig",
    "compute_error_metrics",
    "exp_pwl_fixed",
    "fixed_point_flash_attention",
    "generate_random_qkv",
    "golden_attention_fp32",
    "load_experiment_config",
]
