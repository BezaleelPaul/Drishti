/// Immutable configuration for retinal preprocessing.
///
/// The default shipped model (`drdetect_ordinal_512_fp32.tflite`) was converted
/// from `efficientnet_b0_regression_512px.onnx` and parity-gated against
/// `src/classification/classifier.py`, which uses **sigma = 20** at native
/// resolution. [RetinalPreprocessConfig.ordinal512ImageNet] therefore pins
/// sigma 20 so on-device output stays inside the measured drift budget
/// (`maxPreprocessScoreDrift = 0.12`).
///
/// [RetinalPreprocessConfig.classicalBenGraham512] exposes the textbook
/// Ben Graham sigma = 30 variant for models trained with that pipeline. Do not
/// switch the shipped ordinal artifact to sigma 30 without re-running the
/// parity/golden suite (`scripts/convert/generate_drdetect_dart_goldens.py`).
library;

/// How normalised floats are produced from 8-bit RGB.
enum RetinalTensorNormalization {
  /// `(p / 255 - mean[c]) / std[c]` with per-channel ImageNet statistics.
  imagenet,

  /// `p / 255`, keeping values in `[0, 1]`.
  unit,

  /// `p` as float32 in `[0, 255]`; used by models whose graph performs its own
  /// rescaling (the legacy 224px Keras `dr_efficientnet_b0_fp32` contract).
  rawRgb255,
}

/// Preprocessing parameters for one model artifact.
///
/// Coordinate and memory conventions used across the pipeline:
/// * Pixel origin is the **top-left** corner; `x` grows right, `y` grows down.
/// * Packed RGB buffers are row-major, 3 bytes per pixel, no padding:
///   `index = (y * width + x) * 3 + channel`.
/// * The model tensor is **NHWC** float32, one image per batch:
///   `index = ((y * outputSize + x) * 3) + channel`, row-major within a row.
class RetinalPreprocessConfig {
  const RetinalPreprocessConfig({
    required this.outputSize,
    required this.blurSigma,
    this.applyBenGraham = true,
    this.cropToRetina = true,
    this.workingMaxSide = 768,
    this.borderLumaThreshold = 7.0,
    this.minCropRadius = 16,
    this.normalization = RetinalTensorNormalization.imagenet,
    this.mean = const [0.485, 0.456, 0.406],
    this.std = const [0.229, 0.224, 0.225],
    this.previewMaxSide = 512,
    this.minMeanLuma = 12.0,
    this.maxMeanLuma = 245.0,
    this.minLumaStdDev = 6.0,
    this.minRetinalAreaRatio = 0.04,
    this.minSharpness = 6.0,
  }) : assert(outputSize > 0, 'outputSize must be positive'),
       assert(blurSigma >= 0, 'blurSigma must be non-negative'),
       assert(workingMaxSide > 0, 'workingMaxSide must be positive');

  /// Final square tensor edge length (512 for the shipped ordinal model).
  final int outputSize;

  /// Gaussian sigma used by Ben Graham enhancement.
  ///
  /// The reference pipeline blurs at native resolution with sigma 20. The fast
  /// path first area-resizes the retinal square to [workingMaxSide] and scales
  /// sigma by `workingSide / nativeSide` so the blur radius stays equivalent
  /// in *normalised* retinal coordinates.
  final double blurSigma;

  /// When false the crop is only resized + normalised (no enhancement).
  final bool applyBenGraham;

  /// When false the frame is used as-is (legacy 224px raw-RGB contract).
  final bool cropToRetina;

  /// Maximum working edge for the Gaussian blur. Blurring a multi-megapixel
  /// frame in pure Dart is unaffordable; 768 preserves score parity within the
  /// documented 0.12 drift budget.
  final int workingMaxSide;

  /// Luma threshold (`0.299R + 0.587G + 0.114B`) above which a pixel is
  /// considered retinal. Matches `classifier.py`'s dark-border removal.
  final double borderLumaThreshold;

  /// Minimum accepted radius of the detected retinal disc, in source pixels.
  final int minCropRadius;

  /// Output tensor normalisation scheme.
  final RetinalTensorNormalization normalization;

  /// Per-channel means, applied after `/255` when [normalization] is imagenet.
  final List<double> mean;

  /// Per-channel standard deviations, applied after centring.
  final List<double> std;

  /// Edge length of the PNG returned for clinician visualisation.
  final int previewMaxSide;

  /// Structural guard thresholds. These are deliberately conservative: the
  /// calibrated quality gate remains authoritative, and the guard only rejects
  /// frames that cannot possibly be fundus captures.
  final double minMeanLuma;
  final double maxMeanLuma;
  final double minLumaStdDev;
  final double minRetinalAreaRatio;
  final double minSharpness;

  /// Number of float32 elements in the NHWC tensor.
  int get tensorElementCount => outputSize * outputSize * 3;

  /// Byte size of the NHWC tensor (3 channels, float32).
  int get tensorByteLength => tensorElementCount * 4;

  /// Deployed DRDetect ordinal contract: 512x512, ImageNet statistics,
  /// sigma 20 (parity with `classifier.py`).
  static const ordinal512ImageNet = RetinalPreprocessConfig(
    outputSize: 512,
    blurSigma: 20.0,
  );

  /// Classical Ben Graham variant: 512x512, sigma 30. Only valid for models
  /// trained on that exact pipeline.
  static const classicalBenGraham512 = RetinalPreprocessConfig(
    outputSize: 512,
    blurSigma: 30.0,
  );

  /// Legacy Keras contract: 224x224, raw RGB `[0, 255]`, no crop/enhancement.
  /// Normalisation lives inside the graph for that artifact.
  static const fiveClass224Raw = RetinalPreprocessConfig(
    outputSize: 224,
    blurSigma: 0.0,
    applyBenGraham: false,
    cropToRetina: false,
    normalization: RetinalTensorNormalization.rawRgb255,
    mean: [0.0, 0.0, 0.0],
    std: [1.0, 1.0, 1.0],
  );
}
