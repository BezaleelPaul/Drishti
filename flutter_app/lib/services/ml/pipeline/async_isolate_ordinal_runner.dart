import 'dart:async';

import 'package:image/image.dart' as img;

import '../model_runner.dart';
import 'drishti_inference_engine.dart';
import 'retinal_analysis_isolate_bridge.dart';

/// Drop-in [DrModelRunner] that executes preprocessing and inference in a
/// long-lived background isolate.
///
/// This is the preferred first entry in [FallbackModelRunner]: the synchronous
/// [DrDetectOrdinalTfliteRunner] remains as a failover if the isolate cannot
/// start (e.g. a platform without LiteRT native libraries). Both use the same
/// [RetinalPreprocessor] and decoder, so a failover cannot change the
/// preprocessing contract.
///
/// QUALITY GATE: `predict` passes `validate: false`, matching the synchronous
/// runner. Frame quality is decided by the calibrated `QualityGateDart` in the
/// orchestrator *before* prediction; adding a second, stricter guard here
/// would reject frames the gate accepted.
class AsyncIsolateOrdinalRunner implements DrModelRunner {
  AsyncIsolateOrdinalRunner({RetinalAnalysisIsolateBridge? bridge})
    : _bridge = bridge ?? RetinalAnalysisIsolateBridge();

  final RetinalAnalysisIsolateBridge _bridge;
  bool _initialized = false;

  /// Backend actually used by the worker (`cpu`/`xnnpack`/`gpu`), or null.
  String? get activeBackend => _bridge.activeBackend;

  @override
  String get modelId => DrishtiInferenceEngine.shippedOrdinalModelId;

  @override
  String get modelVersion => DrishtiInferenceEngine.shippedOrdinalModelVersion;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await _bridge.initialize();
      _initialized = true;
    } catch (error) {
      throw StateError(
        'Async DRDetect runner could not start its analysis isolate '
        '(${DrishtiInferenceEngine.shippedOrdinalAsset}): $error',
      );
    }
  }

  @override
  Future<DrModelOutput> predict(img.Image image) async {
    if (!_initialized) {
      throw StateError('AsyncIsolateOrdinalRunner not initialized');
    }
    final result = await _bridge.analyzeDecoded(
      image,
      validate: false,
      includePreview: false,
    );
    return DrModelOutput(
      grade: result.grade,
      probabilities: result.confidenceScores,
      referableScore: result.referableScore,
      referable: result.referable,
      // Same convention as the synchronous ordinal runner / legacy adapter:
      // 1 - top1, so the orchestrator's uncertainty gate is behaviour-neutral.
      uncertainty: 1.0 - result.confidence,
      modelId: result.modelId,
      modelVersion: result.modelVersion,
      top2Margin: result.top2Margin,
      // Matches the synchronous runner's semantics: end-to-end model latency
      // (preprocessing + invoke), not just the native call.
      inferenceMs: result.totalDurationMs.toDouble(),
    );
  }

  /// Fire-and-forget native cleanup. The interface is synchronous; the worker
  /// teardown completes shortly after and is safe if the app is exiting.
  @override
  void dispose() {
    _initialized = false;
    unawaited(_bridge.dispose());
  }
}
