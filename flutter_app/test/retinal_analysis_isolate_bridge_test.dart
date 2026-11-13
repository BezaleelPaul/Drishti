import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/services/ml/pipeline/drishti_inference_engine.dart';
import 'package:netra_ai_mobile/services/ml/pipeline/pipeline_exceptions.dart';
import 'package:netra_ai_mobile/services/ml/pipeline/retinal_analysis_isolate_bridge.dart';

/// The native LiteRT runtime is not guaranteed inside `flutter test`, so these
/// tests exercise the bridge's failure and lifecycle contract with deliberately
/// corrupt model bytes. They must fail closed with a typed exception, never
/// hang, and never crash the test process.
void main() {
  group('isolation lifecycle', () {
    test('starts not ready and reports no backend', () {
      final bridge = RetinalAnalysisIsolateBridge(modelBytes: Uint8List(0));
      expect(bridge.isReady, isFalse);
      expect(bridge.activeBackend, isNull);
    });

    test('empty encoded image fails before spawning a worker', () async {
      final bridge = RetinalAnalysisIsolateBridge(
        modelBytes: Uint8List.fromList([1, 2, 3]),
        backend: DrComputeBackend.cpu,
        initTimeout: const Duration(seconds: 10),
      );
      await expectLater(
        bridge.analyzeEncodedBytes(Uint8List(0)),
        throwsA(
          isA<PreprocessingException>().having(
            (e) => e.reason,
            'reason',
            PreprocessingFailureReason.emptyImage,
          ),
        ),
      );
      expect(bridge.isReady, isFalse);
      await bridge.dispose();
    });

    test(
      'corrupt model bytes surface InferenceException, not a grade',
      () async {
        final bridge = RetinalAnalysisIsolateBridge(
          modelBytes: Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]),
          backend: DrComputeBackend.cpu,
          initTimeout: const Duration(seconds: 15),
        );
        await expectLater(
          bridge.initialize(),
          throwsA(isA<InferenceException>()),
        );
        expect(bridge.isReady, isFalse);
        await bridge.dispose();
      },
    );

    test('empty model bytes fail closed as model-unavailable', () async {
      final bridge = RetinalAnalysisIsolateBridge(
        modelBytes: Uint8List(0),
        backend: DrComputeBackend.cpu,
        initTimeout: const Duration(seconds: 10),
      );
      await expectLater(
        bridge.initialize(),
        throwsA(
          isA<InferenceException>().having(
            (e) => e.modelUnavailable,
            'modelUnavailable',
            isTrue,
          ),
        ),
      );
      await bridge.dispose();
    });

    test('dispose is idempotent and safe before initialization', () async {
      final bridge = RetinalAnalysisIsolateBridge(modelBytes: Uint8List(0));
      await bridge.dispose();
      await bridge.dispose();
      expect(bridge.isReady, isFalse);
    });

    test('analyze after dispose throws instead of running', () async {
      final bridge = RetinalAnalysisIsolateBridge(modelBytes: Uint8List(0));
      await bridge.dispose();
      await expectLater(
        bridge.analyzeDecoded(img.Image(width: 8, height: 8)),
        throwsA(isA<InferenceException>()),
      );
      await expectLater(
        bridge.analyzeEncodedBytes(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<InferenceException>()),
      );
    });

    test(
      'repeated failed initialization does not leak a live worker',
      () async {
        final bridge = RetinalAnalysisIsolateBridge(
          modelBytes: Uint8List.fromList([9, 9, 9, 9]),
          backend: DrComputeBackend.cpu,
          initTimeout: const Duration(seconds: 10),
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            bridge.initialize(),
            throwsA(isA<InferenceException>()),
          );
          expect(bridge.isReady, isFalse);
        }
        await bridge.dispose();
      },
    );
  });
}
