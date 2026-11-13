import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

import 'drishti_inference_engine.dart';
import 'dr_inference_result.dart';
import 'pipeline_exceptions.dart';
import 'retinal_preprocess_config.dart';

/// Long-lived background isolate that owns the LiteRT interpreter.
///
/// WHY A LONG-LIVED WORKER: interpreter construction costs ~200-600 ms plus a
/// 15.3 MB asset read, so spawning a fresh isolate per analysis would dominate
/// inference time. One worker is created on first use, keeps the model warm,
/// and processes requests strictly one at a time (LiteRT interpreters are not
/// reentrant).
///
/// THREADING CONTRACT:
/// - The UI isolate only serialises bytes/objects and awaits; it never decodes,
///   blurs, resizes, or invokes native code.
/// - [analyzeEncodedBytes] decodes the JPEG/PNG *inside the worker*.
/// - [analyzeDecoded] forwards an already-decoded `img.Image` (used by the
///   orchestrator, which must decode for the quality gate anyway).
///
/// FAILURE MODEL: every failure surfaces as [PreprocessingException] (bad
/// frame) or [InferenceException] (model/runtime). After an inference or
/// internal error the worker is torn down so the next call re-initialises a
/// clean interpreter; preprocessing failures keep the warm engine.
class RetinalAnalysisIsolateBridge {
  RetinalAnalysisIsolateBridge({
    this.modelAsset = DrishtiInferenceEngine.shippedOrdinalAsset,
    this.modelId = DrishtiInferenceEngine.shippedOrdinalModelId,
    this.modelVersion = DrishtiInferenceEngine.shippedOrdinalModelVersion,
    this.expectedSha256,
    this.preprocessConfig = RetinalPreprocessConfig.ordinal512ImageNet,
    this.outputKind = DrOutputKind.ordinalScalar,
    this.backend = DrComputeBackend.xnnpack,
    this.numThreads = 2,
    this.initTimeout = const Duration(seconds: 30),
    this.analysisTimeout = const Duration(seconds: 45),
    Uint8List? modelBytes,
  }) : _modelBytes = modelBytes;

  final String modelAsset;
  final String modelId;
  final String modelVersion;
  final String? expectedSha256;
  final RetinalPreprocessConfig preprocessConfig;
  final DrOutputKind outputKind;
  final DrComputeBackend backend;
  final int numThreads;
  final Duration initTimeout;
  final Duration analysisTimeout;

  /// Test hook: bypass `rootBundle`. The buffer is copied for each spawn, so
  /// it stays valid across worker restarts.
  final Uint8List? _modelBytes;

  Isolate? _worker;
  SendPort? _commands;
  ReceivePort? _responses;
  ReceivePort? _exits;
  ReceivePort? _errors;
  Completer<void>? _ready;
  Completer<void>? _exited;
  Completer<DRInferenceResult>? _pending;
  String? _activeBackend;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();

  /// Backend reported by the worker (`cpu`, `xnnpack`, `gpu`), or null.
  String? get activeBackend => _activeBackend;

  /// True when a worker exists and its engine is loaded.
  bool get isReady => _commands != null;

  /// Starts the worker and loads the model. Idempotent; safe to call from
  /// `initState` to hide cold-start latency behind the UI.
  Future<void> initialize() {
    return _serial(() => _ensureInitializedLocked());
  }

  /// Decodes [encodedImage] (JPEG/PNG bytes) and runs the full pipeline in the
  /// worker. Never blocks the calling isolate on image work.
  Future<DRInferenceResult> analyzeEncodedBytes(
    Uint8List encodedImage, {
    bool validate = true,
    bool includePreview = true,
  }) {
    return _serial(() async {
      _checkUsable();
      if (encodedImage.isEmpty) {
        throw const PreprocessingException(
          PreprocessingFailureReason.emptyImage,
          'Encoded image buffer is empty.',
        );
      }
      await _ensureInitializedLocked();
      return _sendAnalyze(
        _AnalyzeEncodedCommand(
          TransferableTypedData.fromList([encodedImage]),
          validate,
          includePreview,
        ),
      );
    });
  }

  /// Runs the pipeline on an already-decoded frame.
  ///
  /// The image is deep-copied into the worker by the message serializer (a
  /// memcpy of the pixel buffer), so no Dart-level pixel work happens on the
  /// caller and the caller's image remains usable.
  Future<DRInferenceResult> analyzeDecoded(
    img.Image image, {
    bool validate = false,
    bool includePreview = false,
  }) {
    return _serial(() async {
      _checkUsable();
      if (image.width <= 0 || image.height <= 0) {
        throw PreprocessingException(
          PreprocessingFailureReason.invalidDimensions,
          'Invalid image dimensions ${image.width}x${image.height}.',
        );
      }
      await _ensureInitializedLocked();
      return _sendAnalyze(
        _AnalyzeDecodedCommand(image, validate, includePreview),
      );
    });
  }

  /// Stops the worker and frees its interpreter. Idempotent.
  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    return _serial(() async {
      _disposed = true;
      final commands = _commands;
      if (commands != null) {
        try {
          commands.send(const _DisposeCommand());
        } catch (_) {
          // Worker already gone.
        }
        try {
          await _exited?.future.timeout(const Duration(seconds: 2));
        } catch (_) {
          // Fall through to a hard kill below.
        }
      }
      _killWorker();
      _cleanupPorts();
    });
  }

  // ---------------------------------------------------------------------------
  // Serialisation + lifecycle
  // ---------------------------------------------------------------------------

  /// Runs [action] after every previously queued action, even if they failed.
  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _checkUsable() {
    if (_disposed) {
      throw const InferenceException('Retinal analysis bridge is disposed.');
    }
  }

  Future<void> _ensureInitializedLocked() async {
    _checkUsable();
    if (_commands != null) return;
    await _spawnLocked();
  }

  Future<void> _spawnLocked() async {
    final responses = ReceivePort();
    final exits = ReceivePort();
    final errors = ReceivePort();
    final ready = Completer<void>();
    final exited = Completer<void>();

    _responses = responses;
    _exits = exits;
    _errors = errors;
    _ready = ready;
    _exited = exited;

    responses.listen(_onWorkerMessage);
    exits.listen((_) {
      if (!exited.isCompleted) exited.complete();
      _onWorkerGone(
        'Analysis worker isolate exited unexpectedly.',
        modelUnavailable: false,
      );
    });
    errors.listen((message) {
      final text = message is List && message.isNotEmpty
          ? '${message.first}'
          : '$message';
      _onWorkerGone('Analysis worker crashed: $text', modelUnavailable: false);
    });

    final Uint8List bytes;
    try {
      bytes = await _loadModelBytes();
    } catch (error, stackTrace) {
      _cleanupPorts();
      throw InferenceException(
        'Unable to read model asset $modelAsset: $error',
        modelUnavailable: true,
        cause: error,
        stackTrace: stackTrace,
      );
    }

    final Isolate worker;
    try {
      worker = await Isolate.spawn<_WorkerBootstrap>(
        _drAnalysisWorkerMain,
        _WorkerBootstrap(
          responses.sendPort,
          TransferableTypedData.fromList([bytes]),
          preprocessConfig,
          outputKind,
          backend,
          numThreads,
          modelId,
          modelVersion,
          expectedSha256,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
        debugName: 'drishti-analysis-worker',
      );
    } catch (error, stackTrace) {
      _cleanupPorts();
      throw InferenceException(
        'Unable to start analysis worker: $error',
        modelUnavailable: true,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    _worker = worker;

    try {
      await ready.future.timeout(initTimeout);
    } on TimeoutException {
      _killWorker();
      _cleanupPorts();
      throw InferenceException(
        'Model initialization timed out after '
        '${initTimeout.inSeconds}s ($modelAsset).',
        modelUnavailable: true,
      );
    } catch (_) {
      _killWorker();
      _cleanupPorts();
      rethrow;
    }
  }

  Future<Uint8List> _loadModelBytes() async {
    final injected = _modelBytes;
    if (injected != null) return injected;
    final data = await rootBundle.load(modelAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  // ---------------------------------------------------------------------------
  // Messaging
  // ---------------------------------------------------------------------------

  Future<DRInferenceResult> _sendAnalyze(Object command) {
    final commands = _commands;
    if (commands == null) {
      throw const InferenceException(
        'Analysis worker is not running.',
        modelUnavailable: true,
      );
    }
    final completer = Completer<DRInferenceResult>();
    _pending = completer;

    try {
      commands.send(command);
    } catch (error, stackTrace) {
      _pending = null;
      throw InferenceException(
        'Unable to dispatch analysis to the worker: $error',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    return completer.future.timeout(
      analysisTimeout,
      onTimeout: () {
        _pending = null;
        _killWorker();
        _cleanupPorts();
        throw InferenceException(
          'On-device analysis timed out after '
          '${analysisTimeout.inSeconds}s.',
        );
      },
    );
  }

  void _onWorkerMessage(Object? message) {
    if (message is _WorkerReady) {
      _commands = message.commandPort;
      _activeBackend = message.backend;
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    if (message is _WorkerInitFailed) {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(
          InferenceException(message.message, modelUnavailable: true),
        );
      }
      return;
    }
    if (message is _AnalyzeReply) {
      final pending = _pending;
      _pending = null;
      if (pending != null && !pending.isCompleted) {
        pending.complete(message.result);
      }
      return;
    }
    if (message is _ErrorReply) {
      final pending = _pending;
      _pending = null;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(_rebuildError(message));
      }
      if (message.kind != 'preprocessing') {
        // The native interpreter may be in an undefined state after an
        // invoke failure; force a clean re-init on the next request.
        _killWorker();
        _cleanupPorts();
      }
    }
  }

  Exception _rebuildError(_ErrorReply reply) {
    switch (reply.kind) {
      case 'preprocessing':
        final reason = PreprocessingFailureReason.values.firstWhere(
          (value) => value.name == reply.reason,
          orElse: () => PreprocessingFailureReason.decodeFailed,
        );
        return PreprocessingException(reason, reply.message);
      case 'inference':
        return InferenceException(reply.message);
      default:
        return InferenceException(
          'Internal analysis failure: ${reply.message}',
        );
    }
  }

  void _onWorkerGone(String message, {required bool modelUnavailable}) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        InferenceException(message, modelUnavailable: modelUnavailable),
      );
    }
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(InferenceException(message));
    }
    _worker = null;
    _commands = null;
    _activeBackend = null;
    _cleanupPorts();
  }

  void _killWorker() {
    final worker = _worker;
    _worker = null;
    _commands = null;
    _activeBackend = null;
    if (worker != null) {
      try {
        worker.kill(priority: Isolate.immediate);
      } catch (_) {
        // Already dead.
      }
    }
  }

  void _cleanupPorts() {
    _responses?.close();
    _exits?.close();
    _errors?.close();
    _responses = null;
    _exits = null;
    _errors = null;
    _ready = null;
  }
}

// -----------------------------------------------------------------------------
// Worker protocol (private, same-isolate-group value types)
// -----------------------------------------------------------------------------

class _WorkerBootstrap {
  const _WorkerBootstrap(
    this.replyPort,
    this.modelBytes,
    this.config,
    this.outputKind,
    this.backend,
    this.numThreads,
    this.modelId,
    this.modelVersion,
    this.expectedSha256,
  );

  final SendPort replyPort;
  final TransferableTypedData modelBytes;
  final RetinalPreprocessConfig config;
  final DrOutputKind outputKind;
  final DrComputeBackend backend;
  final int numThreads;
  final String modelId;
  final String modelVersion;
  final String? expectedSha256;
}

class _WorkerReady {
  const _WorkerReady(this.commandPort, this.backend);

  final SendPort commandPort;
  final String backend;
}

class _WorkerInitFailed {
  const _WorkerInitFailed(this.message);

  final String message;
}

class _AnalyzeEncodedCommand {
  const _AnalyzeEncodedCommand(
    this.encoded,
    this.validate,
    this.includePreview,
  );

  final TransferableTypedData encoded;
  final bool validate;
  final bool includePreview;
}

class _AnalyzeDecodedCommand {
  const _AnalyzeDecodedCommand(this.image, this.validate, this.includePreview);

  final img.Image image;
  final bool validate;
  final bool includePreview;
}

class _AnalyzeReply {
  const _AnalyzeReply(this.result);

  final DRInferenceResult result;
}

class _ErrorReply {
  const _ErrorReply(this.kind, this.message, [this.reason]);

  final String kind;
  final String message;
  final String? reason;
}

class _DisposeCommand {
  const _DisposeCommand();
}

/// Worker isolate entry point. Must stay top-level (and therefore
/// entry-point-retained) for `Isolate.spawn`.
@pragma('vm:entry-point')
Future<void> _drAnalysisWorkerMain(_WorkerBootstrap bootstrap) async {
  final commands = ReceivePort();

  final DrishtiInferenceEngine engine;
  try {
    final bytes = bootstrap.modelBytes.materialize().asUint8List();
    engine = await DrishtiInferenceEngine.createFromBytes(
      bytes,
      preprocessConfig: bootstrap.config,
      outputKind: bootstrap.outputKind,
      backend: bootstrap.backend,
      numThreads: bootstrap.numThreads,
      modelId: bootstrap.modelId,
      modelVersion: bootstrap.modelVersion,
      expectedSha256: bootstrap.expectedSha256,
    );
  } catch (error) {
    bootstrap.replyPort.send(_WorkerInitFailed('$error'));
    commands.close();
    return;
  }

  bootstrap.replyPort.send(
    _WorkerReady(commands.sendPort, engine.backendLabel),
  );

  commands.listen((Object? message) {
    if (message is _DisposeCommand) {
      engine.dispose();
      commands.close();
      return;
    }
    if (message is _AnalyzeEncodedCommand) {
      _handleEncoded(bootstrap.replyPort, engine, message);
      return;
    }
    if (message is _AnalyzeDecodedCommand) {
      _handleDecoded(bootstrap.replyPort, engine, message);
    }
  });
}

void _handleEncoded(
  SendPort replyPort,
  DrishtiInferenceEngine engine,
  _AnalyzeEncodedCommand command,
) {
  try {
    final encoded = command.encoded.materialize().asUint8List();
    final image = img.decodeImage(encoded);
    if (image == null) {
      throw const PreprocessingException(
        PreprocessingFailureReason.decodeFailed,
        'Unsupported or corrupt image encoding.',
      );
    }
    final result = engine.analyze(
      image,
      validate: command.validate,
      includePreview: command.includePreview,
    );
    replyPort.send(_AnalyzeReply(result));
  } on PreprocessingException catch (error) {
    replyPort.send(
      _ErrorReply('preprocessing', error.message, error.reason.name),
    );
  } on InferenceException catch (error) {
    replyPort.send(_ErrorReply('inference', error.message));
  } catch (error) {
    replyPort.send(_ErrorReply('internal', '$error'));
  }
}

void _handleDecoded(
  SendPort replyPort,
  DrishtiInferenceEngine engine,
  _AnalyzeDecodedCommand command,
) {
  try {
    final result = engine.analyze(
      command.image,
      validate: command.validate,
      includePreview: command.includePreview,
    );
    replyPort.send(_AnalyzeReply(result));
  } on PreprocessingException catch (error) {
    replyPort.send(
      _ErrorReply('preprocessing', error.message, error.reason.name),
    );
  } on InferenceException catch (error) {
    replyPort.send(_ErrorReply('inference', error.message));
  } catch (error) {
    replyPort.send(_ErrorReply('internal', '$error'));
  }
}
