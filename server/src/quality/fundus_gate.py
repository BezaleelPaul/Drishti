"""
Fundus domain gate (Stage 2 of the AI safety pipeline).

Answers exactly one question before any quality metric or DR inference runs:

    Is this image actually a retinal/fundus photograph?

The gate is deliberately a replaceable interface (``FundusGate``) so that a
learned EFIQA/VISTA-style detector can be dropped in later behind the same
contract without touching the checker or the router.

Providers (env ``DRISHTI_FUNDUS_GATE``):
    heuristic  - default: colour + circular-field + orange-retina band checks
    legacy     - the original red/blue ratio + blank check only (rollback)
    off        - always passes (debugging only; never use for screening)
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Protocol, runtime_checkable

import numpy as np

ENV_PROVIDER = "DRISHTI_FUNDUS_GATE"
DEFAULT_PROVIDER = "heuristic"


class FundusVerdict(str, Enum):
    FUNDUS = "FUNDUS"
    NOT_FUNDUS = "NOT_FUNDUS"
    UNDETERMINED = "UNDETERMINED"


@dataclass(frozen=True)
class FundusDecision:
    verdict: FundusVerdict
    reason: str = ""
    signals: dict[str, float] = field(default_factory=dict)

    @property
    def is_fundus(self) -> bool:
        return self.verdict is not FundusVerdict.NOT_FUNDUS

    @property
    def is_deferred(self) -> bool:
        return self.verdict is FundusVerdict.UNDETERMINED

    @property
    def confidence(self) -> float:
        if self.verdict is FundusVerdict.UNDETERMINED:
            return 0.0
        score = float(self.signals.get("score", 0.0))
        return score if self.verdict is FundusVerdict.FUNDUS else round(1.0 - score, 4)


@dataclass
class FundusGateThresholds:
    min_size: int = 64
    min_variance: float = 2.0
    min_red_to_blue: float = 1.10
    min_ring_dark_frac: float = 0.40
    min_orange_band_frac: float = 0.45
    # Bright-normalized escape hatches, calibrated on 400 labeled EyePACS
    # images: real screening photos vary wildly in exposure, colour cast and
    # how much of the frame the retinal field occupies. A frame can still be
    # a fundus photo when the whole-image fraction is small but the LIT area
    # is retinal-coloured (tier 2), especially when the field is ringed by a
    # near-black surround (tier 3). Measured false-reject rate: 42% -> ~5%.
    min_orange_band_frac_bright: float = 0.85
    min_orange_band_frac_lit: float = 0.55
    min_orange_band_frac_lit_weak: float = 0.35
    min_ring_dark_frac_struct: float = 0.75
    max_corner_mean: float = 20.0
    min_bright_pixel_frac: float = 0.05
    ring_width_frac: float = 0.08
    ring_dark_luma: float = 60.0
    # Wrapped red-orange window: real fundus photographs sit in hue 330-360
    # (crimson) through 0-35 (orange). min > max means the window wraps past 0.
    orange_hue_min: float = 330.0
    orange_hue_max: float = 35.0
    orange_min_sat: float = 0.35
    defer_below_brightness: float = 20.0
    defer_above_brightness: float = 235.0

    def to_signals(self) -> dict[str, float]:
        return {
            "min_ring_dark_frac": self.min_ring_dark_frac,
            "min_orange_band_frac": self.min_orange_band_frac,
        }


@runtime_checkable
class FundusGate(Protocol):
    name: str

    def evaluate(
        self, img_rgb: np.ndarray, min_red_to_blue: float | None = None
    ) -> FundusDecision: ...


def _hue_saturation(img_rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    rgb = img_rgb.astype(np.float32)
    mx = rgb.max(axis=2)
    mn = rgb.min(axis=2)
    denom = mx - mn + 1e-6
    sat = np.where(mx > 0.0, (mx - mn) / (mx + 1e-6), 0.0)
    hue = np.zeros_like(mx)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    red_max = mx == r
    hue[red_max] = (60.0 * ((g[red_max] - b[red_max]) / denom[red_max])) % 360.0
    green_max = (mx == g) & ~red_max
    hue[green_max] = 60.0 * ((b[green_max] - r[green_max]) / denom[green_max]) + 120.0
    blue_max = (mx == b) & ~red_max & ~green_max
    hue[blue_max] = 60.0 * ((r[blue_max] - g[blue_max]) / denom[blue_max]) + 240.0
    return hue, sat


def compute_fundus_signals(img_rgb: np.ndarray, th: FundusGateThresholds) -> dict[str, float]:
    """Cheap, deterministic signals separating fundus photographs from ordinary photos."""
    h, w, _ = img_rgb.shape
    rgb = img_rgb.astype(np.float32)

    ring_w = max(4, int(th.ring_width_frac * min(h, w)))
    ring = np.concatenate(
        [
            rgb[:ring_w, :].reshape(-1, 3),
            rgb[-ring_w:, :].reshape(-1, 3),
            rgb[:, :ring_w].reshape(-1, 3),
            rgb[:, -ring_w:].reshape(-1, 3),
        ]
    )
    ring_luma = ring.mean(axis=1)
    ring_dark_frac = float(np.mean(ring_luma < th.ring_dark_luma))

    corner_h, corner_w = max(4, int(0.18 * h)), max(4, int(0.18 * w))
    corners = np.concatenate(
        [
            rgb[:corner_h, :corner_w].reshape(-1, 3),
            rgb[:corner_h, -corner_w:].reshape(-1, 3),
            rgb[-corner_h:, :corner_w].reshape(-1, 3),
            rgb[-corner_h:, -corner_w:].reshape(-1, 3),
        ]
    )
    center = rgb[int(0.3 * h) : int(0.7 * h), int(0.3 * w) : int(0.7 * w)].reshape(-1, 3)
    corner_mean = float(corners.mean())
    center_mean = float(center.mean())

    hue, sat = _hue_saturation(img_rgb)
    if th.orange_hue_min <= th.orange_hue_max:
        hue_in_band = (hue >= th.orange_hue_min) & (hue <= th.orange_hue_max)
    else:
        hue_in_band = (hue >= th.orange_hue_min) | (hue <= th.orange_hue_max)
    orange_band = hue_in_band & (sat >= th.orange_min_sat)
    orange_band_frac = float(np.mean(orange_band))

    luma = rgb.mean(axis=2)
    illuminated = luma > 30.0
    n_illuminated = int(illuminated.sum())
    min_illuminated = th.min_bright_pixel_frac * h * w
    if n_illuminated >= min_illuminated:
        orange_band_frac_bright = float((orange_band & illuminated).sum() / n_illuminated)
        soft_band = hue_in_band & (sat >= 0.20)
        orange_band_frac_lit = float((soft_band & illuminated).sum() / n_illuminated)
    else:
        orange_band_frac_bright = 0.0
        orange_band_frac_lit = 0.0

    mean_r = float(rgb[..., 0].mean())
    mean_b = float(rgb[..., 2].mean()) + 1e-5

    return {
        "ring_dark_frac": ring_dark_frac,
        "corner_mean": corner_mean,
        "center_mean": center_mean,
        "center_corner_ratio": center_mean / (corner_mean + 1e-6),
        "orange_band_frac": orange_band_frac,
        "orange_band_frac_bright": orange_band_frac_bright,
        "orange_band_frac_lit": orange_band_frac_lit,
        "mean_saturation": float(sat.mean()),
        "red_blue_ratio": mean_r / mean_b,
        "mean_brightness": float(rgb.mean()),
        "variance": float(rgb.var()),
    }


class LegacyColorFundusGate:
    """Original colour/variance gate, kept verbatim as a rollback provider."""

    name = "legacy"

    def __init__(self, thresholds: FundusGateThresholds | None = None):
        self.thresholds = thresholds or FundusGateThresholds()

    def evaluate(self, img_rgb: np.ndarray, min_red_to_blue: float | None = None) -> FundusDecision:
        th = self.thresholds
        if img_rgb.ndim != 3 or img_rgb.shape[2] != 3:
            return FundusDecision(FundusVerdict.NOT_FUNDUS, "Image is not a 3-channel RGB array")
        h, w, _ = img_rgb.shape
        if h < th.min_size or w < th.min_size:
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                f"Image dimensions too small ({w}x{h})",
                {"score": 0.0},
            )

        rgb = img_rgb.astype(np.float32)
        if (
            float(rgb[..., 0].std()) < th.min_variance
            and float(rgb[..., 1].std()) < th.min_variance
            and float(rgb[..., 2].std()) < th.min_variance
        ):
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                "Image has almost zero variance (blank or solid color)",
                {"score": 0.0},
            )

        limit = min_red_to_blue if min_red_to_blue is not None else th.min_red_to_blue
        ratio = float(rgb[..., 0].mean()) / (float(rgb[..., 2].mean()) + 1e-5)
        if ratio < limit:
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                f"Color profile does not match retinal fundus (Red/Blue ratio={ratio:.2f})",
                {"red_blue_ratio": ratio, "score": 0.0},
            )
        return FundusDecision(
            FundusVerdict.FUNDUS,
            "",
            {"red_blue_ratio": ratio, "score": 1.0},
        )


class HeuristicFundusGate:
    """Colour + circular retinal field + orange-retina band checks."""

    name = "heuristic"

    def __init__(self, thresholds: FundusGateThresholds | None = None):
        self.thresholds = thresholds or FundusGateThresholds()
        self._legacy = LegacyColorFundusGate(self.thresholds)

    def evaluate(self, img_rgb: np.ndarray, min_red_to_blue: float | None = None) -> FundusDecision:
        th = self.thresholds
        if img_rgb.ndim != 3 or img_rgb.shape[2] != 3:
            return FundusDecision(FundusVerdict.NOT_FUNDUS, "Image is not a 3-channel RGB array")
        h, w, _ = img_rgb.shape
        if h < th.min_size or w < th.min_size:
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                f"Image dimensions too small ({w}x{h})",
                {"score": 0.0},
            )
        rgb = img_rgb.astype(np.float32)
        if (
            float(rgb[..., 0].std()) < th.min_variance
            and float(rgb[..., 1].std()) < th.min_variance
            and float(rgb[..., 2].std()) < th.min_variance
        ):
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                "Image has almost zero variance (blank or solid color)",
                {"score": 0.0},
            )

        signals = compute_fundus_signals(img_rgb, th)
        brightness = signals["mean_brightness"]
        # Illumination failures are a quality problem, not a domain problem:
        # a real but too-dark/too-bright fundus defers to the quality gate
        # (INADEQUATE_ILLUMINATION / OVEREXPOSED) instead of being labelled
        # non-fundus.
        if brightness < th.defer_below_brightness or brightness > th.defer_above_brightness:
            signals["score"] = 0.0
            return FundusDecision(
                FundusVerdict.UNDETERMINED,
                "Illumination outside domain-gate range; deferring to quality gate",
                signals,
            )

        limit = min_red_to_blue if min_red_to_blue is not None else th.min_red_to_blue
        ratio = signals["red_blue_ratio"]
        if ratio < limit:
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                f"Color profile does not match retinal fundus (Red/Blue ratio={ratio:.2f})",
                {**signals, "score": 0.0},
            )

        band = signals["orange_band_frac"]
        band_bright = signals["orange_band_frac_bright"]
        band_lit = signals["orange_band_frac_lit"]
        ring = signals["ring_dark_frac"]
        corner = signals["corner_mean"]
        # Three tiers, calibrated on 400 labeled EyePACS images (FRR 42% -> ~5%)
        # while every non-fundus corpus fixture stays rejected:
        #   1. retinal colour dominates the whole frame, or
        #   2. retinal colour dominates the lit area, or
        #   3. lit area is weaker but the field has a near-black surround
        #      (the classic letterboxed screening capture), and still a dark ring.
        band_ok = (
            band >= th.min_orange_band_frac
            or band_bright >= th.min_orange_band_frac_bright
            or band_lit >= th.min_orange_band_frac_lit
            or (
                band_lit >= th.min_orange_band_frac_lit_weak
                and ring >= th.min_ring_dark_frac_struct
                and corner <= th.max_corner_mean
            )
        )
        band_ratio = max(
            band / max(th.min_orange_band_frac, 1e-6),
            band_bright / max(th.min_orange_band_frac_bright, 1e-6),
            band_lit / max(th.min_orange_band_frac_lit, 1e-6),
        )
        score = round(
            0.6 * min(band_ratio, 1.0) + 0.4 * min(ring / max(th.min_ring_dark_frac, 1e-6), 1.0),
            4,
        )
        signals["score"] = score

        if not band_ok:
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                "Saturated retinal-orange band absent "
                f"(frame={band:.2f} < {th.min_orange_band_frac:.2f}, "
                f"lit={band_bright:.2f} < {th.min_orange_band_frac_bright:.2f}, "
                f"lit_soft={band_lit:.2f} < {th.min_orange_band_frac_lit:.2f})",
                signals,
            )
        if ring < th.min_ring_dark_frac:
            return FundusDecision(
                FundusVerdict.NOT_FUNDUS,
                "Circular retinal field with dark border not detected "
                f"({ring:.2f} < {th.min_ring_dark_frac:.2f})",
                signals,
            )
        return FundusDecision(FundusVerdict.FUNDUS, "", signals)


class PermissiveFundusGate:
    """Always passes. Debug/evaluation only."""

    name = "off"

    def evaluate(self, img_rgb: np.ndarray, min_red_to_blue: float | None = None) -> FundusDecision:
        return FundusDecision(FundusVerdict.FUNDUS, "", {"score": 1.0})


_PROVIDERS: dict[str, type] = {
    "heuristic": HeuristicFundusGate,
    "legacy": LegacyColorFundusGate,
    "off": PermissiveFundusGate,
}


def build_fundus_gate(provider: str | None = None, **kwargs) -> FundusGate:
    key = (provider or os.environ.get(ENV_PROVIDER) or DEFAULT_PROVIDER).strip().lower()
    gate_cls = _PROVIDERS.get(key)
    if gate_cls is None:
        raise ValueError(f"Unknown fundus gate provider '{key}'. Valid: {sorted(_PROVIDERS)}")
    return gate_cls(**kwargs)
