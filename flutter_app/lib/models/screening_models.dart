import 'dart:typed_data';

import 'result_status.dart';
import 'retinal_markers.dart';

class PatientModel {
  final String patientId;
  final String name;
  final int age;
  final String gender;
  final String phone;
  final String abhaId;
  final String village;
  final String knownDiabetes;
  final double? diabetesDurationYears;
  final double? hba1c;
  final double? fastingGlucose;
  final double? bmi;
  final bool familyHistory;

  /// Measured at check-in (SYS/DIA mmHg, e.g. '145/90'); null when not
  /// measured — the value is never fabricated downstream.
  final String? bloodPressure;

  PatientModel({
    required this.patientId,
    required this.name,
    required this.age,
    required this.gender,
    required this.phone,
    required this.abhaId,
    required this.village,
    required this.knownDiabetes,
    this.diabetesDurationYears,
    this.hba1c,
    this.fastingGlucose,
    this.bmi,
    this.familyHistory = false,
    this.bloodPressure,
  });

  factory PatientModel.fromJson(Map<String, dynamic> json) {
    return PatientModel(
      patientId: json['patient_id'] ?? 'Unknown',
      name: json['name'] ?? '',
      age: (json['age'] as num?)?.toInt() ?? 0,
      gender: json['gender'] ?? 'Unknown',
      phone: json['phone'] ?? '',
      abhaId: json['abha_id'] ?? '',
      village: json['village'] ?? '',
      knownDiabetes: json['known_diabetes'] ?? 'Unknown',
      diabetesDurationYears: (json['diabetes_duration_years'] as num?)
          ?.toDouble(),
      hba1c: (json['hba1c'] as num?)?.toDouble(),
      fastingGlucose: (json['fasting_glucose'] as num?)?.toDouble(),
      bmi: (json['bmi'] as num?)?.toDouble(),
      familyHistory: json['family_history'] ?? false,
      bloodPressure: json['blood_pressure']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'patient_id': patientId,
      'name': name,
      'age': age,
      'gender': gender,
      'phone': phone,
      'abha_id': abhaId,
      'village': village,
      'known_diabetes': knownDiabetes,
      'diabetes_duration_years': diabetesDurationYears,
      'hba1c': hba1c,
      'fasting_glucose': fastingGlucose,
      'bmi': bmi,
      'family_history': familyHistory,
      'blood_pressure': bloodPressure,
    };
  }
}

class DiabetesRiskModel {
  final double riskScore;
  final String riskLevel;
  final String pathway;
  final String riskSource;
  final List<String> clinicalRationale;
  final String actionRecommendation;
  final String patientFriendlyGuidance;

  DiabetesRiskModel({
    required this.riskScore,
    required this.riskLevel,
    required this.pathway,
    required this.riskSource,
    required this.clinicalRationale,
    required this.actionRecommendation,
    required this.patientFriendlyGuidance,
  });

  factory DiabetesRiskModel.fromJson(Map<String, dynamic> json) {
    return DiabetesRiskModel(
      riskScore: (json['risk_score'] as num?)?.toDouble() ?? 0.0,
      riskLevel: json['risk_level'] ?? 'Unknown',
      pathway: json['pathway'] ?? 'Unknown',
      riskSource: json['risk_source'] ?? 'unknown',
      clinicalRationale: List<String>.from(json['clinical_rationale'] ?? []),
      actionRecommendation: json['action_recommendation'] ?? '',
      patientFriendlyGuidance: json['patient_friendly_guidance'] ?? '',
    );
  }
}

class RetinalQualityModel {
  final String qualityGrade; // 'GOOD', 'BORDERLINE', 'BAD'
  final double qualityScore;
  final bool isReliable;
  final List<String> rejectionReasons;
  final String? suspectedClinicalCause;
  final String operatorAction;
  final List<String> recaptureTips;
  final String audioGuidanceHindi;

  RetinalQualityModel({
    required this.qualityGrade,
    required this.qualityScore,
    required this.isReliable,
    required this.rejectionReasons,
    this.suspectedClinicalCause,
    required this.operatorAction,
    required this.recaptureTips,
    required this.audioGuidanceHindi,
  });

  factory RetinalQualityModel.fromJson(Map<String, dynamic> json) {
    return RetinalQualityModel(
      qualityGrade: json['quality_grade'] ?? 'Unknown',
      qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 0.0,
      isReliable: json['is_reliable'] ?? false,
      rejectionReasons: List<String>.from(json['rejection_reasons'] ?? []),
      suspectedClinicalCause: json['suspected_clinical_cause'],
      operatorAction: json['operator_action'] ?? '',
      recaptureTips: List<String>.from(json['recapture_tips'] ?? []),
      audioGuidanceHindi:
          json['audio_guidance_hindi'] ?? 'कृपया पुनः प्रयास करें।',
    );
  }
}

class ScreeningAnalysisModel {
  final String screeningId;
  final String patientId;
  final String eyeSide;
  final String cameraProfile;
  final String qualityGrade;
  final double qualityScore;
  final bool qualityPassed;
  final List<String> rejectionReasons;
  final int? drGrade;
  final String? drLabel;
  final double? predictionScore;
  final bool? isReferable;
  final bool requiresHumanReview;
  final String? humanReviewType;
  final String? humanReviewReason;
  final String originalImageUrl;
  final String? gradcamOverlayUrl;
  final Uint8List? gradcamOverlayBytes;
  final String? gradcamTargetLayer;
  final String? aiExplanationSummary;
  final String? secondOpinionPrompt;
  final String? modelBackend;
  final String actionRecommendation;
  final String plainLanguageAdvice;
  final String smsReferralSlip;
  final Map<String, dynamic>? biomarkers;
  // Tracks whether this result was produced without real AI analysis
  // (e.g. offline capture pending server-side analysis). When true, NO
  // diagnosis-grade values should have been presented — the UI must show
  // a data-source warning instead of rendering clinical metrics.
  final bool isOffline;
  // Tracks whether any individual value was not returned by the AI backend
  // and was left null. The UI uses this to flag gaps in the analysis.
  final bool isFromFallback;
  // Machine-readable terminal state from the server (null when usable):
  // IMG_INVALID | IMG_NOT_FUNDUS | IMG_UNGRADABLE | AI_LOW_CONFIDENCE |
  // AI_UNAVAILABLE | AI_TIMEOUT. AI_LOW_CONFIDENCE means the prediction is
  // provisional and must never be rendered as a confirmed finding.
  final String? errorCode;
  // Full 5-class probability vector from on-device inference (null when the
  // analysis came from a backend that does not expose it). Consumed by the
  // de-identified referral payload builder (/sync/v2).
  final List<double>? probabilities;
  // Provenance of the result relative to the screening service
  // (requirements 6.1-6.7): null when no status was derived — legacy
  // payloads and quality/decode rejections keep the existing presentation.
  // Never defaulted to a value the producing backend did not report.
  final ScreeningResultStatus? resultStatus;
  // What the screening service returned when confirming a preliminary
  // on-device grade; null until an on-device result was confirmed, or when
  // the result was not confirmed at all.
  final ServiceConfirmation? confirmation;

  // ---- Evidence-linked extension (schema_version 1.0) ---------------------
  // Re-used from the canonical marker model; optional (absent on legacy
  // payloads / offline fallbacks = "not provided", never negative).
  final List<CriterionEvaluation> criteriaEvaluation;
  final GradingPolicyInfo? gradingPolicy;
  final DisagreementInfo? disagreement;

  ScreeningAnalysisModel({
    required this.screeningId,
    required this.patientId,
    required this.eyeSide,
    required this.cameraProfile,
    required this.qualityGrade,
    required this.qualityScore,
    required this.qualityPassed,
    required this.rejectionReasons,
    this.drGrade,
    this.drLabel,
    this.predictionScore,
    required this.isReferable,
    required this.requiresHumanReview,
    this.humanReviewType,
    this.humanReviewReason,
    required this.originalImageUrl,
    this.gradcamOverlayUrl,
    this.gradcamOverlayBytes,
    this.gradcamTargetLayer,
    this.aiExplanationSummary,
    this.secondOpinionPrompt,
    this.modelBackend,
    required this.actionRecommendation,
    required this.plainLanguageAdvice,
    required this.smsReferralSlip,
    this.biomarkers,
    this.isOffline = false,
    this.isFromFallback = false,
    this.errorCode,
    this.probabilities,
    this.resultStatus,
    this.confirmation,
    this.criteriaEvaluation = const [],
    this.gradingPolicy,
    this.disagreement,
  });

  factory ScreeningAnalysisModel.fromJson(Map<String, dynamic> json) {
    return ScreeningAnalysisModel(
      screeningId: json['screening_id'] ?? 'Unknown',
      patientId: json['patient_id'] ?? '',
      eyeSide: json['eye_side'] ?? 'Unknown',
      cameraProfile: json['camera_profile'] ?? 'Unknown',
      qualityGrade: json['quality_grade'] ?? 'Unknown',
      qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 0.0,
      qualityPassed: json['quality_passed'] as bool? ?? false,
      rejectionReasons: List<String>.from(json['rejection_reasons'] ?? []),
      drGrade: json['dr_grade'],
      drLabel: json['dr_label'],
      predictionScore: (json['prediction_score'] as num?)?.toDouble(),
      isReferable: json['is_referable'] as bool?,
      requiresHumanReview: json['requires_human_review'] ?? false,
      humanReviewType: json['human_review_type'],
      humanReviewReason: json['human_review_reason'],
      originalImageUrl: json['original_image_url'] ?? '',
      gradcamOverlayUrl: json['gradcam_overlay_url'],
      gradcamTargetLayer: json['gradcam_target_layer']?.toString(),
      modelBackend: json['model_backend']?.toString(),
      actionRecommendation: json['action_recommendation'] ?? '',
      plainLanguageAdvice:
          json['plain_language_advice'] ??
          json['patient_plain_language_summary'] ??
          '',
      smsReferralSlip: json['sms_referral_slip'] ?? '',
      biomarkers: json['biomarkers'] as Map<String, dynamic>?,
      isOffline: json['is_offline'] ?? false,
      isFromFallback: json['is_from_fallback'] ?? false,
      errorCode: json['error_code']?.toString(),
      resultStatus: ScreeningResultStatus.tryParse(
        json['result_status']?.toString(),
      ),
      confirmation: _confirmationFromJson(json['confirmation']),
      criteriaEvaluation: json['criteria_evaluation'] is List
          ? (json['criteria_evaluation'] as List)
                .map(
                  (e) =>
                      CriterionEvaluation.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : const [],
      gradingPolicy: json['grading_policy'] is Map<String, dynamic>
          ? GradingPolicyInfo.fromJson(
              json['grading_policy'] as Map<String, dynamic>,
            )
          : null,
      disagreement: json['disagreement'] is Map<String, dynamic>
          ? DisagreementInfo.fromJson(
              json['disagreement'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  /// Reads the optional confirmation object from a payload. A dict without
  /// the agreement flag is not a confirmation and is dropped rather than
  /// fabricated; the agreement fact is the only required value.
  static ServiceConfirmation? _confirmationFromJson(Object? raw) {
    if (raw is! Map) return null;
    final agreed = raw['agreed'];
    if (agreed is! bool) return null;
    return ServiceConfirmation(
      agreed: agreed,
      serverBackend: raw['server_backend']?.toString(),
      serverGrade: (raw['server_grade'] as num?)?.toInt(),
      serverScreeningId: raw['server_screening_id']?.toString(),
    );
  }

  /// Returns a NEW immutable instance carrying this confirmation with the
  /// status merged per the pure derivation rule; the original instance is
  /// never mutated (requirements 6.3, 6.6, 6.7; design "Models Layer").
  ScreeningAnalysisModel withConfirmation(ServiceConfirmation confirmation) {
    return ScreeningAnalysisModel(
      screeningId: screeningId,
      patientId: patientId,
      eyeSide: eyeSide,
      cameraProfile: cameraProfile,
      qualityGrade: qualityGrade,
      qualityScore: qualityScore,
      qualityPassed: qualityPassed,
      rejectionReasons: rejectionReasons,
      drGrade: drGrade,
      drLabel: drLabel,
      predictionScore: predictionScore,
      isReferable: isReferable,
      requiresHumanReview: requiresHumanReview,
      humanReviewType: humanReviewType,
      humanReviewReason: humanReviewReason,
      originalImageUrl: originalImageUrl,
      gradcamOverlayUrl: gradcamOverlayUrl,
      gradcamTargetLayer: gradcamTargetLayer,
      modelBackend: modelBackend,
      actionRecommendation: actionRecommendation,
      plainLanguageAdvice: plainLanguageAdvice,
      smsReferralSlip: smsReferralSlip,
      biomarkers: biomarkers,
      isOffline: isOffline,
      isFromFallback: isFromFallback,
      errorCode: errorCode,
      probabilities: probabilities,
      resultStatus: deriveResultStatus(
        drGrade: drGrade,
        errorCode: errorCode,
        confirmation: confirmation,
      ),
      confirmation: confirmation,
    );
  }
}
