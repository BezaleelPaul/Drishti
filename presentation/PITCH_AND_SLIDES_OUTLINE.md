# SIH 2026 Presentation & Demonstration Guide

## 1. The 30-Second Pitch (Section 27)

> *"Our project addresses a major weakness in automated diabetic-retinopathy screening: the AI may be confident even when the retinal image is not reliable. We therefore place an image-reliability gate before the DR model. The system evaluates blur, illumination, contrast, artifacts and retinal field of view, reassesses borderline images without altering the original clinical pixels, and abstains when the image remains unreliable. Only reliable images reach the five-class DR model. We then quantify confidence and use Grad-CAM to explain the prediction, with uncertain cases routed for human review. The goal is safer, more trustworthy and more practical AI-assisted retinal screening."*

---

## 2. Key Differentiators (Why This Project Wins)

1. **Quality-First Triage:** The first question answered is *"Can we trust this image?"*, not *"What grade is this?"*
2. **Non-Destructive Retinal Handling (Section 20):** No clinical enhancement or hallucinated features before grading.
3. **Explicit Abstention:** The AI is empowered to say *"I cannot answer this from what you gave me."*
4. **Bounded Recapture Cap:** Hard limit of 2 retries prevents infinite loop; escalates to clinician.
5. **Two-Tier Human Review:** Separates operator hardware issues from ophthalmologist clinical decisions.
6. **Measurable Safety Metrics:** Backed by A/B/C experimental comparisons.

---

## 3. Recommended 8-Slide Pitch Deck Structure

1. **Slide 1: The Clinical Reality:** High screening burden vs. low specialist availability in rural/camp settings.
2. **Slide 2: The Core Failure Mode:** Standard classifiers give confident diagnoses on blurred/garbage images.
3. **Slide 3: Our Solution Architecture:** The 2-model pipeline (Image Quality Gate → Reliable Original Image → DR Classifier → Confidence → Grad-CAM → Human Review).
4. **Slide 4: Model 1 — The Quality Gate:** Feature extraction, 3-way triage, and non-destructive reassessment.
5. **Slide 5: Model 2 — Severity Classification & Grad-CAM:** APTOS 2019 training, QWK performance, and explainability heatmaps.
6. **Slide 6: Dual-Channel Human-in-the-Loop Safety:** Operator over-read for bad captures vs. clinician over-read for clinical ambiguity.
7. **Slide 7: Experimental Evidence (A/B/C Evaluation):** Reduction in forced predictions and improved effective sensitivity.
8. **Slide 8: Roadmap & Impact:** Compliance with tele-ophthalmology workflows.
