from __future__ import annotations

import math

from .fixed_format import FixedFormat


def sat(value: int, fmt: FixedFormat) -> int:
    """Saturate a raw integer to the representable range of ``fmt``."""

    return min(max(int(value), fmt.min_int), fmt.max_int)


def clip_or_assert(value: int, fmt: FixedFormat, saturate: bool = True) -> int:
    """Saturate or assert that ``value`` is representable by ``fmt``."""

    value = int(value)
    if saturate:
        return sat(value, fmt)
    if value < fmt.min_int or value > fmt.max_int:
        raise OverflowError(f"{value} is outside {fmt.name} range")
    return value


def round_shift_right_signed(value: int, sh: int) -> int:
    """Arithmetic right shift with symmetric round-to-nearest."""

    if sh < 0:
        raise ValueError("shift must be non-negative")
    if sh == 0:
        return int(value)
    half = 1 << (sh - 1)
    if value >= 0:
        return (int(value) + half) >> sh
    return -(((-int(value)) + half) >> sh)


def round_shift_right_unsigned(value: int, sh: int) -> int:
    """Logical right shift with round-to-nearest for a non-negative integer."""

    if sh < 0:
        raise ValueError("shift must be non-negative")
    if value < 0:
        raise ValueError("unsigned shift received a negative value")
    if sh == 0:
        return int(value)
    half = 1 << (sh - 1)
    return (int(value) + half) >> sh


def _round_float_symmetric(value: float) -> int:
    if value >= 0.0:
        return int(math.floor(value + 0.5))
    return -int(math.floor(-value + 0.5))


def quantize_float_to_fixed(value: float, fmt: FixedFormat) -> int:
    """Quantize a float to a saturated raw fixed-point integer."""

    return sat(_round_float_symmetric(float(value) * fmt.scale), fmt)


def dequantize_fixed_to_float(value: int, fmt: FixedFormat) -> float:
    """Convert a raw fixed-point integer into a float."""

    clip_or_assert(value, fmt, saturate=False)
    return int(value) / float(fmt.scale)


def align_fixed(value: int, src_frac_bits: int, out_fmt: FixedFormat) -> int:
    """Convert a raw fixed-point value to ``out_fmt`` by changing frac bits."""

    shift = int(src_frac_bits) - out_fmt.frac_bits
    if shift > 0:
        if out_fmt.signed:
            value = round_shift_right_signed(value, shift)
        else:
            value = round_shift_right_unsigned(value, shift)
    elif shift < 0:
        value = int(value) << (-shift)
    return sat(value, out_fmt)


def add_fixed(a: int, b: int, out_fmt: FixedFormat, saturate: bool = True) -> int:
    """Add two raw fixed-point integers and clip to ``out_fmt``."""

    return clip_or_assert(int(a) + int(b), out_fmt, saturate=saturate)


def sub_fixed(a: int, b: int, out_fmt: FixedFormat, saturate: bool = True) -> int:
    """Subtract two raw fixed-point integers and clip to ``out_fmt``."""

    return clip_or_assert(int(a) - int(b), out_fmt, saturate=saturate)
