/// Typed failure surface for the Drishti on-device retinal pipeline.
///
/// The pipeline is fail-closed by design: every path that cannot produce a
/// real model output must throw one of these exceptions (or a documented
/// [StateError] for use-before-initialize) instead of substituting a grade.
/// Callers map failures to `AI_UNAVAILABLE` + mandatory human review.
library;

/// Why a retinal frame could not be turned into a model tensor.
///
/// These are *operator/UX* reasons, not clinical diagnoses. The calibrated
/// `QualityGateDart` remains the authoritative quality contract; this enum
/// describes the fast structural guard that runs inside the analysis worker
/// before any expensive blur/inference work.
enum PreprocessingFailureReason {
  /// The encoded byte stream could not be decoded by `package:image`.
  decodeFailed,

  /// An empty byte buffer was supplied.
  emptyImage,

  /// Zero/negative or absurd pixel dimensions.
  invalidDimensions,

  /// No pixel exceeded the retinal luma threshold (fully black frame).
  noRetinalRegion,

  /// The bright region occupies too little of the frame to be a fundus.
  notFundus,

  /// Mean retinal luma is below the underexposure floor.
  lowExposure,

  /// Mean retinal luma is above the overexposure ceiling.
  overExposure,

  /// Retinal luma standard deviation is too low to contain structure.
  lowContrast,

  /// Laplacian variance is too low: the capture is optically defocused.
  outOfFocus,

  /// The detected retinal disc is smaller than the minimum model input.
  retinaTooSmall,
}

/// Thrown when a frame cannot be validated, cropped or tensorised.
class PreprocessingException implements Exception {
  const PreprocessingException(
    this.reason,
    this.message, {
    this.cause,
    this.stackTrace,
  });

  /// Machine-readable category used by the UI to pick a recapture hint.
  final PreprocessingFailureReason reason;

  /// Human-readable explanation (safe to log; contains no PHI).
  final String message;

  /// Underlying decoder/FFI error, when one exists.
  final Object? cause;

  /// Captured worker-side stack trace, when available.
  final StackTrace? stackTrace;

  @override
  String toString() {
    final suffix = cause == null ? '' : ' (cause: $cause)';
    return 'PreprocessingException(${reason.name}): $message$suffix';
  }
}

/// Thrown when the model cannot be loaded, its tensor contract does not match
/// the shipped artifact, or an inference call fails.
class InferenceException implements Exception {
  const InferenceException(
    this.message, {
    this.cause,
    this.modelUnavailable = false,
    this.stackTrace,
  });

  /// Human-readable explanation (safe to log; contains no PHI).
  final String message;

  /// Underlying FFI/LiteRT error, when one exists.
  final Object? cause;

  /// True when the failure happened before any inference could run (asset
  /// missing, interpreter construction failed, delegate/contract mismatch).
  /// Callers can use this to distinguish "model unavailable" from a
  /// transient runtime failure.
  final bool modelUnavailable;

  /// Captured worker-side stack trace, when available.
  final StackTrace? stackTrace;

  @override
  String toString() {
    final suffix = cause == null ? '' : ' (cause: $cause)';
    return 'InferenceException: $message$suffix';
  }
}
