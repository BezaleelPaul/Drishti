import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_litert/flutter_litert.dart';

import 'pipeline_schema.dart';

/// On-device DR classifier (Ticket A-2) wrapping the parity-gated TFLite
/// artifact of final_model.keras via flutter_litert.
///
/// SHIPPED ARTIFACT: fp32 (15.3 MB) — passed the parity gate with 100%
/// top-1 agreement on the clinical corpus; fp16 measurably drifts
/// (83.3% agreement, 0.29 max prob delta — see results/tflite_parity_*.json)
/// and int8 needs a real calibration corpus (converter ready, planned).
/// Upgrade the constant + pubspec line together when a gated artifact lands.
///
/// PARITY CONTRACT (deviation = silent accuracy destruction):
///   - input:  float32, NHWC [1,384,384,3] (or adaptive [1,S,S,3]), RAW RGB values in [0,255]
///   - the Rescaling(1/255) -> per-channel Normalization -> Rescaling chain
///     lives INSIDE the model graph — never normalize in Dart
///   - resize: bicubic (PIL parity), performed by the caller on the ORIGINAL
///     image, not by this class
class DrClassifierDart {
  DrClassifierDart({
    this.assetPath = defaultModelAsset,
    this.numThreads = 2,
    this.inputSize = 384,
  });

  static const defaultModelAsset =
      'assets/models/dr_efficientnet_b0_tuned_int8.tflite';

  static const fallbackModelAsset =
      'assets/models/dr_efficientnet_b0_fp32.tflite';

  /// Backend identity recorded in screening rows / reports for traceability.
  /// Must stay in sync with the assets/models/README.md shipped artifact.
  static const backendId = 'tflite-int8';

  /// Artifact version identity for audit trails.
  static const artifactVersion = 'efficientnet_b0_int8_v7';

  /// SHA-256 of the shipped calibrated int8 artifact.
  static const assetSha256 =
      '1071E2D5BF8F13CCDFAF2077831E9508F1D7E376378EBC7CFE111C0639F65A44';

  final String assetPath;
  final int numThreads;
  final int inputSize;

  Interpreter? _interpreter;
  bool _initialized = false;

  bool get isReady => _initialized;

  /// Loads the model. Missing/corrupt assets fall back to fp32 or throw [StateError]
  /// — callers must surface AI_UNAVAILABLE and route to human review.
  Future<void> initialize() async {
    if (_initialized) return;
    final options = InterpreterOptions()..threads = numThreads;
    try {
      _interpreter = await Interpreter.fromAsset(assetPath, options: options);
    } catch (e) {
      // Graceful fallback to legacy fp32 if custom int8 path missing in test fixture
      if (assetPath != fallbackModelAsset) {
        try {
          _interpreter = await Interpreter.fromAsset(fallbackModelAsset, options: options);
          _initialized = true;
          return;
        } catch (_) {}
      }
      _interpreter = null;
      _initialized = false;
      throw StateError(
        'On-device DR model not loadable ($assetPath): $e. '
        'Run scripts/convert/convert_to_tflite.py and ship the artifact.',
      );
    }
    _initialized = true;
  }

  /// Runs classification on a canonical RGB image resized to expected dimensions
  /// (bicubic) and serialized as HxWx3 bytes. Returns the DrClassificationResult
  /// mirroring classifier._build_result, or rethrows on inference failure —
  /// the orchestrator maps failures to AI_UNAVAILABLE (fail closed).
  DrClassificationResult classify(Uint8List rgb) {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('DrClassifierDart not initialized');
    }
    final pixelCount = rgb.length ~/ 3;
    final currentSide = math.sqrt(pixelCount.toDouble()).round();
    if (rgb.length != currentSide * currentSide * 3) {
      throw ArgumentError('Expected square HxWx3 RGB bytes, got ${rgb.length}');
    }

    // NHWC float32 raw [0,255] — the in-graph Rescaling layer does the rest.
    final input = Float32List(1 * currentSide * currentSide * 3);
    var j = 0;
    for (var i = 0; i < rgb.length; i += 3) {
      input[j++] = rgb[i].toDouble();
      input[j++] = rgb[i + 1].toDouble();
      input[j++] = rgb[i + 2].toDouble();
    }

    final output = [List<double>.filled(5, 0.0)];
    interpreter.run(input.buffer, output);

    return _buildResult(List<double>.from(output[0]));
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _initialized = false;
  }

  /// Port of classifier._build_result: sum-normalize, top-1/top-2, margin.
  ///
  /// Delegates to the ONE shared derivation
  /// [DrClassificationResult.fromProbabilities] (task 1.2) so the
  /// classifier's result building and the orchestrator conversion (task 2.2)
  /// are computed by the same code and can never disagree. Numbers are
  /// bit-identical to the former inline derivation.
  DrClassificationResult _buildResult(List<double> probs) =>
      DrClassificationResult.fromProbabilities(probs);
}
