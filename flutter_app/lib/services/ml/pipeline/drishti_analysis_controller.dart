import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dr_inference_result.dart';
import 'pipeline_exceptions.dart';
import 'retinal_analysis_service.dart';

/// Observable lifecycle for one on-device analysis.
enum DrishtiAnalysisState {
  /// Nothing requested yet.
  idle,

  /// Worker warm-up, decode, preprocessing or inference in progress.
  analyzing,

  /// A real model result is available in [DrishtiAnalysisController.result].
  success,

  /// The analysis failed; see `errorMessage`/`failureReason`.
  failure,
}

/// Minimal `ChangeNotifier` adapter for the enhanced analysis screen.
///
/// Usage:
/// ```dart
/// final controller = DrishtiAnalysisController()..warmUp();
/// // ...
/// await controller.analyzeFile(path);
/// // build(): switch (controller.state) { ... }
/// // dispose(): controller.dispose();
/// ```
///
/// It never fabricates a result: on failure [state] is
/// [DrishtiAnalysisState.failure] and `result` is cleared. A newer request
/// supersedes an in-flight one from the UI's perspective (the worker still
/// finishes the older one, but its result is dropped).
class DrishtiAnalysisController extends ChangeNotifier {
  DrishtiAnalysisController({RetinalAnalysisService? service})
    : _service = service ?? RetinalAnalysisService();

  final RetinalAnalysisService _service;

  DrishtiAnalysisState _state = DrishtiAnalysisState.idle;
  DRInferenceResult? _result;
  String? _errorMessage;
  PreprocessingFailureReason? _failureReason;
  bool _disposed = false;
  int _runId = 0;

  DrishtiAnalysisState get state => _state;
  DRInferenceResult? get result => _result;
  String? get errorMessage => _errorMessage;

  /// Present when the failure was a frame/quality problem; null for model
  /// failures. Drives the recapture hint copy.
  PreprocessingFailureReason? get failureReason => _failureReason;

  /// True while the worker is busy with this controller's request.
  bool get isBusy => _state == DrishtiAnalysisState.analyzing;

  /// Preloads the model. Errors are swallowed on purpose: the first
  /// [analyzeFile]/[analyzeEncodedBytes] call retries and surfaces them.
  Future<void> warmUp() async {
    try {
      await _service.warmUp();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('DrishtiAnalysisController warm-up failed: $error');
      }
    }
  }

  Future<DRInferenceResult?> analyzeFile(
    String path, {
    bool includePreview = true,
  }) {
    return _execute(
      () => _service.analyzeFile(path, includePreview: includePreview),
    );
  }

  Future<DRInferenceResult?> analyzeEncodedBytes(
    Uint8List bytes, {
    bool includePreview = true,
  }) {
    return _execute(
      () => _service.analyzeEncodedBytes(bytes, includePreview: includePreview),
    );
  }

  Future<DRInferenceResult?> _execute(
    Future<DRInferenceResult> Function() action,
  ) async {
    if (_disposed) return null;
    final runId = ++_runId;
    _state = DrishtiAnalysisState.analyzing;
    _result = null;
    _errorMessage = null;
    _failureReason = null;
    notifyListeners();

    try {
      final result = await action();
      if (runId != _runId || _disposed) return null;
      _result = result;
      _state = DrishtiAnalysisState.success;
      notifyListeners();
      return result;
    } on PreprocessingException catch (error) {
      _fail(runId, error.message, error.reason);
    } on InferenceException catch (error) {
      _fail(runId, error.message, null);
    } catch (error) {
      _fail(runId, 'On-device analysis failed: $error', null);
    }
    return null;
  }

  void _fail(int runId, String message, PreprocessingFailureReason? reason) {
    if (runId != _runId || _disposed) return;
    _result = null;
    _errorMessage = message;
    _failureReason = reason;
    _state = DrishtiAnalysisState.failure;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _runId++;
    unawaited(_service.dispose());
    super.dispose();
  }
}
