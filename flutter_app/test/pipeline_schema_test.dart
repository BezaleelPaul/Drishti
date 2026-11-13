import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/ml/dr_classifier.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';

/// Class-mapping and output-validation parity with
/// src/pipeline/schema.py + src/classification/classifier.py.
void main() {
  group(
    'DrGrade class mapping (verified against src/classification/classifier.py)',
    () {
      test(
        'labels are byte-identical to the production CLASS_LABELS tuple',
        () {
          expect(DrGrade.noDr.label, 'No DR');
          expect(DrGrade.mildNpdr.label, 'Mild NPDR');
          expect(DrGrade.moderateNpdr.label, 'Moderate NPDR');
          expect(DrGrade.severeNpdr.label, 'Severe NPDR');
          expect(DrGrade.proliferativeDr.label, 'Proliferative DR');
        },
      );

      test('enum values map 0..4 in canonical order', () {
        expect(DrGrade.noDr.value, 0);
        expect(DrGrade.mildNpdr.value, 1);
        expect(DrGrade.moderateNpdr.value, 2);
        expect(DrGrade.severeNpdr.value, 3);
        expect(DrGrade.proliferativeDr.value, 4);
      });

      test(
        'fromValue round-trips every valid grade and rejects out-of-range',
        () {
          for (final g in DrGrade.values) {
            expect(DrGrade.fromValue(g.value), g);
          }
          expect(() => DrGrade.fromValue(-1), throwsArgumentError);
          expect(() => DrGrade.fromValue(5), throwsArgumentError);
        },
      );

      test('referable DR is grade >= 2', () {
        expect(DrGrade.noDr.isReferable, isFalse);
        expect(DrGrade.mildNpdr.isReferable, isFalse);
        expect(DrGrade.moderateNpdr.isReferable, isTrue);
        expect(DrGrade.severeNpdr.isReferable, isTrue);
        expect(DrGrade.proliferativeDr.isReferable, isTrue);
      });

      test('high-risk grades are 3 and 4 only', () {
        expect(DrGrade.noDr.isHighRisk, isFalse);
        expect(DrGrade.mildNpdr.isHighRisk, isFalse);
        expect(DrGrade.moderateNpdr.isHighRisk, isFalse);
        expect(DrGrade.severeNpdr.isHighRisk, isTrue);
        expect(DrGrade.proliferativeDr.isHighRisk, isTrue);
      });
    },
  );

  group('Deployed artifact identity', () {
    test(
      'backend id matches the screenings-table default and asset README',
      () {
        expect(DrClassifierDart.backendId, 'tflite-fp32');
      },
    );

    test('asset sha-256 is recorded for audit traceability', () {
      expect(DrClassifierDart.assetSha256, hasLength(64));
      expect(
        DrClassifierDart.assetSha256,
        startsWith('CEB819EA01D2FFC3F0C89CC92A66540B'),
      );
    });

    test('default asset path is the parity-gated fp32 artifact', () {
      expect(
        DrClassifierDart.defaultModelAsset,
        'assets/models/dr_efficientnet_b0_fp32.tflite',
      );
    });
  });

  group('DrClassificationResult.validate (Rule 0 fail-closed)', () {
    DrClassificationResult result({
      List<double> probs = const [0.9, 0.05, 0.03, 0.01, 0.01],
      double confidence = 0.9,
      double margin = 0.85,
    }) => DrClassificationResult(
      predictedGrade: DrGrade.noDr,
      probabilities: probs,
      confidence: confidence,
      top2Margin: margin,
      isReferable: false,
    );

    test('accepts a well-formed vector', () {
      expect(result().validate(), isNull);
    });

    test('rejects NaN probabilities', () {
      expect(
        result(probs: [double.nan, 0.1, 0.1, 0.1, 0.1]).validate(),
        isNotNull,
      );
    });

    test('rejects infinite probabilities', () {
      expect(
        result(probs: [double.infinity, 0.0, 0.0, 0.0, 0.0]).validate(),
        isNotNull,
      );
    });

    test('rejects out-of-range probabilities', () {
      expect(result(probs: [1.5, 0.0, 0.0, 0.0, 0.0]).validate(), isNotNull);
      expect(result(probs: [-0.1, 0.5, 0.3, 0.2, 0.1]).validate(), isNotNull);
    });

    test('rejects wrong vector length', () {
      expect(result(probs: const [0.5, 0.5]).validate(), isNotNull);
    });

    test('rejects confidence that is not max(probs)', () {
      expect(
        result(
          probs: const [0.4, 0.3, 0.2, 0.05, 0.05],
          confidence: 0.9,
        ).validate(),
        isNotNull,
      );
    });

    test('rejects NaN confidence or margin', () {
      expect(result(confidence: double.nan).validate(), isNotNull);
      expect(result(margin: double.nan).validate(), isNotNull);
    });
  });

  group('ScreeningRecordDart.referableFlag operating point (X-0)', () {
    ScreeningRecordDart record(List<double> probs, DrGrade grade) =>
        ScreeningRecordDart(
          imagePath: 'capture',
          qualityGrade: QualityGrade.GOOD,
          qualityStatus: 'Certified Reliable',
          rejectionReasons: const [],
          recaptureAttemptCount: 0,
          reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
          drPrediction: DrClassificationResult(
            predictedGrade: grade,
            probabilities: probs,
            confidence: probs[grade.value],
            top2Margin: 0.1,
            isReferable: grade.isReferable,
          ),
        );

    test('referable when top-1 grade >= 2', () {
      expect(
        record(const [
          0.05,
          0.05,
          0.6,
          0.2,
          0.1,
        ], DrGrade.moderateNpdr).referableFlag,
        isTrue,
      );
    });

    test(
      'referable when mass(p2+p3+p4) >= 0.09 even with non-referable top-1',
      () {
        expect(
          record(const [
            0.4,
            0.5,
            0.05,
            0.03,
            0.02,
          ], DrGrade.mildNpdr).referableFlag,
          isTrue, // 0.05+0.03+0.02 = 0.10 >= 0.09
        );
      },
    );

    test('not referable for confident No DR with negligible tail mass', () {
      expect(
        record(const [
          0.95,
          0.03,
          0.01,
          0.005,
          0.005,
        ], DrGrade.noDr).referableFlag,
        isFalse,
      );
    });

    test('null prediction is never referable', () {
      const r = ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: QualityGrade.BAD,
        qualityStatus: 'Unreliable',
        rejectionReasons: [],
        recaptureAttemptCount: 0,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
      );
      expect(r.referableFlag, isFalse);
    });
  });
}
