import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/services/ml/model_runner.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';
import 'package:netra_ai_mobile/services/ml/quality_gate.dart';
import 'package:netra_ai_mobile/services/ml/screening_orchestrator.dart';

/// Task 1.2: the stored screening record's backend field is nullable with no
/// default claim — a record written when no model ran can no longer assert
/// that one did (R5.4 backend truth, R2.5 failure never reported as a run).
void main() {
  // 1x1 transparent PNG — decodes cleanly for the canonical-RGB path.
  final png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  group('ScreeningRecordDart backend truthfulness (no default claim)', () {
    test('a record constructed with no backend carries null, not a claim', () {
      // Quality-gate-only shape: no model ever ran for this record.
      const rec = ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: QualityGrade.BAD,
        qualityStatus: 'Unreliable',
        rejectionReasons: ['Severe blur / loss of retinal focus'],
        recaptureAttemptCount: 0,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
        errorCode: PipelineErrorCode.imgUntgradable,
      );
      expect(rec.modelBackend, isNull);
    });

    test('an explicitly supplied backend is preserved verbatim', () {
      // The graded path (orchestrator :346) passes the runner's modelId.
      const rec = ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: QualityGrade.GOOD,
        qualityStatus: 'Certified Reliable',
        rejectionReasons: [],
        recaptureAttemptCount: 0,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
        modelBackend: 'tflite-fp32',
      );
      expect(rec.modelBackend, 'tflite-fp32');
    });
  });

  group('Orchestrator records tell the truth about whether a model ran', () {
    test('a quality-gate-only record carries NO backend instead of claiming '
        'the device model', () async {
      final orch = ScreeningOrchestrator(
        modelRunner: _CountingRunner(),
        qualityGate: _GateReturning(QualityGrade.BAD),
      );
      final rec = await orch.processImage(png1x1);

      expect(rec.errorCode, PipelineErrorCode.imgUntgradable);
      expect(rec.drPrediction, isNull);
      // No model executed — the record must not name one.
      expect(rec.modelBackend, isNull);
    });

    test('an undecodable capture record carries NO backend', () async {
      final orch = ScreeningOrchestrator(
        modelRunner: _CountingRunner(),
        qualityGate: _GateReturning(QualityGrade.GOOD),
      );
      final rec = await orch.processImage(Uint8List.fromList([1, 2, 3]));

      expect(rec.errorCode, PipelineErrorCode.imgInvalid);
      expect(rec.modelBackend, isNull);
    });

    test(
      'a grader exception record (predict threw) carries NO backend',
      () async {
        final orch = ScreeningOrchestrator(
          modelRunner: _ThrowingRunner(),
          qualityGate: _GateReturning(QualityGrade.GOOD),
        );
        final rec = await orch.processImage(png1x1);

        expect(rec.errorCode, PipelineErrorCode.aiUnavailable);
        expect(rec.drPrediction, isNull);
        expect(rec.modelBackend, isNull);
      },
    );

    test('a real graded record still records the runner identity', () async {
      final orch = ScreeningOrchestrator(
        modelRunner: _CountingRunner(),
        qualityGate: _GateReturning(QualityGrade.GOOD),
      );
      final rec = await orch.processImage(png1x1);

      // The model ran; the record names the backend that produced the grade.
      expect(rec.drPrediction, isNotNull);
      expect(rec.modelBackend, 'tflite-fp32');
    });
  });
}

/// Gate stub that always returns [grade], matching the repo's hand-rolled
/// fake idiom (no mock library).
class _GateReturning extends QualityGateDart {
  _GateReturning(this._grade);
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
    return const QualityAssessmentResult(
      grade: QualityGrade.BAD,
      isReliable: false,
      reasons: [QualityReason.severeBlur],
      details: 'blur',
      errorCode: PipelineErrorCode.imgUntgradable,
    );
  }
}

/// Runner that returns a real measured output (never called on the
/// quality-rejection paths — asserted via the record having no prediction).
class _CountingRunner implements DrModelRunner {
  int predictCalls = 0;

  @override
  String get modelId => 'tflite-fp32';

  @override
  String get modelVersion => 'test';

  @override
  Future<void> initialize() async {}

  @override
  Future<DrModelOutput> predict(img.Image image) async {
    predictCalls++;
    return DrModelOutput(
      grade: DrGrade.noDr,
      probabilities: const [0.90, 0.05, 0.03, 0.01, 0.01],
      referableScore: 0.0,
      referable: false,
      uncertainty: 0.10,
      modelId: modelId,
      modelVersion: modelVersion,
      top2Margin: 0.85,
      inferenceMs: 1.0,
    );
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
