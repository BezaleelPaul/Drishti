import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/ml/pipeline/dr_inference_result.dart';
import 'package:netra_ai_mobile/services/ml/pipeline/pipeline_exceptions.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';

DRInferenceResult decodeOrdinal(double score) {
  return DrishtiOutputDecoder.decode(
    ordinal: true,
    rawOutput: [score],
    preprocessingDurationMs: 120,
    inferenceDurationMs: 80,
    modelId: 'test-model',
    modelVersion: 'v-test',
    backend: 'cpu',
  );
}

void main() {
  group('ordinal decoding', () {
    test('strict cut-points match classifier.py', () {
      expect(decodeOrdinal(0.0).grade, DrGrade.noDr);
      expect(decodeOrdinal(0.5).grade, DrGrade.noDr);
      expect(decodeOrdinal(0.5001).grade, DrGrade.mildNpdr);
      expect(decodeOrdinal(1.5).grade, DrGrade.mildNpdr);
      expect(decodeOrdinal(1.5001).grade, DrGrade.moderateNpdr);
      expect(decodeOrdinal(2.5).grade, DrGrade.moderateNpdr);
      expect(decodeOrdinal(2.5001).grade, DrGrade.severeNpdr);
      expect(decodeOrdinal(3.5).grade, DrGrade.severeNpdr);
      expect(decodeOrdinal(3.5001).grade, DrGrade.proliferativeDr);
    });

    test('scores outside [0,4] clamp to edge classes', () {
      expect(decodeOrdinal(-10).grade, DrGrade.noDr);
      expect(decodeOrdinal(42).grade, DrGrade.proliferativeDr);
    });

    test('referable is score >= 1.5 with the Python boundary exception', () {
      expect(decodeOrdinal(1.4999).referable, isFalse);
      final boundary = decodeOrdinal(1.5);
      expect(boundary.referable, isTrue);
      expect(boundary.grade, DrGrade.mildNpdr);
      for (final score in [0.0, 0.5, 1.5001, 2.2, 4.0]) {
        final result = decodeOrdinal(score);
        expect(result.referable, result.grade.isReferable);
      }
    });

    test('compatibility distribution sums to one and is honest output', () {
      final result = decodeOrdinal(1.621);
      final sum = result.confidenceScores.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-9));
      expect(result.confidenceScores.length, 5);
      expect(
        result.confidence,
        closeTo(result.confidenceScores.reduce((a, b) => a > b ? a : b), 1e-12),
      );
      expect(result.top2Margin, greaterThanOrEqualTo(0));
      expect(result.top2Margin, lessThan(1));
      expect(result.referableScore, 1.621);
      expect(result.rawOutput, [1.621]);
    });

    test('timings are preserved and total is additive', () {
      final result = decodeOrdinal(0.1);
      expect(result.preprocessingDurationMs, 120);
      expect(result.inferenceDurationMs, 80);
      expect(result.totalDurationMs, 200);
    });

    test('non-finite score fails closed', () {
      expect(
        () => decodeOrdinal(double.nan),
        throwsA(isA<InferenceException>()),
      );
      expect(
        () => decodeOrdinal(double.infinity),
        throwsA(isA<InferenceException>()),
      );
    });

    test('wrong ordinal output length fails closed', () {
      expect(
        () => DrishtiOutputDecoder.decode(
          ordinal: true,
          rawOutput: [1, 2],
          preprocessingDurationMs: 0,
          inferenceDurationMs: 0,
          modelId: 'm',
          modelVersion: 'v',
          backend: 'cpu',
        ),
        throwsA(isA<InferenceException>()),
      );
    });

    test('raw output is exposed read-only', () {
      final result = decodeOrdinal(2.0);
      expect(() => result.rawOutput.add(9), throwsUnsupportedError);
    });

    test('custom cut-points are validated', () {
      expect(
        () => DrishtiOutputDecoder.decodeOrdinalScore(2.0, thresholds: [1.0]),
        throwsArgumentError,
      );
    });
  });

  group('five-class decoding', () {
    DRInferenceResult decodeFive(List<double> probs) {
      return DrishtiOutputDecoder.decode(
        ordinal: false,
        rawOutput: probs,
        preprocessingDurationMs: 10,
        inferenceDurationMs: 20,
        modelId: 'legacy',
        modelVersion: 'v1',
        backend: 'cpu',
      );
    }

    test('normalises logits and argmaxes the grade', () {
      final result = decodeFive([0.1, 0.1, 0.6, 0.1, 0.1]);
      final sum = result.confidenceScores.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-12));
      expect(result.grade, DrGrade.moderateNpdr);
      expect(result.confidence, closeTo(0.6, 1e-12));
      expect(result.referable, isTrue);
      expect(result.referableScore, closeTo(0.8, 1e-12));
    });

    test('un-normalised scores still produce a valid distribution', () {
      final result = decodeFive([1, 1, 1, 1, 1]);
      for (final p in result.confidenceScores) {
        expect(p, closeTo(0.2, 1e-12));
      }
      expect(result.top2Margin, closeTo(0.0, 1e-12));
    });

    test('non-referable five-class output is not referable', () {
      final result = decodeFive([0.7, 0.2, 0.05, 0.04, 0.01]);
      expect(result.grade, DrGrade.noDr);
      expect(result.referable, isFalse);
    });

    test('negative, zero and non-finite vectors fail closed', () {
      expect(
        () => decodeFive([1, -1, 0, 0, 0]),
        throwsA(isA<InferenceException>()),
      );
      expect(
        () => decodeFive([0, 0, 0, 0, 0]),
        throwsA(isA<InferenceException>()),
      );
      expect(
        () => decodeFive([1, 0, 0, 0, double.nan]),
        throwsA(isA<InferenceException>()),
      );
    });

    test('wrong length fails closed', () {
      expect(
        () => decodeFive([0.2, 0.2, 0.2, 0.2]),
        throwsA(isA<InferenceException>()),
      );
    });
  });

  group('preview plumbing', () {
    test('processed preview metadata is copied into the result', () {
      final png = Uint8List.fromList([1, 2, 3, 4]);
      final result = DrishtiOutputDecoder.decode(
        ordinal: true,
        rawOutput: [0.2],
        preprocessingDurationMs: 1,
        inferenceDurationMs: 2,
        modelId: 'm',
        modelVersion: 'v',
        backend: 'xnnpack',
        processedImageBytes: png,
        processedImageWidth: 512,
        processedImageHeight: 512,
      );
      expect(result.processedImageBytes, png);
      expect(result.processedImageWidth, 512);
      expect(result.processedImageHeight, 512);
      expect(result.backend, 'xnnpack');
    });
  });

  group('compatibility kernel', () {
    test('is peaked at the integer nearest the score', () {
      final probs = DrishtiOutputDecoder.compatibilityDistribution(2.1);
      final argmax = probs.indexOf(probs.reduce((a, b) => a > b ? a : b));
      expect(argmax, 2);
    });

    test('is symmetric around an integer score', () {
      final probs = DrishtiOutputDecoder.compatibilityDistribution(2.0);
      expect(probs[1], closeTo(probs[3], 1e-12));
      expect(probs[0], closeTo(probs[4], 1e-12));
    });

    test('rejects non-positive sigma', () {
      expect(
        () => DrishtiOutputDecoder.compatibilityDistribution(1.0, sigma: 0),
        throwsArgumentError,
      );
      expect(
        () => DrishtiOutputDecoder.compatibilityDistribution(
          1.0,
          sigma: double.nan,
        ),
        throwsArgumentError,
      );
    });
  });
}
