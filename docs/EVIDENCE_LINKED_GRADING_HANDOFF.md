# Handoff Report — Evidence-Linked Grading (schema_version 1.0)

Date: 2026-10-21 · Branch: `master` · Commits: `93838a2`, `90c5804`, `6227da5`, `827ae73`

---

## 1. Architecture discovered (verified, not assumed)

**Backend chain (single decode, one canonical pixel space).**
`ScreeningPipelineRouter.process_image` decodes the capture **once** into a
canonical uint8 RGB array (`src/image_io.to_rgb_uint8`) and shares that array
with the quality checker, the structure segmenter, and the classifier. The
segmenter (`src/segmentation/structure_segmenter.py`) therefore operates in
**source-image pixel space** — no crop, resize, flip, or padding occurs on
that path, so **no coordinate transformation is ever required** downstream.
That is the canonical space the new evidence contract uses.

**Three (not one) evidence paths existed before this work — the source of the
"backend evidence is not in the Flutter payload" problem:**
1. `analyze_retina` API → **counts only** (`microaneurysm_count`, no coordinates).
2. `GET /review/{id}/markers` → `ReviewMarkersResponse` (coordinates; the doctor viewer path).
3. **On-device Dart port** (`computeRetinalMarkers`) → its own coordinates, documented deviations
   (box-blur top-hat, no CLAHE/vessel-exclusion, ≤384 px work space scaled back).

**Flutter had exactly one parse point** — `RetinalMarkers.fromJson` — so the
extension was made there (no duplicate competing model).

**Grade ↔ evidence were never connected**: the CNN grade and the classical
detections were shown side by side, with no criterion mapping and no
disagreement policy.

## 2. Files changed and why

**New (Python core — the clinical layer):**
- `src/services/grading_policy.py` — versioned ICDRS-subset policy `icdrss-subset v1.0`.
  Deterministic criterion evaluation; statuses `satisfied / not_met / indeterminate /
  not_evaluated`; stable criterion ids (`icdrss.ma_present`, `icdrss.exudate_present`,
  `icdrss.fovea_involvement`, `icdrss.venous_beading`, `icdrss.neovascularization`).
- `src/services/evidence.py` — detector output → typed, validated evidence
  (stable ids `LE-0001…`, controlled lesion types, explicit detection status,
  criterion links, honesty notes, fail-closed coordinate validation).
- `src/services/disagreement.py` — deterministic CNN-vs-evidence reconciliation with named
  reason codes (`EVIDENCE_MATCH / ADJACENT / CONFLICT / NOT_ASSERTED / INCOMPLETE /
  MODEL_UNAVAILABLE`).
- `src/services/evidence_service.py` — **single seam** building the whole payload
  (used by the review service, the API bridge and the demo report).

**Changed (Python):**
- `api/schemas.py` — `LesionEvidenceItem`, `CriterionEvaluationItem`, `GradingPolicyInfo`,
  `DisagreementAssessment` + converters; `ReviewMarkersResponse` gained **optional** fields
  (`schema_version`, `lesion_evidence`, `criteria_evaluation`, `grading_policy`, `disagreement`).
- `src/services/marker_service.py` — fetches the stored CNN grade for the review case and
  attaches the evidence extension (legacy shape retained on failure).
- `api/services/ai_bridge.py` — `analyze_retina` now returns the extension; a material
  conflict escalates the **existing** review path via `dataclasses.replace` (the CNN grade is
  never overwritten).
- `src/reporting/pdf_generator.py` — optional "Grading Criteria Evidence" section
  (criterion table + policy version + reconciliation line), backward compatible.
- `demo/clinical_screens_34.py` — the referral screen feeds the report from the same seam.

**Changed (Flutter):**
- `lib/models/retinal_markers.dart` — typed extension models (unknown enums → explicit
  `unknown`, never a crash; legacy payloads parse unchanged).
- `lib/widgets/review/lesion_marker_painter.dart` — evidence-aware rendering
  (type-coloured rings), selection emphasis, dimming, criterion→marker highlight; a v1 payload
  never falls back to the legacy coordinate list (no double-draw).
- `lib/widgets/review/zoomable_fundus_screen.dart` — tap-to-select with zoom-correct inverse
  mapping + evidence detail bar (type, status, notes, criterion chips).
- `lib/models/screening.dart`, `lib/models/screening_models.dart`, `lib/services/api_service.dart`
  — the screening payload carries the extension end-to-end.
- `lib/screens/flow/flow_result_screen.dart` — criteria card ("why this grade") + disagreement banner.
- `lib/l10n/evidence_strings.dart` — en/hi presentation strings (`context.ev(...)`).
- `lib/screens/flow/flow_capture_screen.dart` — first-contact fix (no auto-preloaded sample),
  sanitised errors, operator-friendly sample labels.

**Performance / design mods (this request):**
- `lib/main.dart` — root `textScaler` clamp to **1.0×–1.25×** (one place, inherited by all screens).
- `lib/services/ml/on_device_pipeline.dart` — `qualityGateComputeWorker` (top-level) runs decode +
  gate assessment on a background isolate via `compute`; `checkQualityOnDevice` is now `Future`.
- `lib/widgets/scanner/scanner_view.dart` — rebuilt on `flutter_layout_grid` 2.0.8 with three rigid
  tracks (**56 px status / 1 fr canvas / 140 px telemetry**); HUD is no longer painted over the canvas.
- `lib/widgets/glass/glass_console.dart` — glassmorphic console primitives: `BackdropFilter`
  blur σ16, `#020617` opacity-mapped base, `#00FFCC` micro-border, explicit `maxLines` +
  `TextOverflow.fade` on every label, blur disabled under reduced-motion.

## 3. Data-contract changes (real example payload)

```json
{
  "review_id": "REV-8F3A21C0B4D7",
  "available": true,
  "source": "classical_cv_segmentation",
  "width": 2240, "height": 1680,
  "ma_candidates": [{"x": 1204, "y": 933, "r": 5}],
  "schema_version": "1.0",
  "lesion_evidence": [{
    "lesion_id": "LE-0001",
    "lesion_type": "microaneurysm_candidate",
    "detection_status": "detected",
    "x": 1204, "y": 933, "radius": 5,
    "geometry_type": "circle",
    "detector_id": "classical_cv_segmenter", "detector_version": "1.0",
    "criterion_links": ["icdrss.ma_present", "icdrss.fovea_involvement"],
    "evidence_notes": ["Classical-CV candidate (dark focal spot); not a confirmed lesion."],
    "image_width": 2240, "image_height": 1680
  }],
  "criteria_evaluation": [{
    "criterion_id": "icdrss.ma_present", "status": "satisfied",
    "supporting_evidence_ids": ["LE-0001"], "contradicting_evidence_ids": [],
    "reason_codes": ["DETECTOR_RAN", "CANDIDATES_PRESENT", "CANDIDATES_ARE_NOT_CONFIRMED_LESIONS"],
    "explanation_key": "criterion_ma_present"
  }],
  "grading_policy": {
    "policy_id": "icdrss-subset", "policy_version": "1.0",
    "framework": "International Clinical Diabetic Retinopathy (ICDRS) severity scale"
  },
  "disagreement": {
    "status": "adjacent", "reason_codes": ["CANDIDATES_PRESENT", "EVIDENCE_ADJACENT"],
    "review_required": false, "cnn_grade": 2, "evidence_implied_grade": 1,
    "explanation_key": "disagreement_adjacent",
    "policy_id": "icdrss-subset", "policy_version": "1.0"
  }
}
```

Legacy payloads (no `schema_version`) parse unchanged — verified by the existing marker
tests and by `tests/contract/test_evidence_payload_wire_format.py`.

## 4. Implemented criteria and their documented sources

| Criterion | Source | Implemented |
|---|---|---|
| `icdrss.ma_present` | ICDRS level ≥ 1 (MA only) | ✅ (candidates — not confirmed lesions) |
| `icdrss.exudate_present` | ICDRS level ≥ 2 | ✅ (classical bright-lesion heuristic) |
| `icdrss.fovea_involvement` | project CSME rule (lesion < 1.5 × OD radius from fovea) | ✅ (landmark-reliability gated) |
| `icdrss.venous_beading` | ICDRS level 3 | ❌ **not evaluated** (no detector) |
| `icdrss.neovascularization` | ICDRS level 4 | ❌ **not evaluated** (no detector) |

**Intentionally unsupported:** venous beading, IRMA, neovascularisation, preretinal
haemorrhage. The repository contains no IDRiD pixel-level annotations (only the EyePACS
parquet), so these cannot be implemented or validated here. They are returned as
`not_evaluated` with `DETECTOR_NOT_IMPLEMENTED` — **never inferred absent**, and the
evidence-implied grade always carries `upper_bound_indeterminate = true`.

## 5. Lesion→criterion navigation

- Backend: each lesion carries `criterion_links`; each criterion carries
  `supporting_evidence_ids` — a bidirectional, auditable link (the contract test asserts every
  link resolves to a real evidence object).
- Flutter: tap a marker in the full-screen inspector → evidence bar (type, detection status,
  notes) with **criterion chips** for the criteria that marker supports; tapping a chip
  highlights every supporting marker on the canvas (cyan ring) and lists them in the
  criteria card on the result screen.

## 6. Disagreement and escalation

| Situation | Status | Review |
|---|---|---|
| CNN grade == implied level | `match` | no |
| ±1 level | `adjacent` | advisory only (mapping unvalidated) |
| ≥2 levels apart | `conflict` | **yes** — review path updated, CNN grade preserved |
| Detector failed / criteria not evaluable | `incomplete` | no (advisory, mirrors the repo's biomarker rule) |
| No candidates detected | `not_asserted` | no — absence is **not** negative evidence |
| CNN grade missing/invalid | `model_unavailable` | **yes** |

The ≥2 conflict window is a **deterministic rule, not a clinically validated threshold** —
documented as such in the module docstring.

## 7. Tests executed (exact commands, real results)

```
venv\Scripts\python.exe -m pytest tests\unit tests\integration tests\contract tests\edge_cases tests\red_team -q
   → 273 passed, 148 subtests passed (5m15s)
flutter test            → 348 passed (2m59s)
flutter analyze         → No issues found
ruff check src api tests demo → clean on all touched files
```

New suites: `tests/unit/test_grading_policy.py`, `tests/unit/test_evidence_normalization.py`,
`tests/unit/test_disagreement.py`, `tests/contract/test_evidence_payload_wire_format.py`,
`tests/contract/test_evidence_failure_injection.py`, `flutter_app/test/evidence_payload_test.dart`.

## 8. Performance and measurements

- Quality-gate decode+assess now runs off the UI isolate (`compute`): the 12 MP decode and the
  O(analysis pixels) gate no longer block the Flame game loop during capture.
- Text scaling is clamped app-wide (1.0×–1.25×), so HUD rows and the 320 dp wizard matrices
  cannot be shattered by OS font settings.
- The scanner console is a rigid 3-track grid: overlap is structurally impossible (no
  `Positioned` HUD over the canvas any more).
- `BackdropFilter` is used exactly twice per scanner view and is disabled under
  reduced-motion (a backdrop blur is a saveLayer).

## 9. Known limitations and residual risks

1. **The implied grade is an explanatory artifact, not a grade.** The CNN grade remains the
   prediction; the criteria explain it. The ICDRS subset cannot exclude levels 3–4.
2. **Candidates ≠ lesions.** MA/exudate detections are classical-CV heuristics; their
   specificity is unvalidated. Every payload labels them "candidate — not a confirmed lesion".
3. **On-device path has no criteria.** The Dart port computes markers only; criteria require the
   server path. The result screen shows an explicit unavailable state rather than inventing one.
4. **Detector sensitivity is unmeasured** — no IDRiD pixel annotations exist in-repo.
5. **The Grad-CAM XAI gate still FAILS** (pre-existing, documented in
   `docs/EVALUATION_RESULTS.md` §7.6): heatmaps are labelled attention, not evidence.
6. **Threshold-dependent decisions are unvalidated**: the ≥2-level conflict window and the
   1.5×OD-radius fovea rule are deterministic but not clinically validated.

## 10. Work deferred (and why)

- **Haemorrhage detector** — deferred, per the contract's guard: no annotated data (IDRiD) is
  present, and an unvalidated heuristic must not influence a clinical grade. Neovascularisation
  detection is **not claimed at all**.
- **Dart port of the criteria engine** — deferred: the on-device path stays evidence-only, so
  offline screens never show a fabricated criterion state.
- **FHIR extension** — the FHIR exporter keeps its existing (already-tested) NullFlavor
  semantics; criteria were not added to the FHIR resource in this pass.

## 11. Manual end-to-end demo checklist

1. `streamlit run demo/app.py` → wizard step 1 (patient intake) → step 2 (capture) → pick
   "Case 4: Severe Retinal Lesions" → step 3: **criteria card** must list
   `icdrss.ma_present` / `icdrss.exudate_present` with support counts, plus the policy line
   `icdrss-subset v1.0` and the upper-bound note; disagreement banner shows
   `match`/`adjacent`/`conflict`.
2. Step 3 "Inspect & zoom" → tap a marker → evidence bar with type + notes + criterion chips →
   tap a chip → supporting markers highlight in cyan.
3. Step 4 → download the PDF → the "Grading Criteria Evidence" table is present.
4. Flutter app: `flutter run -d windows` → capture screen opens **empty** (no preloaded sample);
   "Use camera" is the primary CTA; upload/sample errors are operator-worded, never raw
   exceptions; large OS fonts stay clamped (1.25× max).
5. `flutter test` + `pytest` must be green before demo.

## 12. Implemented vs proposed

**Implemented:** versioned evidence contract (Python + Dart), ICDRS-subset criteria engine,
typed lesion evidence with stable ids and coordinate integrity, deterministic disagreement
policy with escalation, criterion↔evidence navigation in Flutter, criteria + disagreement
surfaces in the result screen and the PDF report, capture first-contact fix, text-scaler clamp,
background-isolated quality gate, LayoutGrid scanner console, glassmorphic console language.

**Proposed (not built):** validated haemorrhage/neovascularisation detectors with IDRiD,
Dart criteria port for fully offline evidence explanation, multi-site prospective validation
programme, XAI-gate-passing retrain (F-5).
