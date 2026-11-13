"""
Kaggle Notebook Export N2: Image Quality Assessment Gate (Model 1).
Scope:
- Objective photographic feature extraction (blur, illumination, contrast, FOV)
- Threshold tuning for Good / Borderline / Bad
- Validation on quality-labeled subsets (EyePACS / DeepDRiD / synthetic degradation)
- Reassessment logic implementation and tuning.
"""

import cv2
import numpy as np


def compute_retinal_quality_features(img_bgr: np.ndarray) -> dict:
    """Extracts photographic quality features from retinal fundus photograph."""
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape

    # Retinal area mask
    mask = gray > 15
    fov_ratio = float(np.sum(mask)) / (h * w)

    if fov_ratio > 0.05:
        retinal_pixels = gray[mask]
        mean_brightness = float(np.mean(retinal_pixels))
        contrast_score = float(np.std(retinal_pixels))
        laplacian = cv2.Laplacian(gray, cv2.CV_64F)
        sharpness_score = float(np.var(laplacian[mask]))
    else:
        mean_brightness = float(np.mean(gray))
        contrast_score = float(np.std(gray))
        laplacian = cv2.Laplacian(gray, cv2.CV_64F)
        sharpness_score = float(np.var(laplacian))

    return {
        "sharpness": sharpness_score,
        "brightness": mean_brightness,
        "contrast": contrast_score,
        "fov_ratio": fov_ratio,
    }

def classify_quality(features: dict, strict: bool = False) -> str:
    """Applies decision boundary rules for 3-way quality triage."""
    blur_th = 110.0 if strict else 85.0
    bad_blur = 45.0 if strict else 35.0

    if features["sharpness"] < bad_blur or features["brightness"] < 20 or features["brightness"] > 235:
        return "BAD"
    if features["sharpness"] < blur_th or features["brightness"] < 40 or features["brightness"] > 210:
        return "BORDERLINE"
    return "GOOD"

if __name__ == "__main__":
    print("Image Quality Assessment Gate (Model 1) ready for evaluation.")
