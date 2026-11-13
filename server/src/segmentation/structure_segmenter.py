from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field

import numpy as np

_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_TOOLBOX_PATH = os.path.join(_PROJECT_ROOT, "external", "fundus_image_toolbox")
if os.path.exists(_TOOLBOX_PATH) and _TOOLBOX_PATH not in sys.path:
    sys.path.insert(0, _TOOLBOX_PATH)

try:
    import cv2
    HAS_OPENCV = True
except ImportError:
    HAS_OPENCV = False


@dataclass
class RetinalStructuresResult:
    optic_disc_center: tuple[int, int]           # (x, y) coordinates
    optic_disc_radius: int
    fovea_center: tuple[int, int]                # (x, y) coordinates
    vessel_mask: np.ndarray                      # 2D binary uint8 mask (255 for vessel, 0 background)
    microaneurysm_candidates: list[tuple[int, int, int]] = field(default_factory=list) # (x, y, radius)
    exudate_mask: np.ndarray | None = None    # 2D binary uint8 mask of bright lesions
    annotated_overlay: np.ndarray | None = None # RGB image with clinical annotations
    vessel_density_pct: float = 0.0              # % of retinal area occupied by vessels (1-decimal display)
    vessel_density_raw: float = 0.0            # unrounded density for gate comparisons (avoids 0.751->0.8 flips)
    min_fovea_distance_px: float | None = None  # distance from closest lesion to fovea center; None if no lesions (healthy)
    csme_risk: str = "LOW"                       # Clinically Significant Macular Edema risk


class RetinalStructureSegmenter:
    """
    MathWorks SIH26038 Requirement #2:
    Retinal Structure Segmentation and Clinical Landmark Extraction:
    - Optic Disc (OD) & Fovea localization
    - Blood vessel tree segmentation
    - Microaneurysm candidates (sub-pixel top-hat morphology)
    - Exudate candidate segmentation
    - Combined annotated overlay for <30s ophthalmologist validation.
    """

    def __init__(self, use_dl_toolbox: bool = True):
        self.use_dl_toolbox = use_dl_toolbox
        self._fovea_od_dl_model = None

        if self.use_dl_toolbox:
            self._try_load_dl_models()

    def _try_load_dl_models(self):
        try:
            import fundus_image_toolbox as fit
            self._fovea_od_dl_model, _ = fit.load_fovea_od_model(device="cpu")
        except Exception:  # noqa: BLE001 - optional toolbox model uses geometric fallback
            self._fovea_od_dl_model = None

    def segment_structures(self, img_rgb: np.ndarray) -> RetinalStructuresResult:
        """
        Extracts all anatomical landmarks, vessels, and lesion candidates.
        Accepts HxWx3 RGB; 2D grayscale is expanded to 3 channels.
        """
        if not isinstance(img_rgb, np.ndarray) or img_rgb.size == 0:
            raise ValueError(f"segment_structures requires a non-empty numpy array, got {type(img_rgb)}.")
        from src.image_io import to_rgb_uint8 as _to_rgb
        img_rgb = _to_rgb(img_rgb)  # normalize dtype/range/channels like every other stage
        # _to_rgb always returns HxWx3 uint8: the 2-D branch below is dead.
        if img_rgb.ndim != 3 or img_rgb.shape[2] != 3:
            raise ValueError(f"segment_structures requires HxWx3 RGB, got shape {img_rgb.shape}.")
        h, w, _ = img_rgb.shape
        if min(h, w) < 3:
            raise ValueError(f"segment_structures requires min dimension >= 3px, got {h}x{w}.")
        green = img_rgb[:, :, 1].astype(np.float32)
        from src.image_io import rgb_to_gray as _to_gray
        # Shared luma (NOT mean): matches the router reassessment denominator.
        gray = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2GRAY) if HAS_OPENCV else _to_gray(img_rgb).astype(np.uint8)
        from src.image_io import retinal_mask as _retinal_mask
        retinal_mask = _retinal_mask(gray).astype(np.uint8) * 255

        # 1. Optic Disc and Fovea Localization
        od_center, od_radius, fovea_center = self._localize_od_and_fovea(img_rgb, green, retinal_mask)

        # 2. Blood Vessel Tree Segmentation
        vessel_mask = self._segment_vessels(green, retinal_mask)

        # 3. Exudate Candidate Segmentation (Bright yellow lesions outside optic disc)
        exudate_mask = self._segment_exudates(img_rgb, od_center, od_radius, retinal_mask)

        # 4. Microaneurysm Candidate Detection (Small dark red dots in green channel)
        ma_candidates = self._detect_microaneurysm_candidates(green, vessel_mask, retinal_mask)

        # 5. Composite Annotated Clinical Overlay (<30s specialist review)
        annotated_overlay = self._create_annotated_overlay(
            img_rgb, od_center, od_radius, fovea_center, vessel_mask, exudate_mask, ma_candidates
        )

        # 6. Quantitative Biomarkers & CSME / Macular Edema Risk
        retinal_pixels = max(int(np.count_nonzero(retinal_mask)), 1)
        vessel_pixels = int(np.count_nonzero(vessel_mask))
        vessel_density = float((vessel_pixels / retinal_pixels) * 100.0)

        # Compute minimum lesion distance to fovea center
        fx, fy = fovea_center
        min_dist = 999.0
        for cx, cy, _ in ma_candidates:
            d = float(np.sqrt((cx - fx) ** 2 + (cy - fy) ** 2))
            min_dist = min(min_dist, d)

        # Check exudates if any
        if exudate_mask is not None and HAS_OPENCV:
            ex_pts = np.argwhere(exudate_mask == 255)
            if len(ex_pts) > 0:
                # ex_pts is (y, x)
                dists = np.sqrt((ex_pts[:, 1] - fx) ** 2 + (ex_pts[:, 0] - fy) ** 2)
                min_ex_dist = float(np.min(dists))
                min_dist = min(min_dist, min_ex_dist)

        # CSME Risk: Macular encroachment within 1.5x OD radius (~500-1500 microns)
        has_lesions = (len(ma_candidates) > 0) or (exudate_mask is not None and bool(np.count_nonzero(exudate_mask) > 0))
        if has_lesions and min_dist < od_radius * 1.5:
            csme_risk = "HIGH (Macular Zone Encroached)"
        elif has_lesions and min_dist < od_radius * 2.5:
            csme_risk = "MODERATE (Paramacular Lesions)"
        else:
            csme_risk = "LOW (Extramacular)"

        return RetinalStructuresResult(
            optic_disc_center=od_center,
            optic_disc_radius=od_radius,
            fovea_center=fovea_center,
            vessel_mask=vessel_mask,
            microaneurysm_candidates=ma_candidates,
            exudate_mask=exudate_mask,
            annotated_overlay=annotated_overlay,
            vessel_density_pct=round(vessel_density, 1),
            vessel_density_raw=vessel_density,
            min_fovea_distance_px=round(min_dist, 1) if min_dist < 999.0 else None,
            csme_risk=csme_risk,
        )

    def _localize_od_and_fovea(
        self, img_rgb: np.ndarray, green: np.float32, retinal_mask: np.ndarray
    ) -> tuple[tuple[int, int], int, tuple[int, int]]:
        h, w, _ = img_rgb.shape
        cy, cx = h // 2, w // 2
        approx_radius = max(2, int(min(h, w) * 0.08))

        # 1. Try deep learning model from toolbox
        if self._fovea_od_dl_model is not None:
            try:
                coords = self._fovea_od_dl_model.predict([img_rgb])[0] # [fovea_x, fovea_y, od_x, od_y]
                fx, fy, od_x, od_y = int(coords[0]), int(coords[1]), int(coords[2]), int(coords[3])
                return (od_x, od_y), approx_radius, (fx, fy)
            except Exception as exc:  # noqa: BLE001 - invalid model output uses fallback
                import logging
                logging.getLogger(__name__).debug("Fovea/optic-disc model failed: %s", exc)

        # 2. Robust morphological fallback
        if HAS_OPENCV:
            # Optic disc has high red + green intensity (yellowish bright area)
            red = img_rgb[:, :, 0].astype(np.float32)
            intensity = (red * 0.6 + green * 0.4)
            # Smooth with large Gaussian to find global bright region.
            # Bound kernel to image size to avoid cv2.error on small images.
            min_dim = min(h, w)
            ks = min(45, max(3, ((min_dim // 8) | 1)))
            if ks > min_dim:
                ks = min_dim if (min_dim % 2 == 1) else max(3, min_dim - 1)
            if ks % 2 != 1:
                ks = ks + 1 if ks % 2 == 0 else ks  # Ensure odd kernel size
            ks = max(3, ks)
            blurred = cv2.GaussianBlur(intensity, (ks, ks), 0)
            blurred[retinal_mask == 0] = 0
            
            # Find brightest centroid
            _, _, _, max_l = cv2.minMaxLoc(blurred)
            od_x, od_y = int(max_l[0]), int(max_l[1])

            # Fovea is roughly 2.5 disc diameters temporal to optic disc
            # If OD is on left half of retina, fovea is to the right (+X), and vice versa
            od_side = 1 if od_x < cx else -1
            # Clip margin scales with resolution: fixed 50px is degenerate
            # below 100px (np.clip returns max when min>max -> edge/negative
            # landmarks that still pass `>0` checks downstream).
            _m = max(2, min(w, h) // 20)
            fx = int(np.clip(od_x + od_side * approx_radius * 3.2, _m, w - _m))
            fy = int(np.clip(od_y + (cy - od_y) * 0.3, _m, h - _m))
            return (od_x, od_y), approx_radius, (fx, fy)

        # Default geometric center estimate
        return (int(w * 0.35), cy), approx_radius, (int(w * 0.60), cy)

    def _segment_vessels(self, green: np.float32, retinal_mask: np.ndarray) -> np.ndarray:
        h, w = green.shape
        if not HAS_OPENCV:
            return np.zeros((h, w), dtype=np.uint8)

        # Resolution-aware scaling (reference: 512px). Keeps morphology stable
        # across 256px thumbnails and high-res captures without breaking tests.
        scale = max(0.5, min(2.0, min(h, w) / 512.0))

        def _odd(n: float, lo: int = 3) -> int:
            n = max(lo, round(n))
            return n if (n % 2 == 1) else n + 1

        # Enhance green channel contrast using CLAHE
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        g_u8 = np.clip(green, 0, 255).astype(np.uint8)
        enhanced_g = clahe.apply(g_u8)

        # Morphological black-hat transform: extracts structures darker than background (blood vessels)
        bh_k = _odd(15 * scale)
        kernel_bh = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (bh_k, bh_k))
        blackhat = cv2.morphologyEx(enhanced_g, cv2.MORPH_BLACKHAT, kernel_bh)

        # Adaptive thresholding on black-hat response
        _, vessels = cv2.threshold(blackhat, 9, 255, cv2.THRESH_BINARY)
        vessels[retinal_mask == 0] = 0

        # Remove small isolated speckles (area scaled by resolution)
        min_vessel_area = max(8, round(20 * scale * scale))
        num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(vessels)
        cleaned_vessels = np.zeros_like(vessels)
        for i in range(1, num_labels):
            if stats[i, cv2.CC_STAT_AREA] >= min_vessel_area:
                cleaned_vessels[labels == i] = 255

        return cleaned_vessels

    def _segment_exudates(
        self, img_rgb: np.ndarray, od_center: tuple[int, int], od_radius: int, retinal_mask: np.ndarray
    ) -> np.ndarray:
        h, w, _ = img_rgb.shape
        if not HAS_OPENCV:
            return np.zeros((h, w), dtype=np.uint8)

        # Exudates appear bright yellow (high red & green, lower blue)
        r = img_rgb[:, :, 0].astype(np.float32)
        g = img_rgb[:, :, 1].astype(np.float32)
        b = img_rgb[:, :, 2].astype(np.float32)

        # Exudate index: high intensity + yellow saturation
        exudate_metric = np.clip(r * 0.5 + g * 0.5 - b * 0.4, 0, 255).astype(np.uint8)

        # Mask out optic disc (OD is also bright and would trigger false positives)
        od_mask = np.zeros((h, w), dtype=np.uint8)
        cv2.circle(od_mask, od_center, int(od_radius * 1.5), 255, -1)
        exudate_metric[od_mask == 255] = 0
        exudate_metric[retinal_mask == 0] = 0

        # Threshold top 1.5% brightest pixels outside OD
        if np.max(exudate_metric) > 160:
            _, ex_thresh = cv2.threshold(exudate_metric, 175, 255, cv2.THRESH_BINARY)
            # Retain only focal clusters (kernel scaled to resolution)
            ex_k = max(3, round(3 * max(0.5, min(2.0, min(h, w) / 512.0))))
            if ex_k % 2 == 0:
                ex_k += 1
            kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ex_k, ex_k))
            ex_cleaned = cv2.morphologyEx(ex_thresh, cv2.MORPH_OPEN, kernel)
            return ex_cleaned
        return np.zeros((h, w), dtype=np.uint8)

    def _detect_microaneurysm_candidates(
        self, green: np.float32, vessel_mask: np.ndarray, retinal_mask: np.ndarray
    ) -> list[tuple[int, int, int]]:
        """
        Microaneurysms: Small isolated focal dark spots (< 15 px diameter).
        """
        if not HAS_OPENCV:
            return []

        h, w = green.shape
        g_u8 = np.clip(green, 0, 255).astype(np.uint8)

        # Resolution-aware morphology (reference: 512px)
        scale = max(0.5, min(2.0, min(h, w) / 512.0))

        def _odd(n: float, lo: int = 3) -> int:
            n = max(lo, round(n))
            return n if (n % 2 == 1) else n + 1

        # Bottom-hat transform highlights dark circular objects smaller than kernel
        ma_k = _odd(9 * scale)
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ma_k, ma_k))
        blackhat = cv2.morphologyEx(g_u8, cv2.MORPH_BLACKHAT, kernel)

        # Mask out main vessels (MAs are adjacent to or isolated from major arcades)
        dil_k = _odd(3 * scale)
        dilated_vessels = cv2.dilate(vessel_mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (dil_k, dil_k)))
        blackhat[dilated_vessels == 255] = 0
        blackhat[retinal_mask == 0] = 0

        # Threshold candidate spots
        _, ma_thresh = cv2.threshold(blackhat, 15, 255, cv2.THRESH_BINARY)
        _cnt = cv2.findContours(ma_thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        contours = _cnt[0] if len(_cnt) == 2 else _cnt[1]

        ma_min_area = max(2, round(3 * scale * scale))
        ma_max_area = round(65 * scale * scale)
        candidates = []
        for cnt in contours:
            area = cv2.contourArea(cnt)
            if ma_min_area <= area <= ma_max_area:  # sub-pixel/small lesion range
                (x, y), radius = cv2.minEnclosingCircle(cnt)
                candidates.append((int(x), int(y), max(int(radius), 3)))

        return candidates[:35]  # cap to top candidates to avoid clutter

    def _create_annotated_overlay(
        self,
        orig_rgb: np.ndarray,
        od_center: tuple[int, int],
        od_radius: int,
        fovea_center: tuple[int, int],
        vessel_mask: np.ndarray,
        exudate_mask: np.ndarray,
        ma_candidates: list[tuple[int, int, int]],
    ) -> np.ndarray:
        """
        Blends all anatomical landmarks and lesion indicators onto original image
        for an instant <30s ophthalmology over-read.
        """
        overlay = orig_rgb.copy()
        if not HAS_OPENCV:
            return overlay

        # 1. Overlay Blood Vessels in light cyan tint
        vessel_pixels = vessel_mask == 255
        # np.clip before uint8: arithmetic can exceed 255 and uint8 wraps
        # (e.g. 255*0.5+180=307.5 -> 51 instead of 255), corrupting the cyan tint.
        overlay[vessel_pixels, 0] = np.uint8(np.clip(overlay[vessel_pixels, 0] * 0.4 + 40, 0, 255))
        overlay[vessel_pixels, 1] = np.uint8(np.clip(overlay[vessel_pixels, 1] * 0.5 + 180, 0, 255))
        overlay[vessel_pixels, 2] = np.uint8(np.clip(overlay[vessel_pixels, 2] * 0.5 + 230, 0, 255))

        # 2. Draw Optic Disc (yellow circle) & Fovea (blue crosshair)
        cv2.circle(overlay, od_center, od_radius, (255, 230, 0), 2)
        cv2.putText(overlay, "Optic Disc", (od_center[0] - 35, od_center[1] - od_radius - 6),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 230, 0), 1, cv2.LINE_AA)

        fx, fy = fovea_center
        cv2.drawMarker(overlay, (fx, fy), (0, 180, 255), cv2.MARKER_CROSS, 20, 2)
        cv2.circle(overlay, (fx, fy), 18, (0, 180, 255), 1)
        cv2.putText(overlay, "Fovea", (fx - 20, fy - 24),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 180, 255), 1, cv2.LINE_AA)

        # 3. Highlight Exudate Clusters in bright yellow outline
        if exudate_mask is not None and np.sum(exudate_mask) > 0:
            _ex_cnt = cv2.findContours(exudate_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            ex_contours = _ex_cnt[0] if len(_ex_cnt) == 2 else _ex_cnt[1]
            cv2.drawContours(overlay, ex_contours, -1, (255, 255, 50), 1)

        # 4. Highlight Microaneurysm candidates with red circle markers
        for cx, cy, cr in ma_candidates:
            cv2.circle(overlay, (cx, cy), cr + 2, (255, 40, 40), 1)

        return overlay
