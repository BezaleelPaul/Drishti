from __future__ import annotations

import logging
import os
from typing import Any

import numpy as np
from PIL import Image

# Configure TensorFlow env vars BEFORE tensorflow is lazily imported below.
from src.tf_config import configure_tensorflow

configure_tensorflow()

try:
    import cv2
    HAS_OPENCV = True
except ImportError:
    HAS_OPENCV = False

from src.pipeline.schema import DRGrade, GradCAMResult


class GradCAMExplainer:
    """
    Grad-CAM & Grad-CAM++ Explainability Engine for Model 2 (DR Classifier).
    Calculates exact gradient backpropagation of class scores through convolutional
    feature maps to produce mathematically rigorous attention heatmaps.
    
    Supports:
    - Keras 3 / TensorFlow backbones (e.g. EfficientNetB0, EfficientNet-B4)
    - PyTorch backbones (DenseNet121, ResNet50, Swin/ViT)
    - Grad-CAM++ higher-order derivative weighting for multi-focal micro-lesions
    - Graceful multi-scale anatomical saliency fallback when running in offline/simulated mode
    
    Enforces strict claim boundary per Section 8:
    'Grad-CAM shows which pixels most influenced the model's decision.
     It does not prove that a lesion exists at that location, and it is not a lesion-segmentation output.'
    """

    EXPLAINABILITY_DISCLAIMER = (
        "Grad-CAM visualizes regions of highest gradient activation influencing the "
        "model's classification decision. It does NOT constitute automated lesion detection "
        "or segmentation and must be interpreted by a qualified clinician."
    )

    FALLBACK_LAYER_NAME = "multiscale_vascular_saliency (fallback)"

    FALLBACK_NOTE = (
        " NOTE: Gradient backpropagation was unavailable, so this map is a multi-scale "
        "vascular saliency fallback — not model attention — and must not be interpreted "
        "as gradient-based evidence."
    )

    # Single background threshold shared by saliency masking and overlay blending.
    # Read live from src.image_io at call time (never snapshot) so the one shared
    # definition in image_io.py stays authoritative.
    @staticmethod
    def _bg_threshold() -> float:
        from src.image_io import RETINAL_BG_THRESHOLD
        return RETINAL_BG_THRESHOLD

    def __init__(self, classifier_backend: Any | None = None, use_gradcam_plus_plus: bool = True):
        self.classifier_backend = classifier_backend
        self.use_gradcam_plus_plus = use_gradcam_plus_plus

    def generate_heatmap(
        self,
        image_input: str | np.ndarray | Image.Image,
        target_grade: DRGrade,
        save_path: str | None = None,
        classifier: Any | None = None,
    ) -> GradCAMResult:
        """
        Computes Grad-CAM attention heatmap overlaid onto the original fundus image.
        """
        active_classifier = classifier or self.classifier_backend
        pil_img = self._load_image(image_input)
        orig_np = np.array(pil_img)

        # 1. Attempt Real Gradient Backpropagation through DL Model
        attention_map = None
        layer_name = "final_convolutional_block"

        if active_classifier is not None:
            # 1a. Keras / TensorFlow Gradient Tape Backpropagation
            keras_model = getattr(active_classifier, "_keras_model", None)
            if keras_model is not None:
                try:
                    attention_map, layer_name = self._compute_keras_gradcam(
                        keras_model, orig_np, target_grade.value, use_pp=self.use_gradcam_plus_plus
                    )
                except Exception:  # noqa: BLE001 - try saliency fallback
                    attention_map = None

            # 1b. PyTorch Forward/Backward Hook Backpropagation
            torch_model = getattr(active_classifier, "_torch_model", None)
            if attention_map is None and torch_model is not None:
                try:
                    device = getattr(active_classifier, "device", "cpu")
                    attention_map, layer_name = self._compute_pytorch_gradcam(
                        torch_model, orig_np, target_grade.value, device=device, use_pp=self.use_gradcam_plus_plus
                    )
                except Exception:  # noqa: BLE001 - try saliency fallback
                    attention_map = None

        # 2. Fallback to Multi-Scale Morphological & Vascular Saliency if no DL weights loaded
        disclaimer = self.EXPLAINABILITY_DISCLAIMER
        if attention_map is None:
            attention_map = self._compute_synthetic_attention_map(orig_np, target_grade)
            layer_name = self.FALLBACK_LAYER_NAME
            disclaimer = self.EXPLAINABILITY_DISCLAIMER + self.FALLBACK_NOTE
            logging.getLogger("NetraAI.GradCAM").warning(
                "Gradient-based explainability unavailable; using multi-scale vascular "
                "saliency fallback. Output is NOT gradient backpropagation."
            )

        # 3. Create Overlaid Visual Heatmap onto Original Retinal Frame
        overlay = self._overlay_heatmap_on_image(orig_np, attention_map)

        if save_path:
            os.makedirs(os.path.dirname(os.path.abspath(save_path)), exist_ok=True)
            Image.fromarray(overlay).save(save_path)

        return GradCAMResult(
            heatmap_generated=True,
            heatmap_array=overlay,
            overlay_path=save_path,
            target_layer=layer_name,
            disclaimer=disclaimer,
        )

    def _compute_keras_gradcam(
        self, keras_model: Any, img_rgb: np.ndarray, class_idx: int, use_pp: bool = True
    ) -> tuple[np.ndarray | None, str]:
        """
        Computes exact Grad-CAM / Grad-CAM++ gradients from Keras convolutional layers.
        """
        try:
            import tensorflow as tf
        except ImportError:
            import logging
            logging.getLogger("NetraAI.GradCAM").warning(
                "TensorFlow is required for Keras Grad-CAM++ gradient calculation. "
                "Falling back to multi-scale anatomical vascular saliency."
            )
            return None, "multiscale_vascular_saliency (fallback)"

        h_orig, w_orig = img_rgb.shape[:2]
        # Preprocess input image to model dimensions (224x224)
        if HAS_OPENCV:
            img_resized = cv2.resize(img_rgb, (224, 224))
        else:
            img_resized = np.array(Image.fromarray(img_rgb).resize((224, 224)))

        img_tensor = tf.cast(np.expand_dims(img_resized, axis=0), tf.float32)

        # Locate last 4D convolutional feature layer
        target_layer = None
        target_layer_index = None
        for layer_index in range(len(keras_model.layers) - 1, -1, -1):
            layer = keras_model.layers[layer_index]
            out_shape = getattr(layer, "output_shape", None)
            if out_shape is None and hasattr(layer, "output"):
                out_shape = getattr(layer.output, "shape", None)
            if out_shape and len(out_shape) == 4:
                target_layer = layer
                target_layer_index = layer_index
                break
            if hasattr(layer, "layers"):  # nested backbone
                for sub in reversed(layer.layers):
                    sub_shape = getattr(sub, "output_shape", None)
                    if sub_shape is None and hasattr(sub, "output"):
                        sub_shape = getattr(sub.output, "shape", None)
                    if sub_shape and len(sub_shape) == 4:
                        target_layer = sub
                        break
                if target_layer is not None:
                    break

        if target_layer is None:
            raise ValueError("No 4D convolutional feature map found in Keras model.")

        with tf.GradientTape() as tape:
            if target_layer_index is not None:
                # Keras 3 may reject a multi-output graph built from a
                # serialized nested Functional backbone. Replaying the head
                # keeps the backbone activation connected to the input tensor.
                conv_outputs = target_layer(img_tensor, training=False)
                predictions = conv_outputs
                for layer in keras_model.layers[target_layer_index + 1:]:
                    predictions = layer(predictions, training=False)
            else:
                raise ValueError("Nested Keras feature map requires an unsupported graph path.")
            target_score = predictions[:, class_idx]

        grads = tape.gradient(target_score, conv_outputs)
        if grads is None:
            raise ValueError("Gradient calculation failed.")

        conv_outputs = conv_outputs[0]  # [H, W, C]
        grads = grads[0]                # [H, W, C]

        if use_pp:
            # Grad-CAM++ formulation: higher-order partial derivatives
            g2 = tf.math.square(grads)
            g3 = tf.math.pow(grads, 3)
            sum_acts = tf.reduce_sum(conv_outputs, axis=(0, 1), keepdims=True)
            eps = 1e-7
            alphas = g2 / (2.0 * g2 + sum_acts * g3 + eps)
            alphas = tf.where(tf.math.is_nan(alphas), tf.zeros_like(alphas), alphas)
            weights = tf.reduce_sum(alphas * tf.nn.relu(grads), axis=(0, 1))
        else:
            # Standard Grad-CAM: Global Average Pooling of gradients
            weights = tf.reduce_mean(grads, axis=(0, 1))

        cam = tf.reduce_sum(conv_outputs * weights, axis=-1)
        cam = tf.nn.relu(cam).numpy()

        # Normalize to [0, 1]
        c_min, c_max = np.min(cam), np.max(cam)
        if c_max > c_min:
            cam_norm = (cam - c_min) / (c_max - c_min)
        else:
            cam_norm = np.zeros_like(cam)

        if HAS_OPENCV:
            cam_full = cv2.resize(cam_norm, (w_orig, h_orig))
        else:
            cam_full = np.array(Image.fromarray((cam_norm * 255).astype(np.uint8)).resize((w_orig, h_orig))) / 255.0

        return cam_full, target_layer.name

    def _compute_pytorch_gradcam(
        self, torch_model: Any, img_rgb: np.ndarray, class_idx: int, device: str = "cpu", use_pp: bool = True
    ) -> tuple[np.ndarray, str]:
        """
        Computes exact Grad-CAM / Grad-CAM++ using PyTorch backward hooks.
        """
        import torch
        import torch.nn.functional as F
        from torchvision import transforms

        h_orig, w_orig = img_rgb.shape[:2]
        transform = transforms.Compose([
            transforms.ToPILImage(),
            transforms.Resize((224, 224)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ])
        tensor = transform(img_rgb).unsqueeze(0).to(device)

        # Find target conv module (Conv2d only: BatchNorm2d has no spatial
        # semantics suitable as a CAM target and must not be selected)
        target_module = None
        target_name = "conv_head"
        for name, module in reversed(list(torch_model.named_modules())):
            if isinstance(module, torch.nn.Conv2d):
                target_module = module
                target_name = name
                break

        if target_module is None:
            raise ValueError("No Conv2d module found in PyTorch model.")

        activations = []
        gradients = []

        def fwd_hook(m, inp, out):
            activations.append(out)

        def bwd_hook(m, gin, gout):
            gradients.append(gout[0])

        h_fwd = target_module.register_forward_hook(fwd_hook)
        h_bwd = target_module.register_full_backward_hook(bwd_hook)

        torch_model.eval()
        torch_model.zero_grad(set_to_none=True)
        logits = torch_model(tensor)
        score = logits[0, class_idx]
        score.backward(retain_graph=False)

        h_fwd.remove()
        h_bwd.remove()

        if not activations or not gradients:
            raise ValueError("Forward/backward hooks did not capture activations.")

        act = activations[0][0]  # [C, H, W]
        grad = gradients[0][0]   # [C, H, W]

        if use_pp:
            g2 = grad.pow(2)
            g3 = grad.pow(3)
            sum_acts = act.sum(dim=(1, 2), keepdim=True)
            eps = 1e-7
            alphas = g2 / (2.0 * g2 + sum_acts * g3 + eps)
            alphas = alphas * F.relu(grad)
            weights = alphas.sum(dim=(1, 2), keepdim=True)
        else:
            weights = grad.mean(dim=(1, 2), keepdim=True)

        cam = (weights * act).sum(dim=0)
        cam = F.relu(cam).detach().cpu().numpy()

        c_min, c_max = np.min(cam), np.max(cam)
        cam_norm = (cam - c_min) / (c_max - c_min + 1e-8) if c_max > c_min else np.zeros_like(cam)

        if HAS_OPENCV:
            cam_full = cv2.resize(cam_norm, (w_orig, h_orig))
        else:
            cam_full = np.array(Image.fromarray((cam_norm * 255).astype(np.uint8)).resize((w_orig, h_orig))) / 255.0

        return cam_full, target_name

    def _compute_synthetic_attention_map(self, img_np: np.ndarray, target_grade: DRGrade) -> np.ndarray:
        """
        Deterministic multi-scale structural saliency map for offline testing.
        Highlights vessel bifurcation points and contrast focal points.
        """
        green = img_np[:, :, 1].astype(np.float32)

        # Retinal boundary mask (unified threshold with overlay blending).
        # Shared luma conversion (NOT mean(axis=2)) so the mask agrees with
        # the checker/segmenter/router denominators on dim border pixels.
        from src.image_io import rgb_to_gray as _to_gray
        gray = _to_gray(img_np)
        retinal_mask = gray > self._bg_threshold()

        if HAS_OPENCV:
            blurred = cv2.GaussianBlur(green, (21, 21), 0)
            diff = np.abs(green - blurred)
            attention = cv2.GaussianBlur(diff, (35, 35), 0)
        else:
            gy, gx = np.gradient(green)
            attention = np.sqrt(gx**2 + gy**2)

        attention[~retinal_mask] = 0.0

        min_v = np.min(attention)
        max_v = np.max(attention)
        if max_v > min_v:
            norm_att = (attention - min_v) / (max_v - min_v)
        else:
            norm_att = np.zeros_like(attention)

        if target_grade.value >= 2:
            norm_att = np.power(norm_att, 0.7)
        else:
            norm_att = np.power(norm_att, 1.5)

        return norm_att

    def _overlay_heatmap_on_image(
        self, orig_rgb: np.ndarray, attention_map: np.ndarray, alpha: float = 0.45
    ) -> np.ndarray:
        """
        Overlays jet/plasma heatmap onto original retinal image without distorting base pixels.
        Masks out non-retinal outer boundary.
        """
        alpha = float(np.clip(float(alpha), 0.0, 1.0))
        h, w, _ = orig_rgb.shape
        attention_map = np.nan_to_num(
            np.asarray(attention_map, dtype=np.float32), nan=0.0, posinf=1.0, neginf=0.0
        )
        att_u8 = np.uint8(255 * np.clip(attention_map, 0.0, 1.0))

        if HAS_OPENCV:
            heatmap_bgr = cv2.applyColorMap(att_u8, cv2.COLORMAP_JET)
            heatmap_rgb = cv2.cvtColor(heatmap_bgr, cv2.COLOR_BGR2RGB)
        else:
            heatmap_rgb = np.zeros((h, w, 3), dtype=np.uint8)
            norm = att_u8 / 255.0
            heatmap_rgb[:, :, 0] = np.uint8(255 * np.clip(1.5 - np.abs(norm * 4 - 3), 0, 1))
            heatmap_rgb[:, :, 1] = np.uint8(255 * np.clip(1.5 - np.abs(norm * 4 - 2), 0, 1))
            heatmap_rgb[:, :, 2] = np.uint8(255 * np.clip(1.5 - np.abs(norm * 4 - 1), 0, 1))

        # Blend original with heatmap (uint8 math: avoids a float64 HxWx3 transient,
        # ~400MB at 4K).
        if HAS_OPENCV:
            overlaid = cv2.addWeighted(orig_rgb, 1.0 - alpha, heatmap_rgb, alpha, 0)
        else:
            overlaid = np.uint8(
                orig_rgb.astype(np.float32) * (1.0 - alpha) + heatmap_rgb.astype(np.float32) * alpha
            )

        # Keep non-retinal outer boundary black (same threshold AND same
        # luma conversion as the saliency mask above).
        from src.image_io import rgb_to_gray as _to_gray
        gray = _to_gray(orig_rgb)
        overlaid[gray <= self._bg_threshold()] = orig_rgb[gray <= self._bg_threshold()]

        return overlaid

    def _load_image(self, image_input: str | np.ndarray | Image.Image) -> Image.Image:
        from src.image_io import to_rgb_uint8
        if isinstance(image_input, str):
            # Shared funnel: dimension cap applies to file paths too.
            with Image.open(image_input) as img:
                return Image.fromarray(to_rgb_uint8(np.array(img.convert("RGB"))))
        elif isinstance(image_input, np.ndarray):
            # Single shared loader, mirroring classifier._load_as_pil.
            return Image.fromarray(to_rgb_uint8(image_input)).convert("RGB")
        elif isinstance(image_input, Image.Image):
            return image_input.convert("RGB")
        else:
            raise TypeError(f"Unsupported image input: {type(image_input)}")
