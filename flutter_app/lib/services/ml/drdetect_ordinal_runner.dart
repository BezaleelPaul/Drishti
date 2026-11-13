import 'dart:typed_data';

import 'package:flutter_litert/flutter_litert.dart';
import 'package:image/image.dart' as img;

import 'model_runner.dart';
import 'pipeline/dr_inference_result.dart';
import 'pipeline/retinal_preprocess_config.dart';
import 'pipeline/retinal_preprocessor.dart';

/// On-device runner for the DRDetect ordinal-regression model, converted
/// from `efficientnet_b0_regression_512px.onnx` via onnx2tf and parity-gated
/// against the ONNX reference (10/10 grade agreement, max |score diff|
/// 3e-5 — see results/drdetect_tflite_parity.json).
///
/// ARTIFACT CONTRACT (deviation = silent accuracy destruction):
///   - asset:  assets/models/drdetect_ordinal_512_fp32.tflite (fp32, ~15.3 MB)
///   - input:  float32, NHWC [1,512,512,3], ImageNet-normalized
///     (mean [0.485,0.456,0.406], std [0.229,0.224,0.225]) — normalization
///     happens outside the graph (unlike the Keras model).
///   - output: float32 [1,1] continuous ordinal severity score.
///   - decode: cut-points [0.5, 1.5, 2.5, 3.5] (byte-parity with
///     src/classification/classifier.py::_predict_onnx_drdetect).
///
/// PREPROCESSING now lives in [RetinalPreprocessor] and decoding in
/// [DrishtiOutputDecoder], shared with the background-isolate path so the two
/// can never drift. This synchronous runner remains the failover when the
/// analysis isolate cannot start, and keeps the golden-parity test hooks.
class DrDetectOrdinalTfliteRunner implements DrModelRunner {
  DrDetectOrdinalTfliteRunner({
    this.numThreads = 2,
    this.thresholds = defaultThresholds,
  });

  /// Shipped converted artifact (onnx2tf output, fp32).
  static const shippedModelAsset =
      'assets/models/drdetect_ordinal_512_fp32.tflite';

  static const defaultThresholds = [0.5, 1.5, 2.5, 3.5];

  /// Kernel width of the server's ordinal compatibility distribution.
  static const double kernelSigma = DrishtiOutputDecoder.kernelSigma;

  /// Working resolution for the Ben Graham fast path.
  static const maxWorkingSide = 768;

  /// Sigma of the Python reference (`classifier.py`) at native resolution.
  static const double nativeBlurSigma = 20.0;

  /// Documented measured bound on score drift introduced by the working-size
  /// fast path (results/drdetect_fastpreprocess_tolerance.json).
  static const maxPreprocessScoreDrift = 0.12;

  static const backendId = 'drdetect_ordinal_tflite';
  static const artifactVersion = 'v1.0.0-ordinal-512px-fp32';
  static const assetSha256 =
      '8644E287098D347F2D91A6327ACD5ED90A263E6535A8308EEA4B5BF3B82CE3C0';

  final int numThreads;
  final List<double> thresholds;

  Interpreter? _interpreter;
  bool _initialized = false;

  bool get isReady => _initialized;

  @override
  String get modelId => backendId;

  @override
  String get modelVersion => artifactVersion;

  /// Loads the converted TFLite artifact. Missing/corrupt assets throw
  /// [StateError] — the fallback chain then tries the Keras TFLite model,
  /// and the orchestrator maps total failure to AI_UNAVAILABLE + review.
  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final options = InterpreterOptions()..threads = numThreads;
    try {
      _interpreter = await Interpreter.fromAsset(
        shippedModelAsset,
        options: options,
      );
    } catch (e) {
      _interpreter = null;
      _initialized = false;
      throw StateError(
        'DRDetect ordinal TFLite model not loadable ($shippedModelAsset): $e. '
        'Re-convert with scripts/convert (onnx2tf) and re-run '
        'validate_drdetect_tflite.py before shipping.',
      );
    }
    _initialized = true;
  }

  /// Full preprocessing + inference. Throws [StateError] when uninitialized,
  /// [ArgumentError] on degenerate crops — callers must map failures to
  /// AI_UNAVAILABLE, never to a substitute grade.
  @override
  Future<DrModelOutput> predict(img.Image image) async {
    final interpreter = _interpreter;
    if (interpreter == null || !_initialized) {
      throw StateError('DrDetectOrdinalTfliteRunner not initialized');
    }

    final sw = Stopwatch()..start();
    final input = RetinalPreprocessor.toModelTensor(
      image,
      config: RetinalPreprocessConfig.ordinal512ImageNet,
    );

    final output = [List<double>.filled(1, 0.0)];
    interpreter.run(input.buffer, output);
    final score = output[0][0];
    if (score.isNaN || score.isInfinite) {
      throw StateError('DRDetect ordinal model returned non-finite score');
    }
    sw.stop();

    return decodeScoreForTest(
      score,
      inferenceMs: sw.elapsedMicroseconds / 1000.0,
    );
  }

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _initialized = false;
  }

  /// Full preprocessing (crop -> Ben Graham fast path -> normalize -> NHWC)
  /// exposed for the golden parity test. Same code path as [predict], minus
  /// the interpreter call, so the test asserts exactly what inference sees.
  static Float32List preprocessToNhwcForTest(img.Image image) {
    return RetinalPreprocessor.toModelTensor(
      image,
      config: RetinalPreprocessConfig.ordinal512ImageNet,
    );
  }

  /// Cut-point decoding + kernel distribution — byte-parity with
  /// classifier._predict_onnx_drdetect steps 3-4. Exposed for unit tests.
  DrModelOutput decodeScoreForTest(double score, {double inferenceMs = 0}) {
    final decoded = DrishtiOutputDecoder.decodeOrdinalScore(
      score,
      thresholds: thresholds,
    );
    return DrModelOutput(
      grade: decoded.grade,
      probabilities: decoded.probabilities,
      referableScore: score,
      referable: decoded.referable,
      // Uncertainty follows the same convention as LegacyClassifierAdapter
      // (1 - top1) so the orchestrator's >0.4 check behaves identically to
      // the softmax confidence gate instead of firing on every ordinal
      // result (exp(-dist) is bounded in [0.61, 1.0] for 1.0-spaced cuts).
      uncertainty: 1.0 - decoded.confidence,
      modelId: backendId,
      modelVersion: artifactVersion,
      top2Margin: decoded.top2Margin,
      inferenceMs: inferenceMs,
    );
  }
}
