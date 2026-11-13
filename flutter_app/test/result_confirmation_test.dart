import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/models/result_status.dart';
import 'package:netra_ai_mobile/models/screening_models.dart';

/// ScreeningAnalysisModel status/confirmation provenance fields and the
/// pure merge rule (requirements 5.3, 6.3, 6.4, 6.6; design "Models Layer
/// → result_status module" and "Logical Data Model").
void main() {
  const requiredFields = <String, dynamic>{
    'screening_id': 'SCR-1',
    'patient_id': 'PAT-1',
    'eye_side': 'Right',
    'camera_profile': 'Generic Fundus Camera',
    'quality_grade': 'GOOD',
    'quality_score': 0.9,
    'quality_passed': true,
    'rejection_reasons': <String>[],
    'is_referable': false,
    'requires_human_review': false,
    'original_image_url': '',
    'action_recommendation': '',
    'plain_language_advice': '',
    'sms_referral_slip': '',
  };

  ScreeningAnalysisModel modelFrom(Map<String, dynamic> payload) {
    return ScreeningAnalysisModel.fromJson(payload);
  }

  ScreeningAnalysisModel baseModel({int? drGrade}) {
    return ScreeningAnalysisModel(
      screeningId: 'SCR-1',
      patientId: 'PAT-1',
      eyeSide: 'Right',
      cameraProfile: 'Generic Fundus Camera',
      qualityGrade: 'GOOD',
      qualityScore: 0.9,
      qualityPassed: true,
      rejectionReasons: const [],
      isReferable: false,
      requiresHumanReview: false,
      originalImageUrl: '',
      actionRecommendation: '',
      plainLanguageAdvice: '',
      smsReferralSlip: '',
      drGrade: drGrade,
    );
  }

  group('ScreeningAnalysisModel status/confirmation fields', () {
    test('a payload without the status keys leaves both fields null (6.7)', () {
      final model = modelFrom(Map<String, dynamic>.of(requiredFields));
      expect(model.resultStatus, isNull);
      expect(model.confirmation, isNull);
    });

    test('fromJson reads optional result_status and confirmation keys', () {
      final payload = Map<String, dynamic>.of(requiredFields)
        ..['result_status'] = 'serviceConfirmed'
        ..['confirmation'] = <String, dynamic>{
          'agreed': true,
          'server_backend': 'tflite-fp32',
          'server_grade': 2,
          'server_screening_id': 'SRV-9',
        };
      final model = modelFrom(payload);
      expect(model.resultStatus, ScreeningResultStatus.serviceConfirmed);
      expect(
        model.confirmation,
        ServiceConfirmation(
          agreed: true,
          serverBackend: 'tflite-fp32',
          serverGrade: 2,
          serverScreeningId: 'SRV-9',
        ),
      );
    });

    test('fromJson tolerates a confirmation dict missing optional keys', () {
      final payload = Map<String, dynamic>.of(requiredFields)
        ..['result_status'] = 'serviceDisagreed'
        ..['confirmation'] = <String, dynamic>{'agreed': false};
      final model = modelFrom(payload);
      expect(model.resultStatus, ScreeningResultStatus.serviceDisagreed);
      expect(model.confirmation, ServiceConfirmation(agreed: false));
    });

    test(
      'fromJson drops a confirmation dict that does not carry the agreement flag',
      () {
        final payload = Map<String, dynamic>.of(requiredFields)
          ..['result_status'] = 'serviceConfirmed'
          ..['confirmation'] = <String, dynamic>{'server_grade': 2};
        final model = modelFrom(payload);
        expect(
          model.confirmation,
          isNull,
          reason: 'a confirmation without the agreement flag is meaningless',
        );
      },
    );

    test('fromJson maps an unrecognised status name to null (fail-safe)', () {
      final payload = Map<String, dynamic>.of(requiredFields)
        ..['result_status'] = 'not_a_status';
      final model = modelFrom(payload);
      expect(model.resultStatus, isNull);
    });

    test(
      'constructor defaults are null so existing constructions are unchanged',
      () {
        final model = baseModel();
        expect(model.resultStatus, isNull);
        expect(model.confirmation, isNull);
      },
    );
  });

  group('withConfirmation (copy-on-change merge)', () {
    test(
      'returns a new instance that carries the confirmation and merged status',
      () {
        final original = baseModel(drGrade: 2);
        final merged = original.withConfirmation(
          ServiceConfirmation(agreed: true, serverGrade: 2),
        );
        expect(merged.resultStatus, ScreeningResultStatus.serviceConfirmed);
        expect(merged.confirmation?.agreed, isTrue);
        expect(merged.confirmation?.serverGrade, 2);
      },
    );

    test('the original instance is never mutated', () {
      final original = baseModel(drGrade: 2);
      final merged = original.withConfirmation(
        ServiceConfirmation(agreed: false, serverGrade: 3),
      );
      expect(original.resultStatus, isNull);
      expect(original.confirmation, isNull);
      expect(merged.resultStatus, ScreeningResultStatus.serviceDisagreed);
      expect(merged.confirmation?.agreed, isFalse);
    });

    test('all other fields are preserved in the copy', () {
      final original = baseModel(drGrade: 1);
      final merged = original.withConfirmation(
        ServiceConfirmation(agreed: true, serverGrade: 1),
      );
      expect(merged.screeningId, original.screeningId);
      expect(merged.patientId, original.patientId);
      expect(merged.eyeSide, original.eyeSide);
      expect(merged.cameraProfile, original.cameraProfile);
      expect(merged.qualityGrade, original.qualityGrade);
      expect(merged.qualityScore, original.qualityScore);
      expect(merged.qualityPassed, original.qualityPassed);
      expect(merged.rejectionReasons, original.rejectionReasons);
      expect(merged.drGrade, original.drGrade);
      expect(merged.drLabel, original.drLabel);
      expect(merged.predictionScore, original.predictionScore);
      expect(merged.isReferable, original.isReferable);
      expect(merged.requiresHumanReview, original.requiresHumanReview);
      expect(merged.humanReviewType, original.humanReviewType);
      expect(merged.humanReviewReason, original.humanReviewReason);
      expect(merged.originalImageUrl, original.originalImageUrl);
      expect(merged.gradcamOverlayUrl, original.gradcamOverlayUrl);
      expect(merged.gradcamTargetLayer, original.gradcamTargetLayer);
      expect(merged.modelBackend, original.modelBackend);
      expect(merged.actionRecommendation, original.actionRecommendation);
      expect(merged.plainLanguageAdvice, original.plainLanguageAdvice);
      expect(merged.smsReferralSlip, original.smsReferralSlip);
      expect(merged.biomarkers, original.biomarkers);
      expect(merged.isOffline, original.isOffline);
      expect(merged.isFromFallback, original.isFromFallback);
      expect(merged.errorCode, original.errorCode);
      expect(merged.probabilities, original.probabilities);
    });
  });

  group('buildConfirmation (pure merge rule)', () {
    test(
      'null when the server result carries an error code — nothing to agree with (6.4)',
      () {
        final serverError = ScreeningAnalysisModel(
          screeningId: 'SCR-3',
          patientId: 'PAT-1',
          eyeSide: 'Right',
          cameraProfile: 'Generic Fundus Camera',
          qualityGrade: 'PENDING_SYNC',
          qualityScore: 0.0,
          qualityPassed: false,
          rejectionReasons: const [],
          isReferable: null,
          requiresHumanReview: true,
          originalImageUrl: '',
          actionRecommendation: '',
          plainLanguageAdvice: '',
          smsReferralSlip: '',
          errorCode: 'AI_UNAVAILABLE',
        );
        expect(
          buildConfirmation(preliminaryGrade: 2, serverResult: serverError),
          isNull,
        );
      },
    );

    test(
      'null when the server result has no DR grade (offline fallback, PENDING_SYNC)',
      () {
        final offlineNoGrade = ScreeningAnalysisModel(
          screeningId: 'SCR-2',
          patientId: 'PAT-1',
          eyeSide: 'Right',
          cameraProfile: 'Generic Fundus Camera',
          qualityGrade: 'PENDING_SYNC',
          qualityScore: 0.0,
          qualityPassed: false,
          rejectionReasons: const [],
          isReferable: null,
          requiresHumanReview: true,
          originalImageUrl: '',
          actionRecommendation: '',
          plainLanguageAdvice: '',
          smsReferralSlip: '',
          isOffline: true,
        );
        expect(
          buildConfirmation(preliminaryGrade: 2, serverResult: offlineNoGrade),
          isNull,
        );
      },
    );

    test(
      'null when the server result with a grade is flagged as the offline fallback',
      () {
        final offlineFlagged = ScreeningAnalysisModel(
          screeningId: 'SCR-4',
          patientId: 'PAT-1',
          eyeSide: 'Right',
          cameraProfile: 'Generic Fundus Camera',
          qualityGrade: 'GOOD',
          qualityScore: 0.9,
          qualityPassed: true,
          rejectionReasons: const [],
          drGrade: 2,
          isReferable: false,
          requiresHumanReview: false,
          originalImageUrl: '',
          actionRecommendation: '',
          plainLanguageAdvice: '',
          smsReferralSlip: '',
          isOffline: true,
        );
        expect(
          buildConfirmation(preliminaryGrade: 2, serverResult: offlineFlagged),
          isNull,
        );
      },
    );

    test(
      'agreement when the server DR grade equals the preliminary grade (D4)',
      () {
        final server = baseModel(drGrade: 3);
        final confirmation = buildConfirmation(
          preliminaryGrade: 3,
          serverResult: server,
        );
        expect(confirmation, isNotNull);
        expect(confirmation!.agreed, isTrue);
        expect(confirmation.serverGrade, 3);
      },
    );

    test(
      'disagreement when the server DR grade differs — both preserved (6.6)',
      () {
        final server = baseModel(drGrade: 4);
        final confirmation = buildConfirmation(
          preliminaryGrade: 2,
          serverResult: server,
        );
        expect(confirmation, isNotNull);
        expect(confirmation!.agreed, isFalse);
        expect(confirmation.serverGrade, 4);
      },
    );

    test(
      'confirmation carries server backend, grade and screening id (5.3)',
      () {
        final server = ScreeningAnalysisModel(
          screeningId: 'SRV-42',
          patientId: 'PAT-1',
          eyeSide: 'Right',
          cameraProfile: 'Generic Fundus Camera',
          qualityGrade: 'GOOD',
          qualityScore: 0.9,
          qualityPassed: true,
          rejectionReasons: const [],
          drGrade: 2,
          modelBackend: 'tflite-fp32',
          isReferable: false,
          requiresHumanReview: false,
          originalImageUrl: '',
          actionRecommendation: '',
          plainLanguageAdvice: '',
          smsReferralSlip: '',
        );
        final confirmation = buildConfirmation(
          preliminaryGrade: 2,
          serverResult: server,
        );
        expect(confirmation, isNotNull);
        expect(confirmation!.agreed, isTrue);
        expect(confirmation.serverBackend, 'tflite-fp32');
        expect(confirmation.serverGrade, 2);
        expect(confirmation.serverScreeningId, 'SRV-42');
      },
    );

    test(
      'an unknown server backend is carried as null, never as a guessed id (5.4)',
      () {
        final server = baseModel(drGrade: 2);
        final confirmation = buildConfirmation(
          preliminaryGrade: 2,
          serverResult: server,
        );
        expect(confirmation, isNotNull);
        expect(confirmation!.serverBackend, isNull);
      },
    );
  });
}
