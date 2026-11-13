from __future__ import annotations

import os

import numpy as np
from PIL import Image

# Configure TensorFlow env vars BEFORE keras is lazily imported below.
from src.tf_config import configure_tensorflow

configure_tensorflow()

from src.classification.drdetect_contract import (
    CALIBRATED_REFERABLE_SCORE_CUT,
    CALIBRATED_THRESHOLDS,
    REFERABLE_SCORE_CUT,
    preprocess_fundus_to_nchw,
)
from src.classification.ordinal import (
    BASE_SIGMA,
    decode_grade,
    probabilities_from_score,
    uncertainty_from_scores,
    widened_sigma,
)
from src.classification.tta import aggregate_scores, build_views, resolve_view_count
from src.pipeline.schema import DRClassificationResult, DRGrade


class ClinicalModelUnavailableError(RuntimeError):
    """Raised when clinical inference cannot run with real model weights."""


class DRClassifier:
    """
    Model 2: Diabetic Retinopathy 5-Class Severity Classifier.
    Trained on APTOS 2019 dataset.
    Grades:
      0 - No DR
      1 - Mild NPDR
      2 - Moderate NPDR
      3 - Severe NPDR
      4 - Proliferative DR
    Referable DR: Grade >= 2
    """

    CLASS_LABELS = (
        "No DR",
        "Mild NPDR",
        "Moderate NPDR",
        "Severe NPDR",
        "Proliferative DR",
    )

    def __init__(
        self,
        onnx_model_path: str | None = None,
        keras_model_path: str | None = None,
        pytorch_model_path: str | None = None,
        dinov3_model_path: str | None = None,
        use_consensus: bool = False,
        consensus_classifier: Any | None = None,
        device: str = "cpu",
        strict_real_weights: bool = False,
        thresholds: Sequence[float] | None = None,
        referable_cut: float | None = None,
    ):
        self.device = device
        self.onnx_model_path = onnx_model_path
        self.keras_model_path = keras_model_path
        self.pytorch_model_path = pytorch_model_path
        self.dinov3_model_path = dinov3_model_path
        self.use_consensus = use_consensus or os.environ.get("DRISHTI_USE_CONSENSUS") in (
            "1",
            "true",
            "True",
        )
        self.strict_real_weights = strict_real_weights
        self.model_backend = "mock"
        self.load_error: str | None = None
        self._onnx_session = None
        self._keras_model = None
        self._torch_model = None
        self._dinov3_classifier = None
        self._consensus_classifier = consensus_classifier
        if self._consensus_classifier is not None:
            self.model_backend = "consensus"
            self.use_consensus = True
            return

        env_th = os.environ.get("DRISHTI_THRESHOLDS")
        use_calibrated = os.environ.get("DRISHTI_USE_CALIBRATED_THRESHOLDS", "1") in (
            "1",
            "true",
            "True",
        )
        if thresholds is not None:
            self.thresholds = list(thresholds)
        elif env_th:
            self.thresholds = [float(x.strip()) for x in env_th.split(",") if x.strip()]
        elif use_calibrated:
            self.thresholds = list(CALIBRATED_THRESHOLDS)
        else:
            self.thresholds = [0.5, 1.5, 2.5, 3.5]

        env_cut = os.environ.get("DRISHTI_REFERABLE_CUT")
        if referable_cut is not None:
            self.referable_cutoff = float(referable_cut)
        elif env_cut:
            self.referable_cutoff = float(env_cut.strip())
        elif use_calibrated:
            self.referable_cutoff = CALIBRATED_REFERABLE_SCORE_CUT
        else:
            self.referable_cutoff = REFERABLE_SCORE_CUT
        # TTA ensemble size (1 = legacy single pass). Read once so runs are
        # deterministic for the lifetime of the classifier instance.
        self.tta_views = resolve_view_count(os.environ.get("DRISHTI_TTA_VIEWS"))

        # Auto-detect pretrained model candidates in models/, root, or external
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        if not self.dinov3_model_path:
            candidate_dinov3 = os.path.join(
                repo_root, "models", "TL_dinov3_large_fine_tune_3class_final_icdr_best.pth"
            )
            if os.path.exists(candidate_dinov3) and os.environ.get("DRISHTI_USE_DINOV3") in (
                "1",
                "true",
                "True",
            ):
                self.dinov3_model_path = candidate_dinov3
        onnx_candidates = [
            os.path.join(repo_root, "models", "efficientnet_b0_regression_512px.onnx"),
            os.path.join(
                repo_root,
                "flutter_app",
                "assets",
                "models",
                "efficientnet_b0_regression_512px.onnx",
            ),
            os.path.join(repo_root, "release", "models", "efficientnet_b0_regression_512px.onnx"),
            os.path.join(repo_root, "efficientnet_b0_regression_512px.onnx"),
        ]
        if not self.onnx_model_path:
            for op in onnx_candidates:
                if os.path.exists(op):
                    self.onnx_model_path = op
                    break

        candidate_keras_paths = [
            os.path.join(repo_root, "results", "kaggle_retrain", "drishti_retrain_output", "final_model_focal_tuned.keras"),
            os.path.join(repo_root, "final_model.keras"),
            os.path.join(repo_root, "external", "DR-EfficientNetB0", "final_model.keras"),
        ]
        if not self.keras_model_path:
            for cp in candidate_keras_paths:
                if os.path.exists(cp):
                    self.keras_model_path = cp
                    break

        self._initialize_model()

    def _initialize_model(self):
        import logging

        # 0a. Prioritize Dual-Engine Consensus mode if requested
        if self.use_consensus:
            try:
                from src.classification.consensus_classifier import DualEngineConsensusClassifier

                self._consensus_classifier = DualEngineConsensusClassifier(
                    onnx_model_path=self.onnx_model_path,
                    dinov3_checkpoint_path=self.dinov3_model_path,
                    device=self.device,
                )
                self.model_backend = "consensus"
                self.load_error = None
                logging.getLogger(__name__).info(
                    "Loaded Dual-Engine Consensus Classifier (DRDetect + DINOv3)"
                )
                return
            except Exception as e:
                self.load_error = f"consensus load failed: {type(e).__name__}: {e}"
                logging.getLogger(__name__).warning(self.load_error)

        # 0b. Prioritize DINOv3 model if explicitly provided
        if self.dinov3_model_path and os.path.exists(self.dinov3_model_path):
            try:
                from src.classification.dinov3_classifier import DINOv3ICDRClassifier

                self._dinov3_classifier = DINOv3ICDRClassifier(
                    checkpoint_path=self.dinov3_model_path, device=self.device
                )
                self.model_backend = "dinov3"
                self.load_error = None
                logging.getLogger(__name__).info(
                    f"Loaded DINOv3 3-class ICDR model: {self.dinov3_model_path}"
                )
                return
            except Exception as e:
                self.load_error = (
                    f"dinov3 load failed ({self.dinov3_model_path}): {type(e).__name__}: {e}"
                )
                logging.getLogger(__name__).warning(self.load_error)

        # 1. Prioritize winning ONNX model (DRDetect Ordinal Regression)
        if self.onnx_model_path and os.path.exists(self.onnx_model_path):
            try:
                import onnxruntime as ort

                providers = ["CPUExecutionProvider"]
                self._onnx_session = ort.InferenceSession(self.onnx_model_path, providers=providers)
                self.model_backend = "onnx_drdetect"
                self.load_error = None
                logging.getLogger(__name__).info(
                    f"Loaded DRDetect ONNX model: {self.onnx_model_path}"
                )
                return
            except Exception as e:
                self.load_error = (
                    f"onnx load failed ({self.onnx_model_path}): {type(e).__name__}: {e}"
                )
                logging.getLogger(__name__).warning(self.load_error)

        # 2. Try loading Keras model if available
        if self.keras_model_path and os.path.exists(self.keras_model_path):
            try:
                import keras

                self._keras_model = keras.saving.load_model(self.keras_model_path)
                self.model_backend = "keras"
                self.load_error = None
                return
            except Exception as e:
                self.load_error = (
                    f"keras load failed ({self.keras_model_path}): {type(e).__name__}: {e}"
                )
                logging.getLogger(__name__).warning(self.load_error)

        # 3. Try loading PyTorch model
        if self.pytorch_model_path and os.path.exists(self.pytorch_model_path):
            try:
                import torch

                try:
                    self._torch_model = torch.load(
                        self.pytorch_model_path, map_location=self.device, weights_only=True
                    )
                except TypeError:
                    self._torch_model = torch.load(
                        self.pytorch_model_path, map_location=self.device
                    )
                self._torch_model.eval()
                self.model_backend = "pytorch"
                self.load_error = None
                return
            except Exception as e:
                self.load_error = (
                    f"torch load failed ({self.pytorch_model_path}): {type(e).__name__}: {e}"
                )
                logging.getLogger(__name__).warning(self.load_error)

        # 4. Simulation fallback
        import logging

        if self.strict_real_weights:
            # Fail closed: screening products must never render fabricated
            # predictions when the clinical weights are missing. Callers may
            # opt out for rehearsals/tests via strict_real_weights=False.
            raise ClinicalModelUnavailableError(
                "No real DR model weights could be loaded "
                f"(last load error: {self.load_error or 'no candidate files found'}). "
                "Run scripts/download_winning_model.py or install the model artifacts "
                "into models/. Set DRISHTI_ALLOW_SIMULATED=1 to bypass this guard for "
                "offline rehearsals."
            )
        logging.getLogger(__name__).warning(
            "DRClassifier: no DL weights loaded, using simulated backend."
        )
        self.model_backend = "simulated"

    def get_onnx_session(self):
        return self._onnx_session

    def get_keras_model(self):
        return self._keras_model

    def get_torch_model(self):
        return self._torch_model

    def get_active_model(self):
        if self.model_backend == "consensus":
            return self._consensus_classifier
        elif self.model_backend == "dinov3":
            return self._dinov3_classifier
        elif self.model_backend == "keras":
            return self._keras_model
        elif self.model_backend == "pytorch":
            return self._torch_model
        return None

    def get_backend(self) -> str:
        return self.model_backend

    def predict(self, image_input: str | np.ndarray | Image.Image) -> DRClassificationResult:
        """
        Runs DR classification on a certified Reliable Original Image.
        Returns full 5-class probability distribution, top-1 confidence, and top2 margin.
        """
        # Load image strictly without clinical enhancement (Section 20 Non-destructive rule)
        pil_img = self._load_as_pil(image_input)

        if self.model_backend == "consensus" and self._consensus_classifier is not None:
            return self._consensus_classifier.predict(pil_img)
        elif self.model_backend == "dinov3" and self._dinov3_classifier is not None:
            return self._dinov3_classifier.predict(pil_img).to_dr_classification_result()
        elif self.model_backend == "onnx_drdetect" and self._onnx_session is not None:
            return self._predict_onnx_drdetect(pil_img)
        elif self.model_backend == "keras" and self._keras_model is not None:
            return self._predict_keras(pil_img)
        elif self.model_backend == "pytorch" and self._torch_model is not None:
            return self._predict_pytorch(pil_img)
        else:
            return self._predict_simulated(pil_img)

    def _preprocess_for_drdetect(self, pil_img: Image.Image) -> np.ndarray:
        """Delegates to the canonical DRDetect contract preprocessing."""
        return preprocess_fundus_to_nchw(pil_img)

    def _predict_onnx_drdetect(self, pil_img: Image.Image) -> DRClassificationResult:
        inp_name = self._onnx_session.get_inputs()[0].name
        base_input = self._preprocess_for_drdetect(pil_img)

        # 2. Run ONNX inference across the TTA view ensemble (label-preserving
        #    flips: fundus images are approximately rotation-symmetric). With
        #    tta_views=1 this is exactly the legacy single-pass behaviour.
        views = build_views(base_input, self.tta_views)
        scores: list[float] = []
        for view_tensor in views:
            out = self._onnx_session.run(None, {inp_name: view_tensor})[0]
            scores.append(float(np.squeeze(out)))
        report = aggregate_scores(scores)
        score = report.mean_score

        # 3. Decode continuous ordinal regression score (identical decoding
        #    for TTA mean and legacy single-pass scores)
        grade = DRGrade(decode_grade(score, self.thresholds))

        # 4. Honest uncertainty: cross-view disagreement widens the class
        #    kernels, so confidence/ambiguity/OOD signals are evidence-based.
        sigma = widened_sigma(report.spread) if report.n_views > 1 else BASE_SIGMA
        probs = probabilities_from_score(score, sigma)
        uncertainty = uncertainty_from_scores(score, self.thresholds, spread=report.spread)

        sorted_indices = np.argsort(probs)[::-1]
        top1_idx = int(sorted_indices[0])
        top2_idx = int(sorted_indices[1])
        top1_conf = float(probs[top1_idx])
        margin = float(top1_conf - probs[top2_idx])

        return DRClassificationResult(
            predicted_grade=grade,
            probabilities=probs,
            confidence=top1_conf,
            top2_margin=margin,
            is_referable=score >= self.referable_cutoff,
            raw_score=score,
            uncertainty=uncertainty,
            model_id="drdetect_ordinal",
        )

    def _load_as_pil(self, image_input: str | np.ndarray | Image.Image) -> Image.Image:
        try:
            from src.image_io import to_rgb_uint8

            if isinstance(image_input, str):
                # Shared funnel: dimension cap applies to file paths too.
                return Image.fromarray(
                    to_rgb_uint8(np.array(Image.open(image_input).convert("RGB")))
                )
            elif isinstance(image_input, np.ndarray):
                # Single shared loader (float scale, NaN fail-closed, 2D/RGBA
                # handled). See src/image_io.
                arr = to_rgb_uint8(image_input)
                return Image.fromarray(arr).convert("RGB")
            elif isinstance(image_input, Image.Image):
                return Image.fromarray(to_rgb_uint8(np.array(image_input.convert("RGB"))))
            else:
                raise TypeError(f"Unsupported image type: {type(image_input)}")
        except FileNotFoundError:
            raise ValueError(f"Image file not found: {image_input}")
        except (OSError, ValueError):
            raise
        except Exception as e:  # noqa: BLE001 - normalize decoder failures
            raise ValueError(f"Could not decode image input: {e}")

    def _predict_keras(self, pil_img: Image.Image) -> DRClassificationResult:
        img_resized = pil_img.resize((224, 224))
        arr = np.expand_dims(np.array(img_resized, dtype=np.float32), axis=0)
        # Model's internal preprocessing handles normalization
        preds = self._keras_model.predict(arr, verbose=0)[0]
        probs = [float(p) for p in preds]
        return self._build_result(probs)

    def _predict_pytorch(self, pil_img: Image.Image) -> DRClassificationResult:
        import torch
        from torchvision import transforms

        transform = transforms.Compose(
            [
                transforms.Resize((224, 224)),
                transforms.ToTensor(),
                transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
            ]
        )
        # Validate device, fallback to cpu if cuda unavailable
        try:
            dev = str(self.device)
            if dev.startswith("cuda") and not torch.cuda.is_available():
                dev = "cpu"
        except Exception:  # noqa: BLE001 - invalid accelerator falls back to CPU
            dev = "cpu"
        try:
            self._torch_model.eval()
            self._torch_model.to(dev)
        except Exception:  # noqa: BLE001 - invalid model device falls back to CPU
            dev = "cpu"
        tensor = transform(pil_img).unsqueeze(0).to(dev)
        with torch.no_grad():
            logits = self._torch_model(tensor)
            probs = torch.softmax(logits, dim=-1).squeeze(0).cpu().numpy()
        return self._build_result([float(p) for p in probs])

    def _predict_simulated(self, pil_img: Image.Image) -> DRClassificationResult:
        """
        Simulated inference based on image features for test environments and unit tests.
        Derives realistic probabilities without crashing if heavy DL framework is missing.
        """
        arr = np.array(pil_img.resize((128, 128)), dtype=np.float32)
        # Red channel characteristics and variation
        r_mean = float(np.mean(arr[:, :, 0]))
        r_std = float(np.std(arr[:, :, 0]))

        # Pseudo-deterministic distribution from image features
        # Add hash of all channels to make distribution more unique
        g_mean = float(np.mean(arr[:, :, 1]))
        b_mean = float(np.mean(arr[:, :, 2]))
        image_hash = int((r_mean * 10000 + g_mean * 100 + b_mean * 10 + r_std) % 100000)

        # Pseudo-deterministic distribution from image features
        rng = np.random.RandomState(image_hash)
        raw = rng.dirichlet(alpha=[2.0, 1.0, 1.0, 0.5, 0.5])
        probs = [float(p) for p in raw]

        return self._build_result(probs)

    def _build_result(self, probs: list[float]) -> DRClassificationResult:
        probs = list(probs)
        if len(probs) != 5:
            raise ValueError(f"Expected 5-class probability vector, got {len(probs)}")
        # Ensure sum to 1
        total = sum(probs)
        if total <= 0 or not np.isfinite(total):
            raise ValueError("Invalid probability vector: sum must be positive and finite")
        probs = [p / total for p in probs]

        sorted_indices = np.argsort(probs)[::-1]
        top1_idx = int(sorted_indices[0])
        top2_idx = int(sorted_indices[1])

        top1_conf = float(probs[top1_idx])
        top2_conf = float(probs[top2_idx])
        margin = float(top1_conf - top2_conf)

        grade = DRGrade(top1_idx)
        return DRClassificationResult(
            predicted_grade=grade,
            probabilities=probs,
            confidence=top1_conf,
            top2_margin=margin,
            is_referable=grade.is_referable,
        )
