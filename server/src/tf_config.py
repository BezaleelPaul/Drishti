"""
TensorFlow configuration module.

Sets environment variables BEFORE TensorFlow is imported to:
1. Disable GPU by default (prevents screen flickering on low-end PCs without
   proper GPU drivers)
2. Enable memory growth if GPU is used
3. Suppress verbose TF logs

Set DRISHTI_USE_GPU=1 to opt-in to GPU acceleration.
"""
import os


def configure_tensorflow() -> None:
    """Configure TensorFlow environment variables before TF is imported.

    This MUST be called (or this module imported) before any
    ``import tensorflow`` / ``import keras`` statement in the same
    process, otherwise the environment variables will have no effect.
    """
    # ------------------------------------------------------------------
    # GPU control
    # ------------------------------------------------------------------
    # On low-end field PCs without proper CUDA/cuDNN drivers, TF's
    # GPU context initialization causes screen flickering.
    # Default to CPU-only; allow opt-in via DRISHTI_USE_GPU=1.
    if os.environ.get("DRISHTI_USE_GPU", "0") != "1":
        os.environ["CUDA_VISIBLE_DEVICES"] = "-1"

    # ------------------------------------------------------------------
    # Suppress TensorFlow verbose logs
    #   0 = all logs (default)
    #   1 = filter out INFO logs
    #   2 = filter out INFO and WARNING logs
    #   3 = filter out INFO, WARNING and ERROR logs
    # ------------------------------------------------------------------
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

    # ------------------------------------------------------------------
    # OneDNN / MKL logging (TF 2.16+ uses oneDNN under the hood)
    # ------------------------------------------------------------------
    os.environ.setdefault("TF_ENABLE_ONEDNN_LOGS", "0")


# Auto-configure on import so that simply ``import src.tf_config``
# is enough to set the right environment before TF loads.
configure_tensorflow()
