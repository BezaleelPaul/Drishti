# Google's DR Screening Research — What We Adopt and Why

> Purpose: anchor our screening design to the published gold standard. Google's
> model weights were never released, so nothing here is "borrowed code" — every
> item below is a methodology, an operating-point philosophy, or a deployment
> lesson that we can (and do) mirror in this repository.

## 1. The Papers

### 1.1 Gulshan et al., JAMA 2016 — the founding paper

*Development and Validation of a Deep Learning Algorithm for Detection of
Diabetic Retinopathy in Retinal Fundus Photographs.*
[JAMA 316(22):2402–2410](https://jamanetwork.com/journals/jama/fullarticle/2588763)

- 128,175 retinal images, each graded 3–7× by a panel of 54 US
  board-certified ophthalmologists.
- Referable DR (RDR) defined as **moderate-or-worse DR or referable DME** —
  the same definition this repo uses (our `referable = grade >= 2` boundary;
  see `lib/services/ml/pipeline/dr_inference_result.dart:263`).
- Two validation sets: EyePACS-1 (9,963 images, 7.8% RDR prevalence) and
  Messidor-2 (1,748 images, 14.6% prevalence).

| Operating point | EyePACS-1 | Messidor-2 |
|---|---|---|
| AUC | 0.991 (0.988–0.993) | 0.990 (0.986–0.995) |
| **High-sensitivity** (screening tool) | sens **97.5%** (95.8–98.7) / spec 93.4% (92.8–94.0) | sens **96.1%** (92.4–98.3) / spec 93.9% (92.4–95.3) |
| High-specificity (specialist comparison) | sens 90.3% (87.5–92.7) / spec 98.1% (97.8–98.5) | sens 87.0% (81.1–91.0) / spec 98.5% (97.7–99.1) |
| NPV at measured prevalence | 99.8% | 99.6% |

Key design lesson: a screening tool must be tuned **sensitivity-first**
("a high sensitivity is a prerequisite in a potential screening tool"),
while the specialist-comparison operating point matches ophthalmologist
specificity (~98%). Every reported metric carries a 95% CI.

Bonus result we mirror structurally: **all-cause referable** (mtmDR, DME,
**or ungradable image**) achieved AUC 0.974 — Google treats "cannot grade"
as a first-class safety outcome, exactly like our quality gate does.

**Why we cannot adopt the weights:** the model was never open-sourced and was
trained on ~128k expert panel gradings no one else has. Any claim of
"Gulshan-level accuracy" without an equivalent reference standard is
fabrication — our `docs/EVALUATION_RESULTS.md` reports measured numbers
instead.

### 1.2 Ruamviboonsuk et al., Lancet Digital Health 2022 — national-scale deployment

*Real-time diabetic retinopathy screening by deep learning in a multisite
national screening programme: a prospective interventional cohort study.*
[Lancet Digit Health 4(4):e235–e244](https://www.thelancet.com/journals/landig/article/PIIS2589-7500(22)00017-6/fulltext)

- 7,651 patients, **9 primary-care sites**, Thailand's national DR screening
  programme, real-time AI interpretation at the point of capture.
- Fundus photos taken by **nurses** (task-shifting), not ophthalmologists.
- vtDR performance: accuracy 94.7% (93.0–96.2), sensitivity **91.4%**
  (87.1–95.0), specificity 95.4% (94.1–96.7).
- The AI **outperformed the retina-specialist over-readers on sensitivity**
  (91.4% vs 84.8%, p = 0.024) with equal specificity — graduated,
  non-ophthalmologist staff + AI is clinically defensible.
- **Safety net:** every image also over-read by regional retina specialists.
- 31.5% referral rate (DR, DME, ungradable, or low VA truncated referral).

### 1.3 Beede et al., CHI 2020 — the human-factors reality check

*A Human-Centered Evaluation of a Deep Learning System Deployed in Clinics
for the Detection of Diabetic Retinopathy.*
[DOI 10.1145/3313831.3376718](https://doi.org/10.1145/3313831.3376718)

- 11 Thai clinics, 8 months of observation before/after deployment.
- **Ungradability was the #1 field problem**: poor clinic lighting produced
  images the system correctly refused, frustrating nurses and delaying
  patients ("the tension between the quality threshold a system needs and
  the quality of images an imperfect environment produces").
- Protocol amendment that worked: **ungradable images were routed to a
  specialist for review instead of an automatic ophthalmology referral** —
  reduced unnecessary travel, missed work, and false-positive anxiety.
- Thresholds set for prospective trials must be **re-evaluated before
  widespread use**.

## 2. Adopted Into This Repository (status map)

| Google design element | Status here |
|---|---|
| RDR = moderate-or-worse (+DME) | **Aligned by construction** — ordinal cut-points at `score > 1.5` → grade 2; referable = grade ≥ 2 (Python-parity tested) |
| "Ungradable" is a safety output, not an error | **Implemented** — quality gate returns `BAD/UNGRADABLE` → `IMG_UNGRADABLE`, no grade is ever generated for a rejected frame |
| Ungradable → specialist review, not auto-referral-only | **Implemented** — rejections route into the tele-ophthalmologist review queue, mirroring the CHI-2020 protocol amendment |
| Nurse/operator task-shifting with specialist over-read | **Implemented** — operator capture at PHC + `DoctorReviewScreen` sign-off is the required human confirmation step |
| Sensitivity-first operating point for screening | **Adoption planned** — our current referable cut is the ordinal model's fixed boundary; a deliberately de-tuned high-sensitivity operating point must be selected on a validation cohort before field claims (see §3) |
| Reporting format (2 operating points, AUC + 95% CI, NPV at prevalence) | **Committed** — see §3 |

## 3. Evaluation Plan (Gulshan-format, binding for any accuracy claim)

Any accuracy number this project publishes MUST follow this reporting shape
on a labeled, pre-registered-style holdout:

1. **Reference standard**: majority vote of ≥2 graders (ophthalmologist or
   reading-centre), per image — never single self-labels.
2. **Primary endpoint**: referable-DR detection (**sensitivity with 95% CI**
   first, per the screening philosophy).
3. **Secondary endpoints**: specificity, AUC with 95% CI, NPV/PPV at the
   measured cohort prevalence.
4. **All-cause referable** analysis in which a rejected/ungradable frame
   counts as "referred" (safety-first denominator), like Figure 3 of
   Gulshan 2016.
5. **Both operating points** reported: (a) sensitivity-first screening
   threshold, (b) specialist-specificity-matching threshold.
6. **Gradability reported separately**: imageability rate + false-reject
   rate, because CHI-2020 shows ungradability dominates real-world impact.
7. **Cohort carve-outs**: domain shift (phone cameras vs clinic cameras) and
   media-opacity/ungradable subgroups reported explicitly, never hidden.

Current honest standing (already measured, `docs/EVALUATION_RESULTS.md`):
on 2,810 external EyePACS-labeled images our on-device ordinal model reaches
71.5% top-1 accuracy but referable sensitivity 0.21 under domain shift —
**far below screening-grade and reported as such**. The path to a defensible
sensitivity-first operating point is re-calibration/fine-tuning on Indian
(APTOS/Aravind-style, IDRiD) data with the reporting plan above, not an
unvalidated claim.

### 1.4 Ruamviboonsuk, Krause et al., npj Digital Medicine 2019 — Google × Thailand national programme

*Deep learning versus human graders for classifying diabetic retinopathy
severity in a nationwide screening program.*
[DOI 10.1038/s41746-019-0099-8](https://doi.org/10.1038/s41746-019-0099-8)

- Google-co-authored validation on **25,326 gradable images** from
  Thailand's nationwide community screening programme; reference standard
  adjudicated by a panel of international retinal specialists.
- Referable-DR detection vs **human graders**: deep-learning sensitivity
  **0.97 vs 0.74** (p < 0.001), specificity 0.96 vs 0.98.
- Severity agreement (quadratic-weighted kappa): algorithm **0.85** vs
  human graders 0.78 (p < 0.001).
- Operationally: the algorithm **cut the false-negative rate by 23%** at a
  false-positive cost of only ~2% — the concrete justification for a
  sensitivity-first screening operating point.
- Deep learning significantly outperformed on every severe category
  (severe NPDR+, PDR, DME).

### 1.5 Comparison points outside Google (for completeness)

- **Ting et al., JAMA 2017** (SNEC/NUS Singapore — not Google):
  [DOI 10.1001/jama.2017.18152](https://doi.org/10.1001/jama.2017.18152) —
  494,661 images; multi-disease screening (referable DR AUC 0.936,
  sens 90.5% / spec 91.6%; **plus possible glaucoma & AMD**). The existing
  precedent for closing our single-disease gap.
- **Abràmoff et al., npj Digital Medicine 2018** (IDx-DR pivotal trial —
  not Google): [DOI 10.1038/s41746-018-0040-6](https://doi.org/10.1038/s41746-018-0040-6)
  — first **FDA-authorised autonomous** diagnostic AI: sens 87.2%
  (81.8–91.2; FDA target >85%), spec 90.7% (88.3–92.7; >82.5%),
  imageability 96.1% (94.6–97.3). The regulatory template and the concrete
  numbers a CDSCO pathway would be benchmarked against.
- **EyeArt pivotal study (Eyenuk), JAMA Netw Open 2021** — see §4 item 4.

## 5. Beyond Google — other landmark groups (survey)

| Group / scientist | Contribution | Numbers | Relevance here |
|---|---|---|---|
| **Prof. Michael Abràmoff** (Univ. of Iowa → Digital Diagnostics) | IDx-DR — the **first FDA-authorised autonomous AI diagnostic in any field of medicine** (2018) | Pivotal: sens 87.2% (81.8–91.2; FDA target >85%), spec 90.7% (88.3–92.7; >82.5%), imageability 96.1% | The regulatory template any CDSCO pathway would follow |
| **Dr. Yukun Zhou & Prof. Pearse Keane** (Moorfields Eye Hospital + UCL) | **RETFound** — Nature 2023 retinal *foundation model*: self-supervised on **1.6 M unlabelled retinal images**, then label-efficient fine-tuning | Beats ImageNet-pretrained transfer learning on DR and multiple eye/systemic diseases; validated on **APTOS-2019, IDRiD (Indian), Messidor-2** | **Open weights + a Keras port exist** (github.com/rmaphoh/RETFound_MAE, uw-biomedical-ml/RETFound_MAE) — the concrete upgrade path for our grading model and for closing the single-disease gap (glaucoma/AMD) |
| **Prof. Tien Yin Wong & Dr. Daniel SW Ting** (Singapore Eye Research Institute / NUS) | JAMA 2017 — 494,661 images, multi-disease screening (DR + possible glaucoma + AMD) | Referable DR AUC 0.936, sens 90.5% / spec 91.6%; VTDR sens 100% (94.1–100) | Proves one retinal system can serve multiple diseases |
| **Airdoc / Chen Yuzhong** (Shanghai) | First NMPA **Class III** "AI aided diagnosis" certificate in China (2020); multicenter trial modelled on IDx-DR's protocol | AIDRScreening: RDR sens 86.72% / spec 96.09%; nonmydriatic subgroup 84.0% / 93.3% | Asian regulatory precedent with undilated imaging subgroup reporting |
| **Eyenuk / Kaushal Solanki** (EyeArt) | FDA-cleared autonomous screening; JAMA Netw Open 2021 pivotal | mtmDR sens 95.5% spec 85.0% **without dilation**; imageability 87.4% → 97.4% with dilation | The dilation-gap benchmark; best-in-class undilated sensitivity |
| **India's own institutions built the "famous" ones too** | Gulshan 2016's grading panel and co-authors include **Aravind Eye Care, Madurai (Dr. R. Kim)** and **Sankara Nethralaya, Chennai (Dr. Rajiv Raman — also co-author of npj DM 2019)** | — | Indian-labelled data was central to Google's own model — an Indian dataset fine-tune is lineage-consistent, not niche |
| **Dr. Anand Sivaraman / Remidio** (Bangalore) | **NIRVAI**: smartphone-based DR screening, CDSCO + CE cleared, deployed on the same handheld hardware category our app targets | Reported ~95% sensitivity vs. Eyenuk-lit grades | The commercial Indian precedent our workflow mirrors |


## 4. Full Bibliography

1. Gulshan V, Peng L, Coram M, et al. Development and Validation of a Deep
   Learning Algorithm for Detection of Diabetic Retinopathy in Retinal
   Fundus Photographs. *JAMA*. 2016;316(22):2402–2410.
   doi:10.1001/jama.2016.17216
2. Ruamviboonsuk P, Tiwari R, Sayres R, et al. Real-time diabetic
   retinopathy screening by deep learning in a multisite national screening
   programme: a prospective interventional cohort study. *Lancet Digit
   Health*. 2022;4(4):e235–e244. doi:10.1016/S2589-7500(22)00017-6
3. Beede E, Baylor E, Hersch F, et al. A Human-Centered Evaluation of a
   Deep Learning System Deployed in Clinics for the Detection of Diabetic
   Retinopathy. *CHI 2020*. doi:10.1145/3313831.3376718
4. Ipp E, Liljenquist D, Bode B, et al. Pivotal Evaluation of an
   Artificial Intelligence System for Autonomous Detection of Referrable
   and Vision-Threatening Diabetic Retinopathy. *JAMA Netw Open*.
   2021;4(11):e213684. (EyeArt comparison point: mtmDR sens 95.5% / spec
   85.0% without dilation; imageability 87.4% undilated → 97.4% dilated.)
5. Ruamviboonsuk P, Krause J, Chotcomwongse P, et al. Deep learning versus
   human graders for classifying diabetic retinopathy severity in a
   nationwide screening program. *npj Digit Med*. 2019;2:91.
   doi:10.1038/s41746-019-0099-8
6. Ting DSW, Cheung CY, Lim G, et al. Development and Validation of a Deep
   Learning System for Diabetic Retinopathy and Related Eye Diseases Using
   Retinal Images From Multiethnic Populations With Diabetes. *JAMA*.
   2017;318(22):2211–2223. doi:10.1001/jama.2017.18152
7. Abràmoff MD, Lavin PT, Birch M, et al. Pivotal trial of an autonomous
   AI-based diagnostic system for detection of diabetic retinopathy in
   primary care offices. *npj Digit Med*. 2018;1:39.
   doi:10.1038/s41746-018-0040-6

*Compiled 2026-10-21 for Drishti-AI. No Google weights, datasets with
licence restrictions, or non-disclosed artifacts are included in this
repository.*
