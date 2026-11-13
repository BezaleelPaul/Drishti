# RETFound Feasibility Assessment (on-device TFLite vs edge-server vs distillation)

> Verdict up front: **full RETFound cannot run on the phone** (architecture is
> ViT-Large/16, ~305 M parameters, ~1.2 GB fp32, 224×224 input — roughly 20×
> our shipped model's storage and ~30× its compute). It **can** run on the
> edge server via the official Keras port, and its **realistic on-device path
> is knowledge distillation into our existing EfficientNetB0 student**, which
> requires no pipeline rewrite. Details and step plan below.

## 1. Facts gathered (from the official repos)

| Item | Value |
|---|---|
| Official PyTorch (weights, fine-tuning) | `github.com/rmaphoh/RETFound_MAE` — 688★, HF-gated weights (`YukunZhou/RETFound_mae_natureCFP` — requires an HF account + access form) |
| Official **Keras** port | `github.com/uw-biomedical-ml/RETFound_MAE` — TF 2.8.3, Python 3.9 conda env, `tfimm`; CFP `.h5` weights on a public Google Drive link; fine-tunes on IDRiD/APTOS/MESSIDOR2 by example |
| Architecture | `vit_large_patch16_224_mae` — ViT-L/16, **~300 M params** (repo's own size table) |
| Input | **224×224** (not 512) |
| Pretrained size | ~305 M × 4 B ≈ **1.2 GB fp32**; int8 ≈ **~305 MB** |
| Paper metric to beat | Adapted to APTOS/IDRiD etc. with label-efficient fine-tuning (Nature 2023, Fig. 3: positive NI/AUROC gains over ImageNet-pretrained transfer) |
| Free-GPU route | Colab notebook linked in the repo (free T4 GPU) — fine-tuning/distillation does NOT need our own GPU |

## 2. Comparison against our shipped on-device model

Our path runs `drdetect_ordinal_512_fp32.tflite` = **15.3 MB**, 512×512 NHWC,
~0.6–1.2 s warm inference in the worker isolate on an arm64 phone.

| Metric | DrDetect ordinal (shipped) | RETFound ViT-L/16, int8 | RETFound ViT-L/16, fp32 |
|---|---|---|---|
| Storage | 15.3 MB | ~305 MB | ~1.2 GB |
| Compute @ input | ~2 G FLOPs (512²) | ~61 G FLOPs (224²) | same |
| Est. CPU latency (phone) | ~0.6–1.2 s | **tens of seconds** | unusable |
| Est. GPU-delegate latency (flagship) | — | ~2–5 s | ~8–15 s |
| APK impact | — | +305 MB asset | explodes the APK |

**Conclusion — on-device RETFound: NOT feasible.** Even the int8 variant is
20× the shipped asset, blows the APK by ~1/3 GB, and runs at wall-clock
latency that breaks the ≤1.4 s field budget, on a model that still needs to
prove its APTOS-domain accuracy first (our measured referable sensitivity on
out-of-distribution data is already the weak point we are trying to fix — a
30×-slower teacher does not fix the phone, it fixes the teacher).

## 3. The three viable paths

### Path A — RETFound on the edge server (Keras port) — *doable today-adjacent*

Swap `on_device_pipeline`'s server-side classifier (currently
`DR-EfficientNetB0/final_model.keras`, 33.4 MB) for the Keras-port
RETFound CFP weights + an APTOS fine-tune head:

1. Conda env `python=3.9`, `tensorflow==2.8.3`, `tfimm` (per port README).
2. `tfimm.create_model("vit_large_patch16_224_mae", nb_classes=5)`,
   load `RETFound_cfp_weights.h5`, fine-tune head on APTOS (their
   `main_finetune.py` does IDRiD by example — APTOS is the same 5-class
   shape; the repo's `BENCHMARK.md` even ships standard splits and
   checkpoints for APTOS/IDRiD/MESSIDOR2).
3. Serve through the existing `/retinal/analyze` bridge; preprocessing: keep
   Ben-Graham + ImageNet mean/std, resize **512→224**.

Cost: ~1–3 s/image CPU on a laptop (fits the edge-server path; NOT the
current free-tier Render, which already OOMs on EfficientNetB0).

### Path B — knowledge distillation: RETFound → EfficientNetB0 student — *the on-device route*

- Teacher: RETFound_CFP fine-tuned on APTOS (Colab, free T4).
- Student: **our existing EfficientNetB0** (same architecture already in the
  APK — 15.3 MB fp32 / ~4 MB int8).
- Recipe: hard labels APTOS + soft labels from the teacher (α≈0.9, T≈4),
  50 epochs — the MoE standard recipe from the paper's own fine-tuning
  protocol adapted for distillation.
- Export to TFLite fp32 + int8, then run the **existing golden-parity
  harness** with a new preprocessing config (`input_size=224` — same
  ImageNet stats the preprocessor already supports).
- Result: a lineage-backed backbone ("descends from Nature-2023 RETFound")
  at identical APK size/latency. No pipeline code changes.

### Path C — evaluate the released fine-tuned checkpoint as-is

`BENCHMARK.md` publishes fine-tuned checkpoints + data splits for APTOS and
IDRiD. Least training: download the APTOS checkpoint, evaluate it on a held
out split with the Gulshan-format reporting plan
(`docs/research/GOOGLE_DR_BENCHMARKS.md` §3), and use its **soft labels** to
distill (Path B) without ever fine-tuning the teacher ourselves.

## 4. What blocks us locally TODAY (honest list)

1. **No TensorFlow on this laptop** (Python 3.14 only; TF 2.8 needs 3.9,
   current TF needs ≤3.12) — conversion/fine-tuning must happen in Colab or
   a second conda env. `py --version` → 3.14.5.
2. **HF-gated weights** require a registered account + access request
   (gated by the Moorfields team); Keras-port CFP weights are a plain
   Google-Drive link (no gate).
3. Free-tier Render cannot host ViT-L (already OOMs on B0).
4. Fine-tuning on this machine: no CUDA GPU.

None of these block the plan — they define where it runs (Colab) and what
the local machine does (verify parity, evaluate, ship).

## 5. Decision matrix

| Decision | Recommendation |
|---|---|
| Ship RETFound to the phone? | **No** (size + latency + unproven domain accuracy) |
| Put RETFound on the edge server? | **Yes, later** — after the Render instability is resolved; Keras port makes it a config swap |
| Use RETFound for accuracy claims now? | **No** — evaluate on-holdout first with the Gulshan-format plan |
| Distill to our EfficientNetB0 student? | **Yes — this is the upgrade path** for the on-device grade with a Nature-lineage teacher |
| Keep the current APTOS EfficientNetB0 in the meanwhile? | **Yes** — it is the smallest honest artifact, labeled as such in the README |

## 6. Concrete next steps (in order, cheapest first)

1. Register for HF access (`YukunZhou/RETFound_mae_natureCFP`) AND download
   the ungated Keras-port `RETFound_cfp_weights.h5` (drive link in the port
   README) — keep only one as canonical.
2. Colab: run the repo's example fine-tune on APTOS (or resume the released
   APTOS checkpoint); record AUC/sens/spec at both operating points
   (Gulshan-format) on the standard split.
3. Distill into EfficientNetB0 (APTOSSoft labels); export TFLite fp32+int8.
4. Local: drop the TFLite in as a NEW choice in `RetinalPreprocessConfig`
   (`input_size: 224`, same ImageNet stats), add golden fixtures, run the
   full 339-test suite, ship as the second runner behind the current one
   (fail-closed A/B, never silent).
5. Update the README evaluation table only after the held-out numbers exist.

## 7. Citation

Zhou Y, Chia MA, Wagner SK, et al. A foundation model for generalizable
disease detection from retinal images. *Nature*. 2023;622:156–163.
doi:10.1038/s41586-023-06555-x. Weights/license: MIT (code), model weights
gated by the Moorfields group — redistribution of the weights in APK assets
requires confirming the HF licence terms before shipping.

*Compiled 2026-10-21 for Drishti-AI.*
