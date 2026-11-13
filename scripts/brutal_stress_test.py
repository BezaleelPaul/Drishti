#!/usr/bin/env python3
"""
BRUTAL STRESS TEST BATTERY
Pits Previous Keras, Previous DRDetect ONNX, and New Meta DINOv3-Large
against adversarial attacks, optical noise, rotation variance, and non-fundus leakage.
"""
from __future__ import annotations

import os
import sys
import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from src.classification.classifier import DRClassifier
from src.classification.dinov3_classifier import DINOv3ICDRClassifier

def main():
    print("=" * 80)
    print(" DRISHTI-AI: BRUTAL STRESS TEST & MODEL SHOWDOWN")
    print(" Comparing: [1] Baseline Keras  [2] DRDetect Ordinal ONNX  [3] DINOv3-Large")
    print("=" * 80)

    # 1. Load models
    clf_keras = DRClassifier(keras_model_path=os.path.join(_REPO_ROOT, "final_model.keras"))
    clf_onnx = DRClassifier(onnx_model_path=os.path.join(_REPO_ROOT, "models", "efficientnet_b0_regression_512px.onnx"))
    clf_dinov3 = DINOv3ICDRClassifier()

    # --------------------------------------------------------------------------
    # SUITE 1: ROTATION INVARIANCE TEST (0°, 90°, 180°, 270°)
    # --------------------------------------------------------------------------
    print("\n" + "=" * 80)
    print(" [TEST 1] ROTATION INVARIANCE (0°, 90°, 180°, 270°)")
    print(" Fundus photos are approximately rotation-symmetric. Good models MUST NOT flip.")
    print("=" * 80)

    sample_imgs = [
        ("patient1_mild", os.path.join(_REPO_ROOT, "test_samples", "01_real_clinical_fundus", "real_clinical_fundus_patient1.jpg")),
        ("patient2_normal", os.path.join(_REPO_ROOT, "test_samples", "01_real_clinical_fundus", "real_clinical_fundus_patient2.jpg")),
        ("scenario1_mild", os.path.join(_REPO_ROOT, "test_samples", "04_section24_demo_scenarios", "scenario_1_good.jpg")),
        ("scenario4_uncertain", os.path.join(_REPO_ROOT, "test_samples", "04_section24_demo_scenarios", "scenario_4_uncertain.jpg")),
    ]

    rotations = [0, 90, 180, 270]

    for name, path in sample_imgs:
        if not os.path.exists(path):
            continue
        base_pil = Image.open(path).convert("RGB")
        print(f"\n--- Target: {name} ---")
        
        k_preds, o_preds, d_preds = [], [], []
        for angle in rotations:
            rot_img = base_pil.rotate(angle)
            
            res_k = clf_keras.predict(rot_img)
            res_o = clf_onnx.predict(rot_img)
            res_d = clf_dinov3.predict(rot_img)
            
            k_preds.append((res_k.predicted_grade.value, res_k.confidence))
            o_preds.append((res_o.predicted_grade.value, res_o.raw_score))
            d_preds.append((res_d.predicted_class, res_d.confidence))
            
            print(f"  {angle:3d}° | Keras: G{res_k.predicted_grade.value} ({res_k.confidence*100:4.1f}%) | "
                  f"DRDetect: G{res_o.predicted_grade.value} (sc:{res_o.raw_score:4.2f}) | "
                  f"DINOv3: C{res_d.predicted_class} ({res_d.confidence*100:4.1f}%)")
        
        k_unique = len(set(p[0] for p in k_preds))
        o_unique = len(set(p[0] for p in o_preds))
        d_unique = len(set(p[0] for p in d_preds))
        print(f"  Stability (Flips): Keras={k_unique-1} flips | DRDetect={o_unique-1} flips | DINOv3={d_unique-1} flips")

    # --------------------------------------------------------------------------
    # SUITE 2: OPTICAL NOISE & PERTURBATIONS (Blur, Glare, Dim, Noise)
    # --------------------------------------------------------------------------
    print("\n" + "=" * 80)
    print(" [TEST 2] OPTICAL NOISE & ILLUMINATION STRESS TEST")
    print(" Tests resilience against camera glare, severe blur, low illumination, and sensor noise.")
    print("=" * 80)

    test_img_path = os.path.join(_REPO_ROOT, "test_samples", "01_real_clinical_fundus", "real_clinical_fundus_patient1.jpg")
    orig_pil = Image.open(test_img_path).convert("RGB")

    perturbations = {
        "Clean (Reference)": orig_pil,
        "Heavy Blur (Radius 4)": orig_pil.filter(ImageFilter.GaussianBlur(4)),
        "Underexposed (0.4x)": ImageEnhance.Brightness(orig_pil).enhance(0.4),
        "Overexposed Glare (1.8x)": ImageEnhance.Brightness(orig_pil).enhance(1.8),
        "Low Contrast (0.5x)": ImageEnhance.Contrast(orig_pil).enhance(0.5),
        "High Contrast (1.8x)": ImageEnhance.Contrast(orig_pil).enhance(1.8),
    }

    print(f"{'Perturbation':<26} | {'Keras (Grade & Conf)':<22} | {'DRDetect (Score & Grade)':<24} | {'DINOv3 (Class & Conf)':<22}")
    print("-" * 102)

    for p_name, p_img in perturbations.items():
        res_k = clf_keras.predict(p_img)
        res_o = clf_onnx.predict(p_img)
        res_d = clf_dinov3.predict(p_img)
        
        k_str = f"Grade {res_k.predicted_grade.value} ({res_k.confidence*100:4.1f}%)"
        o_str = f"sc:{res_o.raw_score:4.2f} (Grade {res_o.predicted_grade.value})"
        d_str = f"Class {res_d.predicted_class} ({res_d.confidence*100:4.1f}%)"
        
        print(f"{p_name:<26} | {k_str:<22} | {o_str:<24} | {d_str:<22}")

    # --------------------------------------------------------------------------
    # SUITE 3: ADVERSARIAL NON-FUNDUS LEAKAGE TEST (12 Non-Retinal Images)
    # --------------------------------------------------------------------------
    print("\n" + "=" * 80)
    print(" [TEST 3] ADVERSARIAL NON-FUNDUS HALLUCINATION TEST")
    print(" If non-retinal images are passed: What does each model hallucinate?")
    print(" Danger: Models that hallucinate high-grade disease cause severe clinical panic.")
    print("=" * 80)

    adv_dir = os.path.join(_REPO_ROOT, "test_samples", "03_adversarial_non_fundus")
    adv_files = sorted([f for f in os.listdir(adv_dir) if f.endswith(('.jpg', '.png'))])[:8]

    print(f"{'Adversarial Image':<32} | {'Keras (Hallucination)':<22} | {'DRDetect (Continuous)':<24} | {'DINOv3 (Hallucination)':<22}")
    print("-" * 106)

    for af in adv_files:
        af_path = os.path.join(adv_dir, af)
        img = Image.open(af_path).convert("RGB")
        
        res_k = clf_keras.predict(img)
        res_o = clf_onnx.predict(img)
        res_d = clf_dinov3.predict(img)
        
        k_str = f"Grade {res_k.predicted_grade.value} ({res_k.confidence*100:4.1f}%)"
        o_str = f"sc:{res_o.raw_score:4.2f} (Grade {res_o.predicted_grade.value})"
        d_str = f"Class {res_d.predicted_class} ({res_d.confidence*100:4.1f}%)"
        
        print(f"{af[:30]:<32} | {k_str:<22} | {o_str:<24} | {d_str:<22}")

    print("\n" + "=" * 80)
    print(" BRUTAL TEST SUITE COMPLETE")
    print("=" * 80)

if __name__ == "__main__":
    main()
