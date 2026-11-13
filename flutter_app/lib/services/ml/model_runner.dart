import 'package:image/image.dart' as img;

import 'pipeline_schema.dart';

/// Normalized model output contract across interchangeable graders.
///
/// Honesty contract: [probabilities] and [top2Margin] are only populated when
/// the grader produced a real, calibrated probability vector. Callers must
/// fail closed when they are null — never substitute synthetic values.
class DrModelOutput {
  const DrModelOutput({
    required this.grade,
    required this.probabilities,
    required this.referableScore,
    required this.referable,
    required this.uncertainty,
    required this.modelId,
    required this.modelVersion,
    this.top2Margin,
    this.inferenceMs = 0.0,
  });

  final DrGrade grade;
  final List<double>? probabilities; // null when the grader cannot produce one
  final double? referableScore; // continuous severity or referable mass
  final bool? referable; // true if referable DR (grade >= 2)
  final double? uncertainty; // 1 - top-1 probability, or fold spread
  final String modelId;
  final String modelVersion;

  /// top-1 minus top-2 probability margin. Null when [probabilities] is null.
  /// Feeds ConfidenceEvaluator Rule 2 (class ambiguity) downstream.
  final double? top2Margin;
  final double inferenceMs;
}

/// Abstract contract for interchangeable DR screening models.
abstract class DrModelRunner {
  String get modelId;
  String get modelVersion;

  Future<void> initialize();
  Future<DrModelOutput> predict(img.Image image);
  void dispose();
}

/// DRDetect Ordinal Regression Runner (server-side winner: QWK 0.8931).
///
/// RESERVED SLOT — NOT WIRED ON-DEVICE. The ONNX artifact
/// (`assets/models/efficientnet_b0_regression_512px.onnx`, NCHW
/// [batch,3,512,512]) ships in the repo but is NOT bundled in pubspec assets
/// and no on-device ONNX runtime is integrated. Until one is, `initialize()`
/// throws so the orchestrator fails closed to AI_UNAVAILABLE + human review.
/// It must NEVER simulate a severity score from pixel statistics — a previous
/// red/green channel-ratio stand-in was removed because fabricated clinical
/// output is a safety defect, not a fallback.
class DrDetectRunner implements DrModelRunner {
  DrDetectRunner({
    this.modelAssetPath = defaultOnnxAsset,
    this.thresholds = const [0.5, 1.5, 2.5, 3.5],
  });

  /// Repo location of the ONNX weights (not bundled; server/desktop use only).
  static const defaultOnnxAsset =
      'assets/models/efficientnet_b0_regression_512px.onnx';

  @override
  String get modelId => 'drdetect_ordinal';

  @override
  String get modelVersion => 'v1.0.0-regression-512px';

  final String modelAssetPath;
  final List<double> thresholds;

  @override
  Future<void> initialize() async {
    throw StateError(
      'DrDetectRunner has no on-device ONNX runtime wired. '
      'The ordinal artifact ($modelAssetPath) is not bundled in pubspec '
      'assets and cannot be executed here. Use DrClassifierDart '
      '(TFLite fp32) or the server /retinal/analyze path. '
      'Never substitute a simulated score for a model output.',
    );
  }

  @override
  Future<DrModelOutput> predict(img.Image image) async {
    throw StateError(
      'DrDetectRunner.predict called before initialize(); initialize() '
      'always throws because no on-device ONNX runtime is integrated.',
    );
  }

  @override
  void dispose() {}
}

/// Ordered failover chain of graders, mirroring the server-side backend
/// priority (src/classification/classifier.py: ONNX DRDetect first,
/// Keras TFLite second). [initialize] succeeds when at least ONE runner
/// initializes; [predict] tries runners in order and returns the first
/// successful real output. If every runner fails, both methods throw —
/// callers must map total failure to AI_UNAVAILABLE + human review and
/// never substitute a fabricated grade.
class FallbackModelRunner implements DrModelRunner {
  FallbackModelRunner(this.runners)
    : assert(runners.isNotEmpty, 'FallbackModelRunner needs >= 1 runner');

  final List<DrModelRunner> runners;

  DrModelRunner? _active;

  /// The runner that initialized successfully (null before [initialize]).
  DrModelRunner? get active => _active;

  @override
  String get modelId => _active?.modelId ?? 'unavailable';

  @override
  String get modelVersion => _active?.modelVersion ?? 'unavailable';

  @override
  Future<void> initialize() async {
    if (_active != null) return;
    final errors = <String>[];
    for (final runner in runners) {
      try {
        await runner.initialize();
        _active = runner;
        return;
      } catch (e) {
        errors.add('${runner.modelId}: $e');
      }
    }
    throw StateError(
      'All model runners failed to initialize: ${errors.join(' | ')}',
    );
  }

  /// Runs the first runner that was successfully initialized. If [predict]
  /// throws at runtime (e.g. interpreter crash), falls through to remaining
  /// initialized-capable runners before rethrowing.
  @override
  Future<DrModelOutput> predict(img.Image image) async {
    final active = _active;
    if (active == null) {
      throw StateError('FallbackModelRunner not initialized');
    }
    try {
      return await active.predict(image);
    } catch (primaryError) {
      // Runtime failure of the primary: attempt remaining runners.
      for (final runner in runners) {
        if (runner == active) continue;
        try {
          await runner.initialize();
          final out = await runner.predict(image);
          _active = runner;
          return out;
        } catch (_) {
          continue;
        }
      }
      throw StateError(
        'All model runners failed on predict (primary error: $primaryError)',
      );
    }
  }

  @override
  void dispose() {
    for (final runner in runners) {
      try {
        runner.dispose();
      } catch (_) {
        // Best-effort cleanup; never mask a dispose error to the caller.
      }
    }
    _active = null;
  }
}
