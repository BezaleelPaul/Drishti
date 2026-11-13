import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_litert/native.dart';
import 'package:image/image.dart' as img;

import 'dr_inference_result.dart';
import 'pipeline_exceptions.dart';
import 'retinal_preprocess_config.dart';
import 'retinal_preprocessor.dart';

/// Hardware backend used to create the LiteRT interpreter.
enum DrComputeBackend {
  /// Plain CPU kernels, no delegate. Slowest, most portable.
  cpu,

  /// XNNPack CPU delegate. Default on Android: ~2-4x over reference kernels
  /// on EfficientNet-B0 with no GPU-driver variance.
  xnnpack,

  /// GPU delegate. Fast on flagship devices but has driver-specific
  /// correctness issues; only enable after validating on the target fleet.
  gpu,
}

/// Output contract of the loaded artifact.
enum DrOutputKind {
  /// `[1,1]` continuous severity score; decoded with strict cut-points.
  ordinalScalar,

  /// `[1,5]` class scores; softmax-normalised then argmaxed.
  fiveClass,
}

/// Loads and owns exactly one LiteRT interpreter.
///
/// Designed to be created and used inside a background isolate: it allocates
/// the interpreter on the calling isolate and never touches `rootBundle`
/// except in [createFromAsset], which must be called on the UI isolate.
///
/// LIFETIME: [dispose] must run on the same isolate that created the engine,
/// after the last [runTensor] call. It closes the interpreter before deleting
/// the delegate (the delegate must outlive the interpreter) and the options.
class DrishtiInferenceEngine {
  DrishtiInferenceEngine._({
    required Interpreter interpreter,
    required InterpreterOptions options,
    required Delegate? delegate,
    required this.preprocessConfig,
    required this.outputKind,
    required this.modelId,
    required this.modelVersion,
    required this.requestedBackend,
  }) : _interpreter = interpreter,
       _options = options,
       _delegate = delegate;

  /// Shipped ordinal artifact metadata (kept in sync with the synchronous
  /// runner so both paths report the same identity).
  static const shippedOrdinalAsset =
      'assets/models/drdetect_ordinal_512_fp32.tflite';
  static const shippedOrdinalModelId = 'drdetect_ordinal_tflite';
  static const shippedOrdinalModelVersion = 'v1.0.0-ordinal-512px-fp32';
  static const shippedOrdinalSha256 =
      '8644E287098D347F2D91A6327ACD5ED90A263E6535A8308EEA4B5BF3B82CE3C0';

  final RetinalPreprocessConfig preprocessConfig;
  final DrOutputKind outputKind;
  final String modelId;
  final String modelVersion;
  final DrComputeBackend requestedBackend;

  final Interpreter _interpreter;
  final InterpreterOptions _options;
  final Delegate? _delegate;
  bool _closed = false;

  /// Backend that actually took the model (`cpu` when the delegate declined).
  String get backendLabel {
    if (!_interpreter.hasActiveDelegate) return 'cpu';
    return requestedBackend == DrComputeBackend.gpu ? 'gpu' : 'xnnpack';
  }

  bool get isClosed => _closed;

  /// Creates an engine from raw model bytes.
  ///
  /// When [expectedSha256] is non-null the bytes are hashed and a mismatch
  /// throws [InferenceException] before any native allocation happens. The
  /// hash is uppercase hex, matching the build manifest.
  static Future<DrishtiInferenceEngine> createFromBytes(
    Uint8List modelBytes, {
    RetinalPreprocessConfig preprocessConfig =
        RetinalPreprocessConfig.ordinal512ImageNet,
    DrOutputKind outputKind = DrOutputKind.ordinalScalar,
    DrComputeBackend backend = DrComputeBackend.xnnpack,
    int numThreads = 2,
    String modelId = shippedOrdinalModelId,
    String modelVersion = shippedOrdinalModelVersion,
    String? expectedSha256,
  }) async {
    if (modelBytes.isEmpty) {
      throw const InferenceException(
        'Model buffer is empty.',
        modelUnavailable: true,
      );
    }
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      final actual = sha256.convert(modelBytes).toString().toUpperCase();
      if (actual != expectedSha256.toUpperCase()) {
        throw InferenceException(
          'Model integrity check failed (expected $expectedSha256, got '
          '$actual). Reinstall the app or restore the shipped asset.',
          modelUnavailable: true,
        );
      }
    }

    final performanceConfig = switch (backend) {
      DrComputeBackend.cpu => PerformanceConfig.disabled,
      DrComputeBackend.xnnpack => PerformanceConfig.xnnpack(
        numThreads: numThreads,
      ),
      DrComputeBackend.gpu => const PerformanceConfig.gpu(),
    };
    final InterpreterOptions options;
    final Delegate? delegate;
    try {
      (options, delegate) = InterpreterFactory.create(performanceConfig);
    } catch (error, stackTrace) {
      throw InferenceException(
        'Unable to configure the LiteRT interpreter: $error',
        modelUnavailable: true,
        cause: error,
        stackTrace: stackTrace,
      );
    }

    Interpreter interpreter;
    try {
      interpreter = Interpreter.fromBuffer(modelBytes, options: options);
    } catch (error, stackTrace) {
      delegate?.delete();
      options.delete();
      throw InferenceException(
        'Failed to create LiteRT interpreter: $error',
        modelUnavailable: true,
        cause: error,
        stackTrace: stackTrace,
      );
    }

    try {
      _validateTensors(
        interpreter,
        preprocessConfig: preprocessConfig,
        outputKind: outputKind,
      );
    } catch (_) {
      interpreter.close();
      delegate?.delete();
      options.delete();
      rethrow;
    }

    return DrishtiInferenceEngine._(
      interpreter: interpreter,
      options: options,
      delegate: delegate,
      preprocessConfig: preprocessConfig,
      outputKind: outputKind,
      modelId: modelId,
      modelVersion: modelVersion,
      requestedBackend: backend,
    );
  }

  /// Loads a bundled `.tflite` asset. **UI-isolate only** (`rootBundle`
  /// depends on the Flutter binding); send the resulting bytes to the worker
  /// isolate and use [createFromBytes] there.
  static Future<DrishtiInferenceEngine> createFromAsset(
    String assetPath, {
    RetinalPreprocessConfig preprocessConfig =
        RetinalPreprocessConfig.ordinal512ImageNet,
    DrOutputKind outputKind = DrOutputKind.ordinalScalar,
    DrComputeBackend backend = DrComputeBackend.xnnpack,
    int numThreads = 2,
    String modelId = shippedOrdinalModelId,
    String modelVersion = shippedOrdinalModelVersion,
    String? expectedSha256,
  }) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return createFromBytes(
      bytes,
      preprocessConfig: preprocessConfig,
      outputKind: outputKind,
      backend: backend,
      numThreads: numThreads,
      modelId: modelId,
      modelVersion: modelVersion,
      expectedSha256: expectedSha256,
    );
  }

  static void _validateTensors(
    Interpreter interpreter, {
    required RetinalPreprocessConfig preprocessConfig,
    required DrOutputKind outputKind,
  }) {
    final input = interpreter.getInputTensor(0);
    if (input.type != TensorType.float32) {
      throw InferenceException(
        'Model input must be float32, found ${input.type}.',
        modelUnavailable: true,
      );
    }
    final size = preprocessConfig.outputSize;
    final expected = <int>[1, size, size, 3];
    final shape = input.shape;
    if (shape.length != expected.length || !_sameShape(shape, expected)) {
      throw InferenceException(
        'Model input shape $shape does not match the expected $expected '
        'contract.',
        modelUnavailable: true,
      );
    }

    final output = interpreter.getOutputTensor(0);
    if (output.type != TensorType.float32) {
      throw InferenceException(
        'Model output must be float32, found ${output.type}.',
        modelUnavailable: true,
      );
    }
    final expectedOutput = outputKind == DrOutputKind.ordinalScalar ? 1 : 5;
    final outputElements = output.asFloat32View().length;
    if (outputElements != expectedOutput) {
      throw InferenceException(
        'Model output has $outputElements values; the '
        '${outputKind.name} contract needs $expectedOutput.',
        modelUnavailable: true,
      );
    }
  }

  static bool _sameShape(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Runs one NHWC float32 tensor through the graph.
  ///
  /// Returns raw output values and the invoke-only duration. The input copy is
  /// excluded from the duration (it is a `Float32List.setAll` memcpy).
  RawInferenceOutput runTensor(Float32List tensor) {
    if (_closed) {
      throw const InferenceException('Inference engine is already disposed.');
    }
    final input = _interpreter.getInputTensor(0);
    final view = input.asFloat32View();
    if (view.length != tensor.length) {
      throw InferenceException(
        'Tensor has ${tensor.length} values; model expects ${view.length}.',
        modelUnavailable: true,
      );
    }

    view.setAll(0, tensor);

    final stopwatch = Stopwatch()..start();
    try {
      _interpreter.invoke();
    } catch (error, stackTrace) {
      throw InferenceException(
        'Model invocation failed: $error',
        cause: error,
        stackTrace: stackTrace,
      );
    }
    stopwatch.stop();

    final outView = _interpreter.getOutputTensor(0).asFloat32View();
    final raw = List<double>.generate(
      outView.length,
      (i) => outView[i],
      growable: false,
    );
    return RawInferenceOutput(
      values: raw,
      inferenceMicros: stopwatch.elapsedMicroseconds,
    );
  }

  /// Full analyse path for callers that already hold a decoded image.
  ///
  /// Preprocessing runs on the calling isolate, so this is synchronous and
  /// must only be called from the analysis worker (or a test), never the UI
  /// isolate.
  DRInferenceResult analyze(
    img.Image image, {
    bool validate = true,
    bool includePreview = true,
  }) {
    final preprocessed = RetinalPreprocessor.prepareForModel(
      image,
      config: preprocessConfig,
      validate: validate,
      includePreview: includePreview,
    );
    final raw = runTensor(preprocessed.tensor);

    final preprocessMs = preprocessed.preprocessingMicros / 1000.0;
    final inferenceMs = raw.inferenceMicros / 1000.0;
    return DrishtiOutputDecoder.decode(
      ordinal: outputKind == DrOutputKind.ordinalScalar,
      rawOutput: raw.values,
      preprocessingDurationMs: preprocessMs.round(),
      inferenceDurationMs: inferenceMs.round(),
      modelId: modelId,
      modelVersion: modelVersion,
      backend: backendLabel,
      processedImageBytes: preprocessed.previewBytes,
      processedImageWidth: preprocessed.previewWidth,
      processedImageHeight: preprocessed.previewHeight,
    );
  }

  /// Releases native memory. Idempotent.
  void dispose() {
    if (_closed) return;
    _closed = true;
    try {
      _interpreter.close();
    } finally {
      try {
        _delegate?.delete();
      } finally {
        _options.delete();
      }
    }
  }
}

/// Raw model output plus invoke-only timing.
class RawInferenceOutput {
  const RawInferenceOutput({
    required this.values,
    required this.inferenceMicros,
  });

  final List<double> values;
  final int inferenceMicros;
}
