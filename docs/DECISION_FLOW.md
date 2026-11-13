# Detailed Node-by-Node Decision Flow (Section 3 & 5)

This document specifies the exact execution logic of every node in the pipeline.

### Node 1: Fundus Image
- **Input:** Raw retinal photograph captured from digital fundus camera.
- **Handling:** Loaded without any pixel-altering clinical enhancements.

### Node 2: Image Quality Check (Model 1)
- Evaluates blur (Laplacian variance), illumination (mean luminance & clipping), contrast (standard deviation), and retinal field-of-view (FOV).
- **Outcomes:**
  - **Node 3a: GOOD** -> Proceeds directly to Node 6 (Reliable Original Image).
  - **Node 3b: BORDERLINE** -> Diverts to Node 4 (Reassessment).
  - **Node 3c: BAD** -> Diverts to Recapture loop.

### Node 4: Reassessment
- Re-evaluates marginal captures using stricter decision thresholds.
- Verifies whether subtle vessel architecture is clearly identifiable.

### Node 5: Still Unreliable?
- **5-No:** Joins Good path -> proceeds to Node 6 holding original unmodified pixels.
- **5-Yes:** Reassessment failed -> Routes to Recapture / Human Review. Does **NOT** proceed to DR classification.

### Recapture Cap Rule (Section 5 / Section 7)
- Hard cap: **2 recaptures per patient session**.
- If `recapture_attempt_count >= 2`, system does not request another capture; instead, it force-escalates to **Human Review (Operator Level)** for direct clinical evaluation of the patient's eye (checking for small pupil, dense cataract, or uncooperative gaze).

### Node 6: Reliable Original Image
- Convergence point holding the original, unmodified pixel data.
- Confirms zero synthetic enhancement steps ever run.

### Node 7: DR Classification (Model 2)
- Runs 5-class severity prediction on the reliable image:
  - 0: No DR
  - 1: Mild NPDR
  - 2: Moderate NPDR
  - 3: Severe NPDR
  - 4: Proliferative DR
- Outputs full 5-class probability vector, top-1 confidence, and top-2 margin.

### Node 8: Confidence / Uncertainty Handling
- **Low Softmax Confidence Check:** Top-1 confidence < 0.60 -> flag for human review.
- **Class Ambiguity Check:** Margin between Top-1 and Top-2 probabilities < 0.15 -> flag for human review.
- **High-Risk Grade Safety Override:** Grade 3 (Severe) and Grade 4 (Proliferative) are **ALWAYS** flagged for human review regardless of model confidence.

### Node 9: Grad-CAM Explainability
- Generates visual attention map on the final convolutional layer of Model 2.
- Overlaid onto the original fundus image for reviewer audit.
- Explicit claim boundary: Highlights influential features; does NOT constitute lesion segmentation.

### Node 10: Screening Result
- Compiles the final record per Section 25:
  - Good/Reliable images include DR grade, confidence, Grad-CAM, and referral action.
  - Bad/Unreliable images state rejection reason and recapture instruction, with **NO DR grade displayed**.

### Node 11: Human Review (Terminal Safety Layer)
- **Two Distinct Entry Points:**
  - **Operator-Level Review:** Ungradable/failed reassessment cases (supervised by trained field operator).
  - **Clinical-Level Review:** Low-confidence, ambiguous, or high-risk DR cases (supervised by ophthalmologist/tele-reader).
