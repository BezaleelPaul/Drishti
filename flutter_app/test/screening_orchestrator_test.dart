import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/services/ml/model_runner.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';
import 'package:netra_ai_mobile/services/ml/quality_gate.dart';
import 'package:netra_ai_mobile/services/ml/screening_orchestrator.dart';

/// Orchestrator integrity: the production screening path must never fabricate
/// probabilities, never grade without a real model output, and must keep the
/// quality gate ahead of the grader.
void main() {
  // 1x1 transparent PNG — decodes cleanly for the canonical-RGB path.
  final png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  QualityGateDart gateReturning(QualityGrade grade) => _FakeQualityGate(grade);

  DrModelOutput outputWith({
    List<double>? probabilities,
    double? top2Margin,
    DrGrade grade = DrGrade.noDr,
    double? uncertainty,
  }) => DrModelOutput(
    grade: grade,
    probabilities: probabilities,
    referableScore: 0.0,
    referable: grade.isReferable,
    uncertainty: uncertainty ?? 0.05,
    modelId: 'tflite-fp32',
    modelVersion: 'test',
    top2Margin: top2Margin,
    inferenceMs: 1.0,
  );

  group(
    'Grader output validation (fail-closed, no manufactured probabilities)',
    () {
      test(
        'null probabilities -> AI_UNAVAILABLE, mandatory review, no grade',
        () async {
          final orch = ScreeningOrchestrator(
            modelRunner: _FakeRunner(outputWith()),
            qualityGate: gateReturning(QualityGrade.GOOD),
          );
          final rec = await orch.processImage(png1x1);

          expect(rec.drPrediction, isNull);
          expect(rec.errorCode, PipelineErrorCode.aiUnavailable);
          expect(rec.humanReviewRequired, isTrue);
          expect(rec.humanReviewType, HumanReviewType.OPERATOR_LEVEL);
          expect(rec.qualityStatus, contains('no calibrated probabilities'));
        },
      );

      test('null top2Margin alone is also fail-closed', () async {
        final orch = ScreeningOrchestrator(
          modelRunner: _FakeRunner(
            outputWith(probabilities: const [0.9, 0.05, 0.03, 0.01, 0.01]),
          ),
          qualityGate: gateReturning(QualityGrade.GOOD),
        );
        final rec = await orch.processImage(png1x1);

        expect(rec.drPrediction, isNull);
        expect(rec.errorCode, PipelineErrorCode.aiUnavailable);
        expect(rec.humanReviewRequired, isTrue);
      });

      test('NaN probabilities are rejected, never graded', () async {
        final orch = ScreeningOrchestrator(
          modelRunner: _FakeRunner(
            outputWith(
              probabilities: const [double.nan, 0.2, 0.2, 0.2, 0.2],
              top2Margin: 0.1,
            ),
          ),
          qualityGate: gateReturning(QualityGrade.GOOD),
        );
        final rec = await orch.processImage(png1x1);

        expect(rec.drPrediction, isNull);
        expect(rec.errorCode, PipelineErrorCode.aiUnavailable);
      });

      test('wrong-length probability vector is rejected', () async {
        final orch = ScreeningOrchestrator(
          modelRunner: _FakeRunner(
            outputWith(probabilities: const [0.5, 0.5], top2Margin: 0.1),
          ),
          qualityGate: gateReturning(QualityGrade.GOOD),
        );
        final rec = await orch.processImage(png1x1);

        expect(rec.drPrediction, isNull);
        expect(rec.errorCode, PipelineErrorCode.aiUnavailable);
      });

      test(
        'a throwing grader maps to AI_UNAVAILABLE, never a substitute grade',
        () async {
          final orch = ScreeningOrchestrator(
            modelRunner: _ThrowingRunner(),
            qualityGate: gateReturning(QualityGrade.GOOD),
          );
          final rec = await orch.processImage(png1x1);

          expect(rec.drPrediction, isNull);
          expect(rec.errorCode, PipelineErrorCode.aiUnavailable);
          expect(rec.humanReviewRequired, isTrue);
        },
      );
    },
  );

  group('Real probability path preserves measured outputs', () {
    test(
      'passes the real top-2 margin through to the confidence evaluator',
      () async {
        // Ambiguous output: margin 0.10 < 0.15 threshold -> Rule 2 flags it.
        final orch = ScreeningOrchestrator(
          modelRunner: _FakeRunner(
            outputWith(
              probabilities: const [0.40, 0.30, 0.20, 0.06, 0.04],
              top2Margin: 0.10,
              grade: DrGrade.noDr,
              uncertainty: 0.60,
            ),
          ),
          qualityGate: gateReturning(QualityGrade.GOOD),
        );
        final rec = await orch.processImage(png1x1);

        expect(rec.drPrediction, isNotNull);
        expect(rec.drPrediction!.top2Margin, 0.10); // measured, not synthesized
        expect(rec.drPrediction!.confidence, 0.40); // == max(probs)
        expect(rec.confidence!.isAmbiguous, isTrue);
        expect(
          rec.confidence!.flags.any((f) => f.contains('Class ambiguity')),
          isTrue,
        );
      },
    );

    test('confident referable grade requires clinician review', () async {
      final orch = ScreeningOrchestrator(
        modelRunner: _FakeRunner(
          outputWith(
            probabilities: const [0.02, 0.03, 0.85, 0.07, 0.03],
            top2Margin: 0.78,
            grade: DrGrade.moderateNpdr,
            uncertainty: 0.15,
          ),
        ),
        qualityGate: gateReturning(QualityGrade.GOOD),
      );
      final rec = await orch.processImage(png1x1);

      expect(rec.drPrediction!.predictedGrade, DrGrade.moderateNpdr);
      expect(rec.humanReviewRequired, isTrue);
      expect(rec.humanReviewType, HumanReviewType.CLINICAL_LEVEL);
      expect(rec.modelBackend, 'tflite-fp32');
    });

    test('high-risk grade is always flagged for over-read', () async {
      final orch = ScreeningOrchestrator(
        modelRunner: _FakeRunner(
          outputWith(
            probabilities: const [0.01, 0.02, 0.04, 0.90, 0.03],
            top2Margin: 0.85,
            grade: DrGrade.severeNpdr,
            uncertainty: 0.10,
          ),
        ),
        qualityGate: gateReturning(QualityGrade.GOOD),
      );
      final rec = await orch.processImage(png1x1);

      expect(rec.confidence!.isHighRisk, isTrue);
      expect(rec.humanReviewRequired, isTrue);
    });
  });

  group('Quality gate ordering', () {
    test('BAD image never reaches the grader', () async {
      final runner = _FakeRunner(outputWith());
      final orch = ScreeningOrchestrator(
        modelRunner: runner,
        qualityGate: gateReturning(QualityGrade.BAD),
      );
      final rec = await orch.processImage(png1x1);

      expect(runner.predictCalls, 0);
      expect(rec.drPrediction, isNull);
      expect(rec.errorCode, PipelineErrorCode.imgUntgradable);
    });

    test(
      'BORDERLINE image never reaches the grader and demands review',
      () async {
        final runner = _FakeRunner(outputWith());
        final orch = ScreeningOrchestrator(
          modelRunner: runner,
          qualityGate: gateReturning(QualityGrade.BORDERLINE),
        );
        final rec = await orch.processImage(png1x1);

        expect(runner.predictCalls, 0);
        expect(rec.drPrediction, isNull);
        expect(rec.humanReviewRequired, isTrue);
        expect(rec.action, contains('does NOT proceed'));
      },
    );

    test('recapture cap on BAD escalates to operator review', () async {
      final orch = ScreeningOrchestrator(
        modelRunner: _FakeRunner(outputWith()),
        qualityGate: gateReturning(QualityGrade.BAD),
      );
      final rec = await orch.processImage(png1x1, recaptureAttemptCount: 2);

      expect(rec.humanReviewRequired, isTrue);
      expect(rec.humanReviewType, HumanReviewType.OPERATOR_LEVEL);
      expect(rec.drPrediction, isNull);
    });
  });

  group('Corrupt input', () {
    test('undecodable bytes fail closed before any model call', () async {
      final runner = _FakeRunner(outputWith());
      final orch = ScreeningOrchestrator(
        modelRunner: runner,
        qualityGate: gateReturning(QualityGrade.GOOD),
      );
      final rec = await orch.processImage(Uint8List.fromList([1, 2, 3]));

      expect(runner.predictCalls, 0);
      expect(rec.errorCode, PipelineErrorCode.imgInvalid);
      expect(rec.drPrediction, isNull);
    });
  });
}

class _FakeQualityGate extends QualityGateDart {
  _FakeQualityGate(this._grade);
  final QualityGrade _grade;

  @override
  QualityAssessmentResult assess(
    Uint8List rgbBytes,
    int width,
    int height, {
    bool strictMode = false,
  }) {
    if (_grade == QualityGrade.GOOD) {
      return const QualityAssessmentResult(
        grade: QualityGrade.GOOD,
        isReliable: true,
        reasons: [QualityReason.adequate],
        details: 'adequate',
      );
    }
    return QualityAssessmentResult(
      grade: _grade,
      isReliable: false,
      reasons: [QualityReason.severeBlur],
      details: _grade == QualityGrade.BAD ? 'blur' : 'borderline',
      errorCode: PipelineErrorCode.imgUntgradable,
    );
  }
}

class _FakeRunner implements DrModelRunner {
  _FakeRunner(this.output);
  final DrModelOutput output;
  int predictCalls = 0;

  @override
  String get modelId => output.modelId;

  @override
  String get modelVersion => output.modelVersion;

  @override
  Future<void> initialize() async {}

  @override
  Future<DrModelOutput> predict(img.Image image) async {
    predictCalls++;
    return output;
  }

  @override
  void dispose() {}
}

class _ThrowingRunner implements DrModelRunner {
  @override
  String get modelId => 'throwing';

  @override
  String get modelVersion => '0';

  @override
  Future<void> initialize() async {}

  @override
  Future<DrModelOutput> predict(img.Image image) async {
    throw StateError('simulated inference failure');
  }

  @override
  void dispose() {}
}
