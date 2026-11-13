import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline_schema.dart';
import 'pipeline_exceptions.dart';

/// Pipeline-facing alias for the canonical DR grade enum.
///
/// There is exactly one grade type in the app: [DrGrade] from
/// `pipeline_schema.dart`, whose integer values and labels are a wire contract
/// shared with the server and the SQLite store. Re-declaring a second enum for
/// the pipeline would create two sources of truth for a clinical value, so the
/// requested `DRGrade` name is provided as a transparent alias instead.
typedef DRGrade = DrGrade;

/// Structured result returned by one end-to-end on-device analysis.
///
/// All durations are wall-clock milliseconds measured inside the analysis
/// worker isolate. [processedImageBytes] is a PNG of the enhanced 512x512
/// retinal crop (the exact pixels the tensor was built from, before
/// normalisation) for clinician visualisation; it is empty when the caller
/// opted out of preview generation.
class DRInferenceResult {
  const DRInferenceResult({
    required this.grade,
    required this.confidenceScores,
    required this.confidence,
    required this.top2Margin,
    required this.referableScore,
    required this.referable,
    required this.preprocessingDurationMs,
    required this.inferenceDurationMs,
    required this.processedImageBytes,
    required this.modelId,
    required this.modelVersion,
    required this.backend,
    this.rawOutput = const [],
    this.processedImageWidth = 0,
    this.processedImageHeight = 0,
  });

  /// Ordinal class decoded from the model score via strict cut-points.
  final DRGrade grade;

  /// Five-class compatibility vector `[P0..P4]`, normalised to sum to 1.
  ///
  /// For the ordinal artifact this is the deterministic Gaussian kernel
  /// (`sigma = 0.65`) around the scalar score used by the server. It is a
  /// compatibility transform, **not** a calibrated softmax; the raw scalar is
  /// preserved in [referableScore] and [rawOutput].
  final List<double> confidenceScores;

  /// `max(confidenceScores)`.
  final double confidence;

  /// `top1 - top2` over [confidenceScores].
  final double top2Margin;

  /// Raw scalar ordinal score, or referable probability mass for a 5-class
  /// model (`P2 + P3 + P4`).
  final double referableScore;

  /// True when [grade] is referable (grade >= 2).
  final bool referable;

  /// Decode + crop + Ben Graham + resize/normalisation time.
  final int preprocessingDurationMs;

  /// LiteRT interpreter invocation time only.
  final int inferenceDurationMs;

  /// PNG-encoded enhanced crop for doctor visualisation (may be empty).
  final Uint8List processedImageBytes;

  /// Pixel dimensions of [processedImageBytes] (0 when no preview).
  final int processedImageWidth;
  final int processedImageHeight;

  /// Artifact identity of the model that actually ran.
  final String modelId;
  final String modelVersion;

  /// Delegate actually in use: `cpu`, `xnnpack` or `gpu`.
  final String backend;

  /// Unmodified output tensor values (1 scalar or 5 class scores).
  final List<double> rawOutput;

  /// Total on-device time for this analysis.
  int get totalDurationMs => preprocessingDurationMs + inferenceDurationMs;
}

/// One decoded ordinal score. Shared by the isolate pipeline and the legacy
/// synchronous runner so both can never disagree.
class OrdinalScoreDecoding {
  const OrdinalScoreDecoding({
    required this.grade,
    required this.probabilities,
    required this.confidence,
    required this.top2Margin,
    required this.referable,
  });

  final DRGrade grade;
  final List<double> probabilities;
  final double confidence;
  final double top2Margin;
  final bool referable;
}

/// Pure output-tensor decoding (no FFI).
///
/// Kept free of `flutter_litert` types so it can be unit-tested on the Dart VM
/// and executed inside any isolate.
class DrishtiOutputDecoder {
  const DrishtiOutputDecoder._();

  /// Strict ordinal cut-points from `classifier.py::_predict_onnx_drdetect`.
  static const List<double> ordinalCutPoints = [0.5, 1.5, 2.5, 3.5];

  /// Gaussian kernel width of the server's ordinal compatibility distribution.
  static const double kernelSigma = 0.65;

  /// Decodes the raw output tensor into a [DRInferenceResult].
  ///
  /// [rawOutput] must contain exactly 1 finite scalar for the ordinal contract
  /// or exactly 5 finite, non-negative values for the 5-class contract.
  static DRInferenceResult decode({
    required bool ordinal,
    required List<double> rawOutput,
    required int preprocessingDurationMs,
    required int inferenceDurationMs,
    required String modelId,
    required String modelVersion,
    required String backend,
    Uint8List? processedImageBytes,
    int processedImageWidth = 0,
    int processedImageHeight = 0,
  }) {
    final preview = processedImageBytes ?? Uint8List(0);
    if (ordinal) {
      if (rawOutput.length != 1) {
        throw InferenceException(
          'Ordinal contract expects 1 output value, got ${rawOutput.length}.',
        );
      }
      final score = rawOutput.first;
      if (score.isNaN || score.isInfinite) {
        throw const InferenceException(
          'Ordinal model returned a non-finite score.',
        );
      }
      final decoded = decodeOrdinalScore(score);
      return DRInferenceResult(
        grade: decoded.grade,
        confidenceScores: decoded.probabilities,
        confidence: decoded.confidence,
        top2Margin: decoded.top2Margin,
        referableScore: score,
        referable: decoded.referable,
        preprocessingDurationMs: preprocessingDurationMs,
        inferenceDurationMs: inferenceDurationMs,
        processedImageBytes: preview,
        processedImageWidth: processedImageWidth,
        processedImageHeight: processedImageHeight,
        modelId: modelId,
        modelVersion: modelVersion,
        backend: backend,
        rawOutput: List<double>.unmodifiable(rawOutput),
      );
    }

    if (rawOutput.length != 5) {
      throw InferenceException(
        '5-class contract expects 5 output values, got ${rawOutput.length}.',
      );
    }
    if (rawOutput.any((p) => p.isNaN || p.isInfinite || p < 0)) {
      throw const InferenceException(
        '5-class model returned invalid probability values.',
      );
    }
    final total = rawOutput.fold<double>(0.0, (a, b) => a + b);
    if (total <= 0) {
      throw const InferenceException(
        '5-class model returned an all-zero probability vector.',
      );
    }
    final probs = rawOutput.map((p) => p / total).toList(growable: false);
    var top1Idx = 0;
    var top2Idx = 1;
    for (var i = 0; i < 5; i++) {
      if (probs[i] > probs[top1Idx]) {
        top2Idx = top1Idx;
        top1Idx = i;
      } else if (i != top1Idx && probs[i] > probs[top2Idx]) {
        top2Idx = i;
      }
    }
    final grade = DRGrade.fromValue(top1Idx);
    final referableMass = probs[2] + probs[3] + probs[4];
    return DRInferenceResult(
      grade: grade,
      confidenceScores: probs,
      confidence: probs[top1Idx],
      top2Margin: probs[top1Idx] - probs[top2Idx],
      referableScore: referableMass,
      referable: grade.isReferable,
      preprocessingDurationMs: preprocessingDurationMs,
      inferenceDurationMs: inferenceDurationMs,
      processedImageBytes: preview,
      processedImageWidth: processedImageWidth,
      processedImageHeight: processedImageHeight,
      modelId: modelId,
      modelVersion: modelVersion,
      backend: backend,
      rawOutput: List<double>.unmodifiable(rawOutput),
    );
  }

  /// Decodes one continuous ordinal score.
  ///
  /// Grade boundaries use strict `>` (a score exactly on a cut-point stays in
  /// the lower class), byte-parity with the Python reference. Scores outside
  /// `[0, 4]` clamp to the edge classes.
  static OrdinalScoreDecoding decodeOrdinalScore(
    double score, {
    List<double> thresholds = ordinalCutPoints,
  }) {
    if (thresholds.length != 4) {
      throw ArgumentError.value(
        thresholds,
        'thresholds',
        'Ordinal decoding needs exactly 4 cut-points',
      );
    }
    var gradeValue = 0;
    for (final threshold in thresholds) {
      if (score > threshold) gradeValue++;
    }
    gradeValue = gradeValue.clamp(0, 4);

    final probs = compatibilityDistribution(score);
    var top1Idx = 0;
    var top2Idx = 1;
    for (var i = 0; i < 5; i++) {
      if (probs[i] > probs[top1Idx]) {
        top2Idx = top1Idx;
        top1Idx = i;
      } else if (i != top1Idx && probs[i] > probs[top2Idx]) {
        top2Idx = i;
      }
    }

    return OrdinalScoreDecoding(
      grade: DRGrade.fromValue(gradeValue),
      probabilities: probs,
      confidence: probs[top1Idx],
      top2Margin: probs[top1Idx] - probs[top2Idx],
      // Parity with classifier.py: the grade boundary is strict (`>`), but the
      // binary referable flag is `>=`. A score exactly on the referable
      // cut-point is therefore flagged referable while remaining mild NPDR.
      referable: score >= thresholds[1],
    );
  }

  /// Deterministic Gaussian compatibility distribution around [score].
  ///
  /// `p(c) = exp(-0.5 * ((c - score) / sigma)^2)`, then L1-normalised. This is
  /// the server's documented transform for scalar ordinal models; it is not a
  /// calibrated probability and must not be presented as one.
  static List<double> compatibilityDistribution(
    double score, {
    double sigma = kernelSigma,
  }) {
    if (sigma <= 0 || sigma.isNaN || sigma.isInfinite) {
      throw ArgumentError.value(sigma, 'sigma', 'Must be finite and > 0');
    }
    final raw = List<double>.generate(5, (c) {
      final z = (c - score) / sigma;
      return math.exp(-0.5 * z * z);
    });
    final total = raw.fold<double>(0.0, (a, b) => a + b);
    return raw.map((p) => p / total).toList(growable: false);
  }
}
