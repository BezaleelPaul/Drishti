# Evaluation Results — External Validation on Labeled Fundus Data

Honest measurement of the shipped ELYTRIVA components on real, third-party
labeled data. Everything below is reproducible from this repository; no numbers
are copied from model cards without re-measurement.

**Headline:** the pipeline is *safe* (it refuses non-retinal input, defers
uncertainty, and never silently releases a referral), but the shipped
EfficientNetB0 classifier has **low referable-DR sensitivity (21%)** on external
data. The system is therefore positioned as a **triage-assist with mandatory
human review**, never as an autonomous screener.

---

## 1. Setup

| Item | Value |
|---|---|
| Dataset | `youssefedweqd/Diabetic_Retinopathy_Detection` (HuggingFace, MIT license) |
| Split | `data/validation-00000-of-00001.parquet` — **2,810 images**, real EyePACS-style screening photographs |
| Labels | 5-class DR severity {0..4}; distribution `{0: 2065, 1: 195, 2: 423, 3: 70, 4: 57}` |
| Referable DR definition | grade ≥ 2 (moderate NPDR and above) — 550 positives / 2,260 negatives |
| Classifier | `final_model.keras` (EfficientNetB0, APTOS-2019-trained), via `DRClassifier` (keras backend) |
| Model card's own claim | **72% accuracy, macro-F1 0.57** on 550 held-out APTOS images (author's number, not ours) |
| Preprocessing | 224×224 float32 input; Rescaling/Normalization are **inside** the saved model (verified via `model.summary()`), matching the card's usage snippet |
| Label sanity | Stratified visual spot-check of all 5 grades (pathology consistent with grade) |
| Tooling | `evaluate_labeled_dataset.py` → `results/labeled_evaluation.json`, per-image audit trail in `results/labeled_evaluation_predictions.csv` |

Reproduce:

```
python evaluate_labeled_dataset.py                 # full 2810, ~21 min
python evaluate_labeled_dataset.py --limit 400 --mode quality
python evaluate_labeled_dataset.py --from-csv results/labeled_evaluation_predictions.csv   # instant re-analysis
```

---

## 2. Model 2 (DR grading) — external accuracy

All 2,810 images, gate bypassed (`model_all_images`):

| Metric | Ours (EyePACS external) | Model card (APTOS holdout) |
|---|---|---|
| Top-1 accuracy | **71.5%** | 72% |
| ±1 agreement | 82.4% | — |
| Macro-F1 | **0.26** | 0.57 |
| Weighted-F1 | 0.65 | 0.73 |
| Balanced accuracy | 0.25 | — |
| QWK | **0.31** | not reported |
| ECE (10-bin) | 0.064 | not reported |

Per-class performance (external set):

| Grade | Support | Precision | Recall | F1 |
|---|---|---|---|---|
| 0 No DR | 2065 | 0.770 | **0.942** | 0.847 |
| 1 Mild | 195 | 0.041 | **0.021** | 0.027 |
| 2 Moderate | 423 | 0.291 | **0.114** | 0.163 |
| 3 Severe | 70 | 0.000 | **0.000** | 0.000 |
| 4 Proliferative | 57 | 0.550 | **0.193** | 0.286 |

Confusion matrix (rows = true, cols = predicted):

```
        0     1     2     3     4
  0  1945    60    57     0     3
  1   182     4     9     0     0
  2   343    26    48     1     5
  3    38     4    27     0     1
  4    18     4    24     0    11
```

Referable-DR triage (grade ≥ 2):

| | Value |
|---|---|
| Sensitivity | **0.213** (117/550) |
| Specificity | 0.970 |
| PPV | 0.629 |
| NPV | 0.835 |

**Interpretation (no spin):**
- The headline accuracy **matches the model card's own number** (71.5% vs 72%) —
  nothing was lost in integration or preprocessing.
- But that accuracy is carried almost entirely by the majority class. Minority
  recall collapses under external domain shift: severe NPDR recall is **0/70**,
  and referable-DR sensitivity is **21%**, far below anything acceptable for
  autonomous screening (published screening systems target ≥ 90%).
- Accuracy on a 73%-negative dataset is a vanity metric; macro-F1/QWK/sensitivity
  are the honest ones, and they are weak.

---

## 2b. Shipped backend (DRDetect ordinal regression + TTA) — full set + provenance subset

The shipped classifier changed from the legacy Keras path (section 2) to
`onnx_drdetect` (EfficientNetB0 ordinal regression, 512px, Ben-Graham
preprocessing) with a 4-view TTA flip ensemble whose cross-view spread feeds
the uncertainty signal.

**Full 2,810-image paired run (2026-10-21, streaming loader; identical
subset logic; artifacts `results/labeled_evaluation_drdetect_tta_on.json`
and `results/labeled_evaluation_drdetect_no_tta.json` + `_predictions.csv`
audit trails; wall 3142.8 s / 1886 s on the 2-core CPU):**

| Metric | TTA off (legacy single pass) | TTA on (shipped default) |
|---|---|---|
| Top-1 accuracy | 68.0% | 68.0% |
| Within-1 accuracy | 88.1% | **88.4%** |
| QWK | 0.531 | **0.534** |
| ECE | 0.157 | **0.119** |
| Referable-DR sensitivity | **0.384** | 0.375 |
| Referable-DR specificity | 0.948 | **0.950** |
| Domain-gate coverage / FRR | 93.06% / 6.94% | 93.06% / 6.94% (model-independent ✓) |
| Latency / image (2-core CPU, incl. gates) | 670 ms | 1118 ms |
| Uncertainty-gate released | 2127 | 1785 |
| Released accuracy | 77.8% | **85.4%** |
| Released specificity / NPV | 98.5% / — | **99.8% / 92.6%** |

Full-set reading (supersedes the n=200 subset below):

- TTA's honest effect at scale: −24% calibration error (ECE 0.157 → 0.119)
  and +7.6pp released-subset accuracy (77.8% → 85.4%) with tighter release
  (2127 → 1785 released; abstentions go to mandatory human review). QWK and
  referable sensitivity move within noise (±0.01).
- The n=200 stratified subset (kept below for provenance) over-stated TTA's
  QWK/sensitivity gains — minority-heavy sampling; this full-set table is
  the citable one.
- Against the legacy Keras backend (section 2): QWK 0.31 → 0.53, referable
  sensitivity 0.21 → 0.375 at comparable top-1 accuracy — the ordinal-regression
  swap, not TTA, is the dominant improvement.

Reading (n=200 provenance subset):
- The ordinal-regression swap is itself a large improvement over section 2
  (referable sensitivity 0.21 → 0.60 on comparable subsets, QWK 0.31 → 0.63).
- TTA's incremental effect: same sensitivity, +3.8pp referable specificity,
  −35% calibration error, at ~1.9× inference cost (preprocessing is shared
  across views, so the 4-model ensemble is not 4× wall time).
- The uncertainty gate releases fewer predictions (84 vs 121 of 188 gated
  images) but of visibly higher quality (released-subset macro-F1 0.33 → 0.69);
  everything else is routed to mandatory human review, which is the intended
  fail-safe behaviour.
- n=200 subset numbers; superseded by the full-set paired run above.

Reproduce:

```
venv\Scripts\python.exe evaluate_labeled_dataset.py --limit 200 --mode model --out results\labeled_tta_off_200.json   # with DRISHTI_TTA_VIEWS=1
venv\Scripts\python.exe evaluate_labeled_dataset.py --limit 200 --mode model --out results\labeled_tta_on_200.json    # DRISHTI_TTA_VIEWS unset
```

---

## 3. Domain gate (Model 0) — non-retinal input is refused

| Metric | Full set (n=2810) | Stratified 400 |
|---|---|---|
| FUNDUS (accepted) | 2552 (93.1%) | 365 (91.3%) |
| UNDETERMINED (deferred to quality gate) | 63 (2.2%) | 9 (2.3%) |
| NOT_FUNDUS (rejected) | **195 (6.9%)** | 26 (6.5%) |
| Reject reasons | band 156 / red-blue 39 | — |

Reject reasons are retinal-colour failures on images the gate judged
non-retinal; spot-checked rejects were heavily washed-out/colour-cast frames.
This false-reject rate is the *known cost* of the gate (42% → 6.9% after
calibration on 400 images) and it is the price of the property below.

Safety property (the point of the gate): **all 14 adversarial non-retinal
fixtures in `test_samples/03_adversarial_non_fundus/` are rejected**, including
faces, documents, screenshots, landscapes, and the historical API face uploads
that previously produced a fabricated Grade 0. Enforced by
`tests/red_team/test_corpus_sweep.py` (76 subtests) in CI.

---

## 4. Model 1 (quality gate) — full 2,810-image run, retuned

Domain gate: coverage 93.1% (FUNDUS 2552 / NOT_FUNDUS 195 / UNDETERMINED 63).
Among the 2,615 images that reached Model 1:

| Grade | Count | Share (of 2,810) |
|---|---|---|
| GOOD | 392 | 13.9% |
| BORDERLINE (→ reassessment) | 1,587 | 56.5% |
| BAD (→ recapture guidance, incl. 195 domain rejects) | 831 | 29.6% |
| **Pass fraction (GOOD+BORDERLINE)** | | **75.7%** (was 40.9%; 73.5% on the earlier stratified-400 cross-check) |

**How it was retuned (same discipline as the domain gate):** we dumped every
quality metric for 600 stratified screening images *and* joined them with the
DR model's prediction on the same images. Finding: the 15–35 Laplacian band
(rejected as "severe blur") scored the same DR accuracy as the 35–85 band
that was already admitted as borderline (0.398 vs 0.401 balanced-sample) —
the threshold was cutting usable images without catching anything worse.
`blur_bad_threshold` went 35 → 15 (`checker.py`), which:

- raises the pass rate from 40.9% → **75.7%** on the full real screening set,
- keeps **every** corpus failure fixture BAD (motion blur 1.2, glare,
  underexposure, `scenario_2_bad`, `scenario_3` are all ≤ 3 on sharpness),
- flips exactly one corpus image: `real_clinical_fundus_patient1`
  (a genuine clinical fundus) from BAD → BORDERLINE,
- leaves all safety tests green (29 unit / 29 red-team / 11 integration,
  pytest 86 + 117 subtests).

Remaining BADs are dominated by the ML-ensemble cutoff and gross blur, not by
the metric we relaxed. Model 1 still never creates a wrong prediction — it
can only over-refuse, which is the safe direction.

---

## 5. Uncertainty gate (Section 7) — what is actually released

Thresholds: confidence ≥ 0.60, top-2 margin ≥ 0.15 (`ConfidenceConfig`).

| Subset | n | Accuracy | Referable sensitivity |
|---|---|---|---|
| All (gate bypassed) | 2810 | 0.715 | 0.213 |
| After domain gate | 2615 | 0.719 | 0.201 |
| **Released** (confident + unambiguous) | 2138 (76.1%) | 0.782 | **0.043** |
| Abstained (→ human review) | 672 (23.9%) | — | — |

**Interpretation:** the gate does exactly what it was designed to do — it
abstains on a quarter of cases and its released subset is more accurate than
the whole. It must **not** be read as "the system is 78% accurate": released
sensitivity for referable DR is 4%, because the model's *confident* predictions
are overwhelmingly "No DR". Under-referral is the clinical risk here, and the
mitigations are architectural and already in the code:

- every referable prediction forces clinician review regardless of confidence
  (`router.py`, `referable_review`),
- uncertain predictions are retained as provisional for over-read, never
  silently finalized (`error_code=AI_LOW_CONFIDENCE`),
- the Flutter app withholds a grade and shows recapture guidance instead of
  inventing one.

**TTA-era confidence-threshold sweep (full 2,810-image shipped-backend run):**
`scripts/tune_confidence_thresholds.py` grids `min_confidence_threshold` ×
`min_ambiguity_margin` over the shipped-backend prediction CSVs. Full-set
grid plus split-half validation (tune on A = even rows, confirm on
B = odd rows; the CSV is label-sorted, so parity halves mix all grades):

| Gate (conf/margin) | Released (A/B) | Released acc (A/B) | Missed referables in released (A/B) |
|---|---|---|---|
| 0.55 / 0.15 | 1009 / 1005 | 0.830 / 0.840 | 79 / 81 |
| 0.60 / 0.15 (old default) | 960 / 957 | 0.850 / 0.858 | 68 / 70 |
| 0.65 / 0.15 | 920 / 915 | 0.860 / 0.862 | 60 / 64 |
| **0.70 / 0.15 (shipped)** | 880 / 872 | **0.874 / 0.864** | **52 / 61** |

**Decision (2026-10-21): shipped default raised 0.60 → 0.70** in both the
Python `ConfidenceConfig` and the Dart port (`kMinConfidenceThreshold`).
Justification: the improvement is monotonic on both *independent* halves —
~23% fewer missed referables in the released subset and higher released
accuracy — at only ~8% lower release volume. Margin stays 0.15 (inert with
TTA-separated probabilities). The Dart parity test pins the new flag string
(`Low confidence (55.0% < 70%)`).

---

## 6. Operating-point sweep — a sensitivity lever exists, and its limits

Shipped policy is argmax: predict referable iff the top-1 class ≥ 2. That sits
far to the right of the trade-off curve (very specific, very insensitive).
`operating_point_sweep.py` re-cuts the same 2,810 images at every threshold on
the referable probability mass (`p2 + p3 + p4`), using the probabilities stored
in `results/labeled_evaluation_predictions.csv`:

| Operating point | Threshold | Sensitivity | Specificity | PPV | Balanced acc |
|---|---|---|---|---|---|
| **Shipped (argmax)** | — | 0.213 | 0.970 | 0.629 | 0.591 |
| Youden-J optimum | 0.10 | 0.569 | 0.791 | 0.399 | 0.680 |
| High-specificity option | 0.25 | 0.364 | 0.921 | 0.528 | 0.642 |
| Spec ≥ 0.85 kept | 0.15 | 0.473 | 0.854 | 0.441 | 0.663 |
| Sensitivity ≥ 0.90 | any | — | **unreachable** — would require flagging everything (spec → 0) |

**Held-out check** (`--holdout`, stratified 50/50 split, t\* tuned on the
calibration half only, reported once on the 1,407-image test half):

| Operating point (test half) | Threshold | Sensitivity | Specificity | Balanced acc |
|---|---|---|---|---|
| Shipped argmax | — | 0.250 | 0.971 | 0.610 |
| **t\* = 0.09 (calibration-tuned)** | 0.09 | **0.623** | 0.775 | **0.699** |

**Reading:**
- Threshold choice alone **more than doubles** referable sensitivity
  (0.21 → 0.57 same-set; 0.25 → 0.62 held-out) while staying useful,
  improving balanced accuracy 0.59 → 0.68 (0.61 → 0.70 held-out). This is a
  real, zero-training lever, and the held-out half confirms it transfers
  beyond the tuning sample.
- But sensitivity ≥ 0.90 **cannot be bought with thresholds** — the model's
  probability mass on referable classes is too low. Model improvement (binary
  referable head / fine-tuning, the P1 already in ROADMAP) is the only path to
  screening-grade sensitivity.
- Same-set table rows are optimistic by construction (the held-out rows are
  the ones to quote). Full tables: `results/operating_point_sweep.csv`,
  `results/operating_point_sweep.json`.

> **ADOPTED (X-0, 2026-09-28):** the release operating point moves from
> argmax to **t\* = 0.09 on referable mass** (`p2+p3+p4 ≥ 0.09`), validated on
> the held-out split (sens 0.623 / spec 0.775 / balanced acc 0.699). The app's
> referral flag and UI copy must use this rule; concretely: a capture is
> referable-flagged when `top1 ≥ 2` **OR** `p2+p3+p4 ≥ 0.09`. Flags produced
> this way still route through mandatory human review; this changes where the
> RECALL floor sits, not the trust model. Before adopting any future
> operating-point change, re-verify red-team fixtures and re-run
> `operating_point_sweep.py --holdout` so the quoted numbers stay the held-out
> ones.

---

## 7. Limitations

1. **Third-party labels.** Labels come with the public dataset; they were not
   re-adjudicated by us. A visual spot-check found them plausible.
2. **Single external dataset, single camera distribution.** No multi-site or
   prospective validation.
3. **Class imbalance** (73% grade 0) inflates accuracy; prefer macro-F1/QWK/
   sensitivity when comparing.
4. **One held-out split, not prospective.** The section 6 operating point is
   tuned on a calibration half and confirmed on a held-out test half of the
   *same* dataset; deployment would want external prospective calibration.
5. **Not a clinical claim.** This is a hackathon research benchmark; the model
   card itself states "Not for clinical use".
6. **XAI truthfulness: FAILED its own gate (X-1, 2026-09-28).** We built a
   mathematical check for the explanations — insertion/deletion curves
   (blur-baseline, RISE-style; `validate_xai.py`,
   `results/xai_insertion_deletion.json`) — and the Grad-CAM ordering does
   **not** beat random ordering on the deletion axis on ANY tested image
   (insertion is also non-monotonic). The model's confidence is
   texture-hypersensitive everywhere (same instability visible in the fp16
   quantization drift of 0.29), so gradient attention does not causally
   drive its output on this checkpoint. **Consequence (enforced):** heatmaps
   remain labelled "model attention — not evidence" and are NOT presented to
   operators as justification for a grade; the intended fix is the F-5
   retrain, after which this gate must be re-run and pass before any
   operator-facing heatmap ships.

## 8. What these numbers say the product should do

- Sell the **safety architecture** (domain gate → quality gate → uncertainty
  gate → mandatory human review → audit trail), which is measured and enforced
  by tests — not a headline accuracy that the model does not have.
- Next model work (P1): fine-tune on the combined APTOS+EyePACS data or add a
  referable-vs-not binary head, targeting referable sensitivity ≥ 0.9 before
  anyone claims screening-grade performance.
- Calibration work (P1), **all three done**: Model 1 thresholds recalibrated
  on a 600-image metric+prediction join (pass fraction 40.9% → **75.7%**
  full-set, every corpus failure fixture still rejected, section 4); the
  referable operating point calibrated and confirmed on a held-out split
  (sens 0.25 → 0.62, section 6); full-set Model 1 run completed.
- The one remaining P1: model improvement for referable sensitivity —
  thresholds alone top out near 0.62 and cannot reach screening-grade 0.9.
