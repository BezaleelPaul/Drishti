import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/services/ml/dr_classifier.dart';
import 'package:netra_ai_mobile/services/ml/model_runner.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';

/// Fail-closed contracts for the interchangeable grader layer.
///
/// DrDetectRunner must NEVER return a simulated severity score: the previous
/// implementation derived one from a red/green channel ratio because no
/// on-device ONNX runtime exists. That stand-in is removed; the runner now
/// fails closed so the orchestrator routes to AI_UNAVAILABLE + human review.
void main() {
  group('DrDetectRunner fail-closed contract', () {
    test(
      'initialize always throws — no on-device ONNX runtime is wired',
      () async {
        final runner = DrDetectRunner();
        await expectLater(runner.initialize(), throwsStateError);
      },
    );

    test('predict always throws, even after a (failing) initialize', () async {
      final runner = DrDetectRunner();
      final image = img.Image(width: 8, height: 8);
      await expectLater(runner.predict(image), throwsStateError);
      await expectLater(runner.initialize(), throwsStateError);
    });

    test('reports honest model identity', () {
      final runner = DrDetectRunner();
      expect(runner.modelId, 'drdetect_ordinal');
      expect(runner.modelVersion, 'v1.0.0-regression-512px');
      // Asset path must reference the real file name shipped in models/.
      expect(
        runner.modelAssetPath,
        contains('efficientnet_b0_regression_512px'),
      );
      expect(runner.modelAssetPath, isNot(contains('drdetect_regression')));
    });

    test('dispose is safe to call', () {
      final runner = DrDetectRunner();
      expect(runner.dispose, returnsNormally);
    });
  });

  group('DrModelOutput honesty contract', () {
    test('top2Margin defaults to null alongside null probabilities', () {
      const out = DrModelOutput(
        grade: DrGrade.noDr,
        probabilities: null,
        referableScore: null,
        referable: null,
        uncertainty: null,
        modelId: 'test',
        modelVersion: '0',
      );
      expect(out.probabilities, isNull);
      expect(out.top2Margin, isNull);
    });
  });

  group('DrClassifierDart fail-closed contract (no interpreter loaded)', () {
    test('classify before initialize throws StateError', () {
      final clf = DrClassifierDart();
      expect(() => clf.classify(Uint8List(224 * 224 * 3)), throwsStateError);
      clf.dispose();
    });

    test(
      'initialize with a bogus asset path throws StateError, never degrades',
      () async {
        final clf = DrClassifierDart(
          assetPath: 'assets/models/does_not_exist.tflite',
        );
        await expectLater(clf.initialize(), throwsStateError);
        expect(clf.isReady, isFalse);
        clf.dispose();
      },
    );
  });
}
