from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class FixedFormat:
    """Description of a signed or unsigned fixed-point integer format."""

    name: str
    signed: bool
    total_bits: int
    frac_bits: int

    def __post_init__(self) -> None:
        if self.total_bits <= 0:
            raise ValueError("total_bits must be positive")
        if self.frac_bits < 0:
            raise ValueError("frac_bits must be non-negative")
        if self.frac_bits > self.total_bits:
            raise ValueError("frac_bits cannot exceed total_bits")

    @property
    def int_bits(self) -> int:
        """Number of integer bits, including the sign bit for signed formats."""

        return self.total_bits - self.frac_bits

    @property
    def min_int(self) -> int:
        """Minimum representable raw integer."""

        if self.signed:
            return -(1 << (self.total_bits - 1))
        return 0

    @property
    def max_int(self) -> int:
        """Maximum representable raw integer."""

        if self.signed:
            return (1 << (self.total_bits - 1)) - 1
        return (1 << self.total_bits) - 1

    @property
    def scale(self) -> int:
        """Fixed-point scale factor."""

        return 1 << self.frac_bits

    def label(self) -> str:
        """Return a human-readable label such as signed Q8.8 or UQ1.23."""

        prefix = "signed Q" if self.signed else "UQ"
        return f"{prefix}{self.int_bits}.{self.frac_bits}"

    def to_dict(self) -> dict[str, int | bool | str]:
        """Serialize this format for JSON debug logs."""

        return {
            "name": self.name,
            "signed": self.signed,
            "total_bits": self.total_bits,
            "frac_bits": self.frac_bits,
            "int_bits": self.int_bits,
            "min_int": self.min_int,
            "max_int": self.max_int,
            "label": self.label(),
        }


Q8_8 = FixedFormat("Q8.8", signed=True, total_bits=16, frac_bits=8)
Q16_16 = FixedFormat("Q16.16", signed=True, total_bits=32, frac_bits=16)
Q22_16 = FixedFormat("Q22.16", signed=True, total_bits=38, frac_bits=16)
Q2_16 = FixedFormat("Q2.16", signed=True, total_bits=18, frac_bits=16)
UQ1_23 = FixedFormat("UQ1.23", signed=False, total_bits=24, frac_bits=23)
UQ5_23 = FixedFormat("UQ5.23", signed=False, total_bits=28, frac_bits=23)
UQ9_23 = FixedFormat("UQ9.23", signed=False, total_bits=32, frac_bits=23)
Q12_23 = FixedFormat("Q12.23", signed=True, total_bits=35, frac_bits=23)
Q16_23 = FixedFormat("Q16.23", signed=True, total_bits=39, frac_bits=23)
