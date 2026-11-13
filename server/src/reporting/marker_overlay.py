"""Diagnostic Lesion and Landmark Marker Visualizer.

Provides high-clarity anatomical landmark overlays, ETDRS concentric macular grids,
and color-coded lesion indicators (microaneurysms, hard exudates, CSME risk zones)
for rapid (<30 second) ophthalmologist tele-review and hospital PDF dossiers.
"""
from __future__ import annotations

import logging
import math
import os
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from src.image_io import to_rgb_uint8
from src.segmentation.structure_segmenter import (
    RetinalStructuresResult,
    RetinalStructureSegmenter,
)
from src.services.csme_engine import CSMERiskLevel, CSMERiskResult, CSMEGeometricEngine

try:
    import cv2
    HAS_OPENCV = True
except ImportError:
    HAS_OPENCV = False

logger = logging.getLogger(__name__)


class RetinalMarkerVisualizer:
    """Renders calibrated clinical annotations onto fundus photographs."""

    def __init__(
        self,
        segmenter: RetinalStructureSegmenter | None = None,
        csme_engine: CSMEGeometricEngine | None = None,
    ):
        self.segmenter = segmenter or RetinalStructureSegmenter()
        self.csme_engine = csme_engine or CSMEGeometricEngine(segmenter=self.segmenter)

    def draw_diagnostic_overlay(
        self,
        image_input: str | np.ndarray | Image.Image,
        landmarks: RetinalStructuresResult | None = None,
        csme_result: CSMERiskResult | None = None,
        show_vessels: bool = True,
        show_optic_disc: bool = True,
        show_fovea: bool = True,
        show_etdrs_grid: bool = True,
        show_lesions: bool = True,
        show_hud: bool = True,
    ) -> np.ndarray:
        """Draws comprehensive diagnostic markings onto the retinal photograph.

        Returns:
            uint8 RGB numpy array with clinical overlays.
        """
        rgb_img = self._load_rgb(image_input)
        h, w, _ = rgb_img.shape

        # Extract landmarks if not provided
        structs = landmarks or self.segmenter.segment_structures(rgb_img)

        # Extract CSME risk if not provided
        csme = csme_result or self.csme_engine.evaluate(rgb_img, landmarks=structs)

        if HAS_OPENCV:
            return self._draw_opencv(
                rgb_img=rgb_img,
                structs=structs,
                csme=csme,
                show_vessels=show_vessels,
                show_optic_disc=show_optic_disc,
                show_fovea=show_fovea,
                show_etdrs_grid=show_etdrs_grid,
                show_lesions=show_lesions,
                show_hud=show_hud,
            )
        else:
            return self._draw_pil(
                rgb_img=rgb_img,
                structs=structs,
                csme=csme,
                show_vessels=show_vessels,
                show_optic_disc=show_optic_disc,
                show_fovea=show_fovea,
                show_etdrs_grid=show_etdrs_grid,
                show_lesions=show_lesions,
                show_hud=show_hud,
            )

    def save_diagnostic_overlay(
        self,
        image_input: str | np.ndarray | Image.Image,
        save_path: str,
        landmarks: RetinalStructuresResult | None = None,
        csme_result: CSMERiskResult | None = None,
        **kwargs: Any,
    ) -> str:
        """Renders and saves the diagnostic overlay to a file path."""
        overlay = self.draw_diagnostic_overlay(
            image_input=image_input,
            landmarks=landmarks,
            csme_result=csme_result,
            **kwargs,
        )
        os.makedirs(os.path.dirname(os.path.abspath(save_path)), exist_ok=True)
        Image.fromarray(overlay).save(save_path, quality=95)
        return save_path

    def _draw_opencv(
        self,
        rgb_img: np.ndarray,
        structs: RetinalStructuresResult,
        csme: CSMERiskResult,
        show_vessels: bool,
        show_optic_disc: bool,
        show_fovea: bool,
        show_etdrs_grid: bool,
        show_lesions: bool,
        show_hud: bool,
    ) -> np.ndarray:
        overlay = rgb_img.copy()
        h, w = overlay.shape[:2]

        od_x, od_y = structs.optic_disc_center
        od_r = max(int(structs.optic_disc_radius), 8)
        fx, fy = structs.fovea_center
        dd_px = float(2.0 * od_r)

        # 1. Subtle vessel tree tint
        if show_vessels and structs.vessel_mask is not None:
            v_mask = structs.vessel_mask == 255
            overlay[v_mask, 0] = np.uint8(np.clip(overlay[v_mask, 0] * 0.45 + 30, 0, 255))
            overlay[v_mask, 1] = np.uint8(np.clip(overlay[v_mask, 1] * 0.55 + 170, 0, 255))
            overlay[v_mask, 2] = np.uint8(np.clip(overlay[v_mask, 2] * 0.55 + 220, 0, 255))

        # 2. Optic Disc boundary
        if show_optic_disc and od_x > 0 and od_y > 0:
            cv2.circle(overlay, (od_x, od_y), od_r, (255, 220, 0), 2, cv2.LINE_AA)
            cv2.putText(
                overlay,
                f"OD (D={int(dd_px)}px)",
                (od_x - 45, max(od_y - od_r - 8, 20)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.45,
                (255, 220, 0),
                1,
                cv2.LINE_AA,
            )

        # 3. ETDRS Macular Grid (concentric circles around fovea)
        if show_etdrs_grid and fx > 0 and fy > 0:
            grid_canvas = overlay.copy()
            # ETDRS Inner Zone: 0.5 DD (High CSME Risk) - Bright Coral Red
            r_05 = int(0.5 * dd_px)
            # ETDRS Intermediate Zone: 1.0 DD (Moderate Risk) - Orange
            r_10 = int(1.0 * dd_px)
            # ETDRS Outer Zone: 1.5 DD (Borderline/Safe Zone) - Cyan
            r_15 = int(1.5 * dd_px)

            cv2.circle(grid_canvas, (fx, fy), r_05, (255, 50, 50), 1, cv2.LINE_AA)
            cv2.circle(grid_canvas, (fx, fy), r_10, (255, 165, 0), 1, cv2.LINE_AA)
            cv2.circle(grid_canvas, (fx, fy), r_15, (0, 215, 255), 1, cv2.LINE_AA)

            # Blend grid lines smoothly
            cv2.addWeighted(grid_canvas, 0.85, overlay, 0.15, 0, overlay)

        # 4. Fovea Center crosshair
        if show_fovea and fx > 0 and fy > 0:
            cv2.drawMarker(overlay, (fx, fy), (0, 190, 255), cv2.MARKER_CROSS, 22, 2, cv2.LINE_AA)
            cv2.circle(overlay, (fx, fy), 14, (0, 190, 255), 1, cv2.LINE_AA)
            cv2.putText(
                overlay,
                "Fovea",
                (fx - 20, max(fy - 20, 20)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.45,
                (0, 190, 255),
                1,
                cv2.LINE_AA,
            )

        # 5. Lesion Markers (Microaneurysms + Exudates)
        if show_lesions:
            # Microaneurysms: small red circles
            for cx, cy, cr in structs.microaneurysm_candidates:
                cv2.circle(overlay, (cx, cy), max(cr + 2, 4), (255, 30, 30), 1, cv2.LINE_AA)

            # Exudate clusters from CSME result
            for cluster in csme.candidate_clusters:
                cx, cy = cluster.center
                # Color based on CSME zone
                if cluster.distance_in_disc_diameters <= 0.5:
                    clr = (255, 20, 20)  # High Risk CSME (Within 0.5 DD)
                elif cluster.distance_in_disc_diameters <= 1.5:
                    clr = (255, 140, 0)  # Moderate Risk (0.5 to 1.5 DD)
                else:
                    clr = (255, 240, 40)  # Safe / Extramacular (> 1.5 DD)

                radius = max(int(math.sqrt(cluster.area / math.pi)) + 3, 5)
                cv2.circle(overlay, (cx, cy), radius, clr, 2, cv2.LINE_AA)

        # 6. Clinical Tele-Review HUD / Legend Banner
        if show_hud:
            hud_h = 56
            hud_bg = overlay.copy()
            cv2.rectangle(hud_bg, (0, h - hud_h), (w, h), (15, 23, 42), -1)
            cv2.addWeighted(hud_bg, 0.75, overlay, 0.25, 0, overlay)

            # HUD text
            csme_tag = csme.risk_level.value
            csme_color = (
                (255, 60, 60)
                if csme.urgent_referral
                else (255, 180, 50)
                if csme.risk_level == CSMERiskLevel.MODERATE_RISK
                else (80, 220, 120)
            )

            cv2.putText(
                overlay,
                f"CSME RISK: {csme_tag}",
                (14, h - 34),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.48,
                csme_color,
                1,
                cv2.LINE_AA,
            )

            nearest_str = (
                f"{csme.nearest_exudate_dd:.2f} DD"
                if csme.nearest_exudate_dd is not None
                else "None in zone"
            )
            sub_info = (
                f"Nearest Exudate: {nearest_str}  |  "
                f"Exudates: {csme.exudates_detected_count}  |  "
                f"MA candidates: {len(structs.microaneurysm_candidates)}  |  "
                f"Vessels: {structs.vessel_density_pct:.1f}%"
            )
            cv2.putText(
                overlay,
                sub_info,
                (14, h - 14),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.38,
                (220, 225, 235),
                1,
                cv2.LINE_AA,
            )

        return overlay

    def _draw_pil(
        self,
        rgb_img: np.ndarray,
        structs: RetinalStructuresResult,
        csme: CSMERiskResult,
        show_vessels: bool,
        show_optic_disc: bool,
        show_fovea: bool,
        show_etdrs_grid: bool,
        show_lesions: bool,
        show_hud: bool,
    ) -> np.ndarray:
        """Pure-PIL fallback when OpenCV is not installed."""
        pil_img = Image.fromarray(rgb_img).convert("RGBA")
        draw = ImageDraw.Draw(pil_img)
        w, h = pil_img.size

        od_x, od_y = structs.optic_disc_center
        od_r = max(int(structs.optic_disc_radius), 8)
        fx, fy = structs.fovea_center
        dd_px = float(2.0 * od_r)

        if show_optic_disc and od_x > 0 and od_y > 0:
            draw.ellipse(
                [(od_x - od_r, od_y - od_r), (od_x + od_r, od_y + od_r)],
                outline=(255, 220, 0, 255),
                width=2,
            )

        if show_etdrs_grid and fx > 0 and fy > 0:
            for mult, clr in [(0.5, (255, 50, 50, 200)), (1.0, (255, 165, 0, 200)), (1.5, (0, 215, 255, 200))]:
                r = int(mult * dd_px)
                draw.ellipse([(fx - r, fy - r), (fx + r, fy + r)], outline=clr, width=1)

        if show_fovea and fx > 0 and fy > 0:
            draw.line([(fx - 12, fy), (fx + 12, fy)], fill=(0, 190, 255, 255), width=2)
            draw.line([(fx, fy - 12), (fx, fy + 12)], fill=(0, 190, 255, 255), width=2)

        if show_lesions:
            for cx, cy, cr in structs.microaneurysm_candidates:
                r = max(cr + 2, 4)
                draw.ellipse([(cx - r, cy - r), (cx + r, cy + r)], outline=(255, 30, 30, 255), width=1)

        return np.array(pil_img.convert("RGB"))

    def _load_rgb(self, image_input: str | np.ndarray | Image.Image) -> np.ndarray:
        if isinstance(image_input, str):
            return to_rgb_uint8(np.array(Image.open(image_input).convert("RGB")))
        elif isinstance(image_input, Image.Image):
            return to_rgb_uint8(np.array(image_input.convert("RGB")))
        elif isinstance(image_input, np.ndarray):
            return to_rgb_uint8(image_input)
        raise TypeError(f"Unsupported image input type: {type(image_input)}")
