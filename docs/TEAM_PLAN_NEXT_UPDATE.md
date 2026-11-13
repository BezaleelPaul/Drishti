# Drishti — Team Plan: Next Update Cycle ("Phone Becomes the Screening Unit")

**Platform:** Drishti Autonomous Clinical AI Screening System
**Sprint:** 21 days · **Budget:** 43.5 person-days (6 people) · Freeze at Day 16
**Goal:** Convert the server-round-trip Flutter app into a fully offline, on-device AI screening system for low-end Android, with zero cloud PHI storage and consent-gated de-identified tele-referral.

---

## ⚡ EXECUTION STATUS (2026-09-28) — read this first

| Ticket | Status | Evidence |
|---|---|---|
| A-1 conversion | ✅ **RUN** — fp32 **SHIPPED** (15.3 MB, 2.2× smaller than keras source) | `flutter_app/assets/models/dr_efficientnet_b0_fp32.tflite`; parity **100% top-1 agreement** (`results/tflite_parity_fp32_*.json`) |
| A-1 fp16 | ❌ **REJECTED BY GATE** — 83.3% agreement, 0.29 max prob drift | `results/tflite_parity_fp16_clinical.json` — the gate did its job; do NOT downgrade to fp16 for size |
| A-1 int8 | ⏳ pending real calibration corpus (≥400 stratified images, never the test split); converter + gates ready | `scripts/convert/` |
| A-2/A-3 Dart ML layer | ✅ shipped & wired (orchestrator in capture + analysis flow, on-device-first ladder) | `flutter_app/lib/services/ml/` |
| B-1/B-2 offline store | ✅ SQLCipher queue + screening store, kill-safe write-through, boot rehydration | `local_store.dart`, `offline_queue_service.dart` |
| C-1..C-5 privacy | ✅ complete (de-id, consent UI + service, fail-closed `/sync/v2` + PHI linter + value-redacted 422s, retention both sides, no-analytics CI gate) | `tests/integration/test_deidentified_sync.py` (20 tests) |
| D-1/D-2 referral uplink | ✅ consent → de-id payload → lint → `/sync/v2` → store-and-forward → boot flush; doctor visibility (`/sync/v2/pending`, image) | `referral_uplink_service.dart`, `consent_screen.dart` |
| X-0 operating point | ✅ adopted (t\*=0.09; sens 0.213→0.623 held-out) | `docs/EVALUATION_RESULTS.md` |
| X-1 XAI validation | ✅ **built — result: FAIL (honest)**. Grad-CAM ordering does not beat random on deletion on any tested image; heatmaps stay "attention, not evidence" until the F-5 retrain re-passes this gate | `validate_xai.py`, `results/xai_insertion_deletion.json`, `docs/EVALUATION_RESULTS.md` §7.6 |
| E-2 latency display | ✅ measured ms on result screen ("on-device • N ms") | `flow_result_screen.dart` |
| E-1 device matrix | ⬜ **the only hardware-blocked item** | needs 2GB Android + 2 more phones |
| Verification state | Dart `flutter analyze` 0 errors/warnings · **40/40 tests** · Python **107 tests + 119 subtests** · rehearsal 13 steps/23 assertions all_ok | CI green |

**Remaining human actions:** (1) run E-1 on real phones (the app is ready — airplane-mode demo works as soon as the app is installed; the model is IN the APK now), (2) optional int8 size upgrade when a calibration corpus is downloaded, (3) F-5 retrain post-release.

---

## 0. TL;DR — the mandate in one paragraph

The phone runs the entire screening pipeline **locally and offline**: quality gate (Dart port of `checker.py` with byte-identical thresholds/reason codes) → int8 TFLite DR classifier → confidence gate → routing (recapture cap 2, referable ⇒ mandatory review flag) → encrypted local store. The server becomes an **optional, consent-gated doctor console** that receives ONLY pseudonymized, image-cropped, metadata-stripped payloads in batches ≤3 — and fails closed on any PHI. Internet is used for exactly one thing: referral over-read. Everything else works with airplane mode on.

---

## 1. Ground truth — verified brutal truths (read this first)

We audited every claim. These are FACTS, fixed by reading the code:

| # | Claim in our docs | Reality |
|---|---|---|
| 1 | README: "Inference runs on-device… zero cloud compute" | **FALSE for mobile.** Every analysis POSTs to FastAPI (`api_service.dart` → `/retinal/analyze`). Offline today = "PENDING_SYNC" placeholder, **no grade ever assigned on-device**. |
| 2 | On-device inference exists | **NO.** Zero inference plugins in pubspec, zero `.tflite`/`.onnx` assets, no conversion tooling anywhere. |
| 3 | Offline queue is persisted | **NO.** `static final List` — lost on restart (comment says so at `api_service.dart:47-50`). |
| 4 | `docs/HARDWARE_COMPATIBILITY.md`: "ASHA Tablet < 220 ms — VERIFIED" | **Unbacked by any code.** Never repeat to judges. |
| 5 | Camera capture | **NO camera.** Capture screen uses file_picker + bundled JPEGs; no `CAMERA` permission in manifest. |
| 6 | Release build works | Latent bug: release `AndroidManifest.xml` has **no INTERNET permission** (debug/profile only). Fix or note. |
| 7 | Streamlit app | The app file was **deleted** (commit 2a128d6); `.streamlit/config.toml` is a leftover; BRUTAL_CRITIQUE + PPT docs still reference it. Docs/reality mismatch — clean up. |

**What is genuinely strong (keep and weaponize):** 11-node pipeline with safety invariants, adversarial red-team corpus (14/14 rejected, CI-gated), idempotent sync receipts, retention/audit discipline, honest external eval (71.5% Top-1, sens 0.213, spec 0.970, ECE 0.064), bilingual 5-language UI, demo rehearsal green ×2, 76-subtest CI sweep. The clinical honesty ("triage-assist, never autonomous") is our strongest judge card — do not soften it.

---

## 2. Locked architecture decisions

| Layer | Decision | Rejected (why) |
|---|---|---|
| App | Flutter `flutter_app/` (netra_ai_mobile) — existing 21 screens | Native rewrite (2 weeks lost) |
| Inference runtime | **`flutter_litert` 3.8.0** (bundles LiteRT 1.4.2 / TFLite 2.20) | `onnxruntime_flutter ^0.1.0` (stale pin, extra conversion hop), `tflite_flutter` (archived upstream) |
| Delegate | **CPU + XNNPACK, 2 threads** (prod default) | NNAPI (deprecated), GPU delegate (SIGSEGV/NaN on budget Mali/MediaTek) |
| Model artifact | **int8 TFLite, float in/out**, dual-output graph (softmax + 7×7×1280 conv map for Grad-CAM) — expect 13–17 MB | Score-CAM on-device (~1280 forwards — minutes on A53) |
| Fallback ladder | int8 float-IO (dynamic) → fp16 (~16 MB) → ONNX (`flutter_onnxruntime` ≥1.8.1) | — |
| Local store | **`sqflite_sqlcipher`**, key via `flutter_secure_storage` (Keystore) | plain sqflite / drift |
| Camera | `camera` plugin | platform-channel custom |
| State | Riverpod (replaces mutable `FlowState` + static in-memory `ApiService.offlineQueue`) | BLoC |
| Server | FastAPI unchanged + new `POST /sync/v2` (de-identified, **no server-side inference** — removes the multi-second in-request inference at `sync.py:137`) | — |

### 2.1 Conversion recipe (single source of truth — `scripts/convert/`)

1. `keras.saving.load_model("final_model.keras")` → `model.export("export_sm/")` (SavedModel; **not** torch — there is no `.pth`, our artifact is Keras).
2. Representative dataset: 400 stratified images — 300 good EyePACS + 50 augmented + 50 adversarial from `test_samples/03_adversarial_non_fundus/`.
3. `TFLiteConverter.from_saved_model`, `Optimize.DEFAULT`, `TFLITE_BUILTINS_INT8`, **float32 in/out** (normalization lives inside the graph: `Rescaling(÷255) → Normalization → Rescaling(2.09)` — verified inside the .keras file).
4. Rebuild graph with 2nd output = final conv activation map; convert the dual-output graph.
5. Parity gate: 500 stratified images, keras vs tflite — **ΔQWK ≤ −0.02, referable-sens drop ≤ 1.0 pp, top-1 agreement ≥ 99.2%**, else FAIL → fall down the ladder.
6. Budget gate: `benchmark_latency.py` refactored to run the interpreter — warm ≤ 620 ms, RSS ≤ 300 MB.

### 2.2 Dart preprocessing parity contract (the silent killer — do not "improve" it)

```dart
final resized = img.copyResize(decoded, width: 224, height: 224,
    interpolation: img.Interpolation.cubic);   // bicubic = PIL parity, NOT bilinear
final buffer = Float32List(1 * 224 * 224 * 3); // NHWC, not NCHW [1,3,224,224]
for (int y = 0; y < 224; y++)
  for (int x = 0; x < 224; x++) {
    final p = resized.getPixel(x, y);
    buffer[i++] = p.r.toDouble();              // raw 0..255 — NO ImageNet
    buffer[i++] = p.g.toDouble();              // normalization; the graph
    buffer[i++] = p.b.toDouble();              // does it all internally
  }
const inputShape = [1, 224, 224, 3];
```

Any ImageNet `(p/255−mean)/std` math in Dart = double normalization = silent accuracy destruction. Softmax probs (not logits) feed the confidence gate (0.60 / 0.15 margin; grades 3/4 always flagged). Quality-gate Dart port uses the exact `checker.py` constants (blur 15/85, brightness 40–210/20–235, contrast 16/7, FOV 0.35/0.15, red:blue 1.10, ML-quality 0.70/0.38 — deterministic fusion only; the 10-model DL ensemble is documented as a parity gap) and identical reason-code strings (`IMG_NOT_FUNDUS`, `IMG_UNGRADABLE`, `SEVERE_BLUR`, …). Thresholds ship as a **generated Dart constant file** so Python retunes can't drift silently.

---

## 3. Roadmap — phases, tickets, owners, gates

Owners: **Bezaleel** (lead/arch) · **Akshay** (DL/Ops) · **Adithya** (safety/verification) · **Madhu** (clinical) · **Sinduri** (ASHA UX) · **Megha** (doctor UX).

### Phase A — P0: On-device inference (Days 1–5) — everything depends on this

| Ticket | What | Files | Owner | pd | Gate |
|---|---|---|---|---|---|
| A-1 | Keras→int8 TFLite conversion spike + parity script | new `scripts/convert/convert_to_tflite.py`, `validate_tflite_quantized.py` | Akshay + Bezaleel | 2 | Parity gates above; **2-day timebox then switch to ladder** |
| A-2 | Dart TFLite inference service | new `lib/services/ml/dr_classifier.dart`; asset `assets/models/dr_efficientnet_b0_int8.tflite`; pubspec `flutter_litert: 3.8.0` | Bezaleel | 2 | 500-image golden parity: per-class abs diff ≤0.015 |
| A-3 | Quality gate Dart port + codegen'd thresholds | new `lib/services/ml/quality_gate.dart`, `quality_thresholds.dart`, `pipeline_schema.dart` (byte-identical enum strings) | Madhu + Bezaleel | 2 | All 14 adversarial fixtures rejected on-device, identical codes |
| A-4 | Recapture loop, cap 2, force-human flag | `flow_capture_screen.dart`, `flow_state.dart` (router spec) | Sinduri | 1 | Router parity on 20 fixtures ≥0.95 agreement |
| A-5 | Device latency/RSS benchmark | extend `benchmark_latency.py` → `results/tflite_benchmark.json` | Adithya | 1.5 | warm ≤1.5 s e2e, RSS ≤300 MB on 2 GB-class device |

**TFLite ConfidenceEvaluator port** (0.60/0.15, NaN fail-closed, confidence==max(probs)) folds into A-2/A-4.

### Phase B — P0: Offline-first persistent store & resilience (Days 6–8)

| Ticket | What | Files | Owner | pd |
|---|---|---|---|---|
| B-1 | SQLCipher store: `patients, screenings, sync_queue, sync_receipts, consent_records, audit_log_local` (+WAL, FK, 30s busy_timeout — mirror `api/database.py` PRAGMAs) | new `lib/services/db/app_database.dart`; pubspec `sqflite_sqlcipher`, `path_provider`, `flutter_secure_storage` | Bezaleel | 2 |
| B-2 | Persistent queue, idempotent sync client, **split the 840-line `api_service.dart`** | `offline_queue_service.dart`, `sync_engine.dart` | Bezaleel | 1.5 |
| B-3 | Connectivity UI: 3rd state "LAN/hotspot in range"; flow never gates on network | `connectivity_banner.dart`, `queue_screen.dart`, `figma_dashboard_screen.dart` | Sinduri | 1 |
| B-4 | Kill/restart survival tests (6 kill windows; `adb shell am kill` under load) | new `integration_test/offline_restart_test.dart` | Adithya | 1.5 |

### Phase C — P0: Privacy (parallel, Days 6–8)

| Ticket | What | Owner | pd |
|---|---|---|---|
| C-1 | Data policy: no PHI leaves device without consent; verify `allowBackup=false`, no analytics SDK (grep-test in CI) | Bezaleel + Adithya | 1 |
| C-2 | De-identification module: per-device salted HMAC pseudonym, EXIF strip, FOV-only crop, age-banding | Madhu | 1.5 |
| C-3 | Consent flow screen (per-patient, versioned, bilingual, withdrawal path; default = refuse) | Megha | 1 |
| C-4 | Server `/sync/v2`: de-identified-only schema, fail-closed PHI linter (regex tripwires +91/ABHA/name-regex, ≤3 batches, rejected payloads NOT persisted); tests `tests/integration/test_deidentified_sync.py` | Adithya + Bezaleel | 2 |
| C-5 | On-device retention purge (mirror `api/retention.py`; images destroyed after ACK) | Madhu | 0.5 |

### Phase D — P1: Referral = the only internet path (Days 9–11)

| Ticket | What | Owner | pd |
|---|---|---|---|
| D-1 | Offline bilingual referral slip (urgency from grade+flags; no hardcoded "4 weeks") | Sinduri + Megha | 2 |
| D-2 | Uplink ONLY referable/low-confidence/unresolved-quality cases; ≤3/batch; ~650 KB ≈ 90–120 s on 2G; background Isolate upload | Bezaleel + Akshay | 1.5 |
| D-3 | Doctor console verification over 2G throttle (Streamlit console may remain as internal over-read UI until Flutter doctor screen covers it) | Megha | 1 |
| D-4 | ONNX fallback conversion (only if trigger fired) | Akshay | (1.5 contingent) |

### Phase E — P1: Hardening (Days 12–14)

E-1 device matrix (6 devices, Android 8–14, 2 GB worst — 10-patient airplane-mode camp loop, thermal soak) — Adithya+Sinduri 2pd · E-2 on-device latency display in `system_specs_screen.dart` (honest measured numbers) — Akshay 1pd · E-3 crash guards + `IMG_INFEASIBLE` fallback to operator review (never a fake grade) — Bezaleel 1.5pd · E-4 Streamlit farewell: delete stale `.streamlit/config.toml`, fix doc references — Bezaleel+Megha 0.5pd.

### X — NEW from this review (the only additions to the plan)

| Ticket | What | Owner | pd |
|---|---|---|---|
| X-1 **Insertion/Deletion XAI validation** | Prove heatmaps are truthful: delete Grad-CAM-highlighted pixels → confidence must collapse to ~0; report Deletion AUC in `results/` | Akshay | **1.0** |
| X-0 **Adopt operating point t\*=0.09** | Free sensitivity win already measured: referable sens 0.213→**0.623** (spec 0.970→0.775). Update docs/UI/sweep defaults; re-verify fixtures | Adithya | 0.5 |

**Budget: 42 → 43.5 pd.** That is the entire delta. Nothing else enters the sprint.

### Phase F — P2 backlog (post-release, do NOT start in sprint)

F-1 on-device Grad-CAM polish · F-2 DL segmentation (dual-head, **focal Tversky α0.3/β0.7**, needs IDRiD masks + distillation) · F-3 CLI-equivalent hardening/Keystore rotation · F-4 per-operator data ownership · **F-5 retrain program (§4)** · F-6 extend l10n to 8 languages · F-7 CoreML/iOS · F-8 Postgres/Redis/multi-worker · F-9 real fundus-camera SDK integration (Remidio/Forus/Volk — blocked on device loans).

---

## 4. ML quality track — the honest accuracy story

**Where we are (verified):** Top-1 71.5% · macro-F1 0.26 · QWK 0.31 · referable sens **0.213** / spec 0.970 · severe recall **0/70** · ECE 0.064. The model collapses onto majority No-DR — textbook imbalance failure.

| Step | Cost | Expected referable sensitivity |
|---|---|---|
| Now | — | 21.3% |
| **X-0 operating-point swap (no training)** | 0.5 pd | **62.3%** (spec falls to 77.5% — report the tradeoff, don't hide it) |
| F-5 retrain: **focal loss (γ≈2) + class weights + stratified oversampling (grades 2–4 to ~10% each) + hard-negative mining** from `results/labeled_evaluation.json` (borderline misclassifications up-weighted) | 2–3 pd + gates | 60–75% first pass → 80–90% after 2–3 iterations |
| F-5b **ordinal cross-entropy** (cumulative targets [1,0,0,0]→[1,1,1,0]) folded into F-5 | same retrain | protects QWK + prevents Stage 3→0 distant errors |
| Clinical bar (deep pipeline) | — | 87–95% (IDx 87.2 / Thailand 91.4 / Remidio 93–100) |

**Brutal rules:** (1) F-5 is **NOT in the sprint** — pulling it in costs +4–5 pd (retrain + ECE re-check + quantization + parity redone) and would eat all float, risking the P0 offline pipeline. (2) Any loss change shifts calibration — re-run `evaluate_calibration.py` + `operating_point_sweep.py`; ECE must stay ≤0.10 or the 0.60/0.15 confidence gates are invalid. (3) Never SMOTE raw pixels — non-physical images, LLVM of the eye world. (4) Top-1 accuracy may DROP to 65–72% while sensitivity rises — that is progress; say so in the deck.

---

## 5. Privacy contract (DPDP-aligned) — what may ever leave the device

| Element | Leaves? | Form |
|---|---|---|
| Original fundus image | **NEVER** | Encrypted local file, destroyed after sync ACK |
| Patient name / phone / ABHA / village | **NEVER, no field exists in v2 wire schema** | — (fail-closed linter) |
| Screened image | Only per-patient explicit consent | FOV-crop, ≤512px, EXIF stripped, random token |
| Grade/probs/confidence | Only consented | ≤300 B JSON |
| Age/gender | Only consented | coarse age band (÷10) |
| Pseudonym salt | never | one-way HMAC only |

Consent = separate itemized toggles in the patient's language (DPDP S.5/6 + Rules 2025), withdraw-with-ease, age gate <18 exits, TTL purge, breach surface ≈ 0 (nothing cloud-side). **Mandatory UI banner per MoHFW Telemedicine Guidelines 2020 §5.4: "AI is a screening aid — final decision by a registered medical practitioner."** Never say "anonymized" (vessel topology is biometric); say "de-identified upload: cropped, metadata-stripped, random token." DPDP note: no hard health-data localization exists — do NOT pitch "stored in India" as compliance.

---

## 6. Rejected-advice log (so nobody re-pitches; answers already researched)

| External suggestion | Verdict |
|---|---|
| BRISQUE/NIQE quality gate | Skip — ours is fundus-calibrated (FRR 6.9%); BRISQUE isn't fundus-tuned, adds Dart porting risk |
| Score-CAM on-device | Impossible edge cost (~1280 forwards/image); server-only if ever |
| ONNX as primary / `onnxruntime_flutter ^0.1.0` + ImageNet normalization in Dart + NCHW | Wrong source of truth (Keras not torch), stale pin, **double-normalization bug**, wrong layout. Use §2.1–2.2 verbatim |
| TensorRT | NVIDIA-only; phones are XNNPACK/LiteRT territory |
| Swap to MobileNetV4/EfficientNet-Edge backbone | No — we have a trained+evaluated B0; fix loss first; new backbone is a P2 training arm |
| SMOTE on images | Tabular-only technique; use focal+weights+oversampling |
| LLM/zero-shot labeling of fundus images | Never — APTOS ground truth is verified; LLM labeling = accuracy + regulatory liability |

---

## 7. Demo script (8–9 min, airplane mode)

1. Problem framing — "AI grades garbage confidently." 2. **Airplane mode ON first.** 3. Register patient (bilingual, device-local). 4. Bad capture → on-device rejection + reason code, max-2 loop, force-human flag. 5. Adversarial fixture → `IMG_NOT_FUNDUS`, no grade ever produced. 6. Good capture → grade + confidence + **measured ms on screen**. 7. Kill app, relaunch → history intact (persistence proof). 8. Consent-gated de-identified referral over throttled hotspot → laptop doctor queue, clinician verdict signed. 9. Scale story + honest numbers: X-0 sensitivity table, 71.5% Top-1 disclosed, evaluation-results appendix. **Fallback:** pre-recorded video of #6 on the worst device + 4.8 MB model story if demo-day hardware fails.

---

## 8. Cut list (invoke in this order) + never-cut invariants

Cut: F-7 CoreML → D-4 fallback (if unused) → C-5 auto-purge (manual delete ships) → E-2 HUD → D-2 batching polish → D-4 on-device Grad-CAM → Streamlit analytics port (keep as console).
**Never cut:** gate fidelity, recapture cap 2, de-id-before-sync, consent gate, quantized parity suite, ≥3-device matrix evidence, RMP banner. If on-device ourselves fails by Day 5: present laptop-console demo with capture flow + pitch v1.2 benchmark-in-waiting — never fake a grade.

---

## 9. Definition of done

- [ ] 14/14 adversarial fixtures rejected on-device, zero DR grades from garbage
- [ ] warm e2e ≤1.5 s, peak RSS ≤300 MB on worst device; `results/tflite_benchmark.json` + device matrix table
- [ ] Airplane-mode camp loop (10 patients, 2 kills) → zero loss, no duplicate IDs after one sync
- [ ] Consent refused ⇒ zero outbound HTTP (integration test); any PHI in a de-identified batch ⇒ pytest FAIL
- [ ] All existing gates green: pytest suites, `verify_complete_system.py`, `demo_rehearsal.py`, `flutter analyze/test`, CI extended with parity suites
- [ ] X-0 adopted + documented; X-1 deletion AUC reported; README/HARDWARE_COMPATIBILITY claims corrected (§1 items 1,4)
- [ ] 5 rehearsal runs incl. airplane-mode-only and 2G-throttle runs

---

## 10. Milestones

M0 (Day 2): A-1 spike go/no-go · M1 (Day 5): on-device grade on phone + store live · M2 (Day 8): kill/restart survival + de-id module · M3 (Day 11): consent uplink + referral over 2G sim · M4 (Day 14): device matrix + crash guards · M5 (Day 15–16): freeze, doc/deck regen, rehearsal ×2 · Days 17–18: demo polish ×5.
