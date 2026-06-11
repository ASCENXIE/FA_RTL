from flash_attn_fixed.fixed_format import FixedFormat, Q8_8, UQ1_23
from flash_attn_fixed.fixed_ops import (
    dequantize_fixed_to_float,
    quantize_float_to_fixed,
    round_shift_right_signed,
    round_shift_right_unsigned,
    sat,
)


def test_signed_saturation() -> None:
    assert sat(Q8_8.max_int + 1, Q8_8) == Q8_8.max_int
    assert sat(Q8_8.min_int - 1, Q8_8) == Q8_8.min_int
    assert sat(123, Q8_8) == 123


def test_unsigned_saturation() -> None:
    assert sat(-1, UQ1_23) == 0
    assert sat(UQ1_23.max_int + 1, UQ1_23) == UQ1_23.max_int


def test_round_shift_right_signed() -> None:
    assert round_shift_right_signed(7, 2) == 2
    assert round_shift_right_signed(-7, 2) == -2
    assert round_shift_right_signed(8, 2) == 2
    assert round_shift_right_signed(-8, 2) == -2


def test_round_shift_right_unsigned() -> None:
    assert round_shift_right_unsigned(7, 2) == 2
    assert round_shift_right_unsigned(8, 2) == 2
    assert round_shift_right_unsigned(9, 2) == 2
    assert round_shift_right_unsigned(10, 2) == 3


def test_float_quant_dequant() -> None:
    raw = quantize_float_to_fixed(1.5, Q8_8)
    assert raw == 384
    assert dequantize_fixed_to_float(raw, Q8_8) == 1.5


def test_q8_8_boundaries() -> None:
    assert Q8_8.min_int == -32768
    assert Q8_8.max_int == 32767
    assert dequantize_fixed_to_float(Q8_8.min_int, Q8_8) == -128.0
    assert dequantize_fixed_to_float(Q8_8.max_int, Q8_8) == 127.99609375


def test_custom_format_int_bits() -> None:
    fmt = FixedFormat("Q22.16", signed=True, total_bits=38, frac_bits=16)
    assert fmt.int_bits == 22
    assert fmt.label() == "signed Q22.16"
