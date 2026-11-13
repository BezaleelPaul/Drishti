"""Clinically Significant Macular Edema (CSME) Geometric Risk Engine.

Evaluates foveal proximity of hard exudates and lipid deposits in standard
Optic Disc Diameters (DD) based on Early Treatment Diabetic Retinopathy Study (ETDRS) rules:
- High Risk CSME: Hard exudates within 0.5 DD (1.0 x R_od) of foveal center.
- Moderate CSME: Hard exudates between 0.5 DD and 1.5 DD (1.0 to 3.0 x R_od) of foveal center.
- Macular Safe: Lesions present, but outside 1.5 DD (> 3.0 x R_od) from fovea.
- No CSME: No bright exudative lesions detected.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
import math
import numpy as np
from PIL import Image

from src.image_io import to_rgb_uint8
from src.segmentation.structure_segmenter import (
    RetinalStructureSegmenter,
    RetinalStructuresResult,
)


class CSMERiskLevel(str, Enum):
    NO_CSME = "NO_CSME"
    MACULAR_SAFE = "MACULAR_SAFE"
    MODERATE_RISK = "MODERATE_RISK"
    HIGH_RISK_URGENT = "HIGH_RISK_URGENT"


@dataclass
class ExudateCluster:
    center: tuple[int, int]
    area: int
    distance_to_fovea_px: float
    distance_in_disc_diameters: float


@dataclass
class CSMERiskResult:
    risk_level: CSMERiskLevel
    urgent_referral: bool
    nearest_exudate_dd: float | None
    exudates_detected_count: int
    fovea_center: tuple[int, int] | None
    optic_disc_diameter_px: float | None
    candidate_clusters: list[ExudateCluster] = field(default_factory=list)
    clinical_rationale: str = ""


class CSMEGeometricEngine:
    """Computes geometric macular zone rules from segmented anatomical landmarks and bright lesions."""

    def __init__(self, segmenter: RetinalStructureSegmenter | None = None):
        self.segmenter = segmenter or RetinalStructureSegmenter()

    def evaluate(
        self,
        image_input: str | np.ndarray | Image.Image,
        landmarks: RetinalStructuresResult | None = None,
    ) -> CSMERiskResult:
        if isinstance(image_input, (str, Image.Image)):
            arr = to_rgb_uint8(np.array(Image.open(image_input) if isinstance(image_input, str) else image_input))
        else:
            arr = to_rgb_uint8(image_input)

        # 1. Obtain anatomical landmarks
        structs = landmarks or self.segmenter.segment_structures(arr)
        fovea_x, fovea_y = structs.fovea_center
        od_r = structs.optic_disc_radius

        # Disc diameter in pixels
        dd_px = max(2.0 * od_r, 10.0)

        # Fallback if landmarks missing
        if fovea_x <= 0 or fovea_y <= 0 or od_r <= 0:
            return CSMERiskResult(
                risk_level=CSMERiskLevel.NO_CSME,
                urgent_referral=False,
                nearest_exudate_dd=None,
                exudates_detected_count=0,
                fovea_center=None,
                optic_disc_diameter_px=None,
                clinical_rationale="Anatomical landmarks (fovea/disc) not resolved with sufficient confidence.",
            )

        # 2. Extract candidate bright lesions
        clusters = self._extract_exudate_clusters(arr, structs, (fovea_x, fovea_y), dd_px)

        if not clusters:
            return CSMERiskResult(
                risk_level=CSMERiskLevel.NO_CSME,
                urgent_referral=False,
                nearest_exudate_dd=None,
                exudates_detected_count=0,
                fovea_center=(fovea_x, fovea_y),
                optic_disc_diameter_px=dd_px,
                clinical_rationale="No exudative deposits detected in macular or perimacular zones.",
            )

        # Find closest cluster to fovea
        clusters.sort(key=lambda c: c.distance_in_disc_diameters)
        closest = clusters[0]
        min_dd = closest.distance_in_disc_diameters

        # 3. Apply ETDRS geometric proximity rules
        if min_dd <= 0.5:
            risk = CSMERiskLevel.HIGH_RISK_URGENT
            urgent = True
            rationale = (
                f"Sight-threatening CSME detected: Exudate cluster identified at {min_dd:.2f} DD "
                f"from foveal center (critical macular zone <= 0.5 DD). Urgent anti-VEGF / laser referral required."
            )
        elif min_dd <= 1.5:
            risk = CSMERiskLevel.MODERATE_RISK
            urgent = True
            rationale = (
                f"Perimacular CSME risk: Exudate cluster identified at {min_dd:.2f} DD "
                f"from foveal center (threatened zone <= 1.5 DD). Requires specialist macular assessment."
            )
        else:
            risk = CSMERiskLevel.MACULAR_SAFE
            urgent = False
            rationale = (
                f"Hard exudates detected outside macular zone ({min_dd:.2f} DD from fovea). "
                "Routine diabetic retinopathy followup recommended."
            )

        return CSMERiskResult(
            risk_level=risk,
            urgent_referral=urgent,
            nearest_exudate_dd=float(round(min_dd, 2)),
            exudates_detected_count=len(clusters),
            fovea_center=(fovea_x, fovea_y),
            optic_disc_diameter_px=float(round(dd_px, 1)),
            candidate_clusters=clusters,
            clinical_rationale=rationale,
        )

    def _extract_exudate_clusters(
        self,
        arr: np.ndarray,
        structs: RetinalStructuresResult,
        fovea: tuple[int, int],
        dd_px: float,
    ) -> list[ExudateCluster]:
        """Extracts localized exudate clusters using the segmented exudate mask or color thresholding."""
        import cv2

        ex_mask = structs.exudate_mask
        if ex_mask is None or np.count_nonzero(ex_mask) == 0:
            # Fall back to segmenting if not provided in structs
            from src.image_io import retinal_mask as _retinal_mask
            from src.image_io import rgb_to_gray as _to_gray

            gray = cv2.cvtColor(arr, cv2.COLOR_RGB2GRAY) if cv2 else _to_gray(arr).astype(np.uint8)
            ret_mask = _retinal_mask(gray).astype(np.uint8) * 255
            ex_mask = self.segmenter._segment_exudates(
                arr, structs.optic_disc_center, structs.optic_disc_radius, ret_mask
            )

        if ex_mask is None or np.count_nonzero(ex_mask) == 0:
            return []

        contours, _ = cv2.findContours(ex_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        fx, fy = fovea

        clusters = []
        for cnt in contours:
            area = cv2.contourArea(cnt)
            if area >= 3:  # Valid lesion area threshold
                M = cv2.moments(cnt)
                if M["m00"] > 0:
                    cx = int(M["m10"] / M["m00"])
                    cy = int(M["m01"] / M["m00"])
                    dist_px = math.hypot(cx - fx, cy - fy)
                    dist_dd = dist_px / dd_px
                    clusters.append(
                        ExudateCluster(
                            center=(cx, cy),
                            area=int(area),
                            distance_to_fovea_px=float(round(dist_px, 1)),
                            distance_in_disc_diameters=float(round(dist_dd, 2)),
                        )
                    )
        return clusters
