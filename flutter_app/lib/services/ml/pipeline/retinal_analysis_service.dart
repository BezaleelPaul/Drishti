import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'dr_inference_result.dart';
import 'pipeline_exceptions.dart';
import 'retinal_analysis_isolate_bridge.dart';

/// Thin application-facing facade over [RetinalAnalysisIsolateBridge].
///
/// Keeps the bridge lifecycle in one place so screens never own isolates or
/// native interpreter state. One instance per app is enough; the underlying
/// worker is reused across analyses.
///
/// Threading: all methods return after the work completed in the analysis
/// isolate. Call them from `initState`/button handlers and await the future.
class RetinalAnalysisService {
  RetinalAnalysisService({RetinalAnalysisIsolateBridge? bridge})
    : _bridge = bridge ?? RetinalAnalysisIsolateBridge();

  final RetinalAnalysisIsolateBridge _bridge;

  /// Loads the model before the first capture so the first analysis is not
  /// penalised by the ~0.5-1 s cold start. Optional but recommended.
  Future<void> warmUp() => _bridge.initialize();

  /// Full pipeline for encoded JPEG/PNG bytes (decode happens in the worker).
  Future<DRInferenceResult> analyzeEncodedBytes(
    Uint8List encodedImage, {
    bool includePreview = true,
  }) {
    return _bridge.analyzeEncodedBytes(
      encodedImage,
      includePreview: includePreview,
    );
  }

  /// Convenience for a picker/camera file path.
  ///
  /// Reads the file, then delegates decode + preprocessing + inference to the
  /// worker. A missing or unreadable file is a [PreprocessingException] with
  /// `emptyImage`/`decodeFailed` so the UI can show a single retry affordance.
  Future<DRInferenceResult> analyzeFile(
    String path, {
    bool includePreview = true,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const PreprocessingException(
        PreprocessingFailureReason.emptyImage,
        'Selected image file does not exist.',
      );
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (error) {
      throw PreprocessingException(
        PreprocessingFailureReason.decodeFailed,
        'Unable to read the selected image file.',
        cause: error,
      );
    }
    if (bytes.isEmpty) {
      throw const PreprocessingException(
        PreprocessingFailureReason.emptyImage,
        'Selected image file is empty.',
      );
    }
    return analyzeEncodedBytes(bytes, includePreview: includePreview);
  }

  /// Runs the pipeline on a frame the caller already decoded.
  Future<DRInferenceResult> analyzeDecoded(
    img.Image image, {
    bool validate = false,
    bool includePreview = false,
  }) {
    return _bridge.analyzeDecoded(
      image,
      validate: validate,
      includePreview: includePreview,
    );
  }

  /// Backend that actually took the model, or null before initialisation.
  String? get backend => _bridge.activeBackend;

  Future<void> dispose() => _bridge.dispose();
}
