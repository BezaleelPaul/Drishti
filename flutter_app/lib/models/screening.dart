import 'retinal_markers.dart';

class ScreeningResult {
  // Evidence-linked extension models are re-used (never duplicated) from the
  // canonical marker model.
  final String screeningId;
  final String patientId;
  final String eyeSide;
  final String cameraProfile;
  final String qualityGrade;
  final double qualityScore;
  final bool qualityPassed;
  final List<String> rejectionReasons;
  final String? suspectedClinicalCause;
  final int? drGrade;
  final String? drLabel;
  final double? predictionScore;
  // Null when ungradable — the backend sends no referability verdict then.
  final bool? isReferable;
  final bool requiresHumanReview;
  final String humanReviewType;
  final String? humanReviewReason;
  final String? originalImageUrl;
  final String? gradcamOverlayUrl;
  final String? gradcamTargetLayer;
  final String? modelBackend;
  final String actionRecommendation;
  final String patientPlainLanguageSummary;
  final String createdAt;
  final String? capturedAt; // field-capture time (null when never offline)
  // Segmentation biomarkers from the server (null when ungradable — never estimated)
  final double? vesselDensityPct;
  final int? microaneurysmCount;
  final String? csmeRisk;
  final double? minFoveaDistancePx;
  // Machine-readable terminal state from the server, null when the result is
  // usable: IMG_INVALID | IMG_NOT_FUNDUS | IMG_UNGRADABLE |
  // AI_LOW_CONFIDENCE | AI_UNAVAILABLE | AI_TIMEOUT. When set, the screen
  // must NOT present dr_grade as a confirmed finding.
  final String? errorCode;

  // ---- Evidence-linked extension (schema_version 1.0) ---------------------
  // Optional: absent on legacy servers/offline fallbacks = "not provided",
  // never negative evidence. Reuses the retinal_markers extension models.
  final String? schemaVersion;
  final List<LesionEvidenceItem> lesionEvidence;
  final List<CriterionEvaluation> criteriaEvaluation;
  final GradingPolicyInfo? gradingPolicy;
  final DisagreementInfo? disagreement;

  ScreeningResult({
    required this.screeningId,
    required this.patientId,
    this.eyeSide = 'Right',
    this.cameraProfile = 'Generic Fundus Camera',
    required this.qualityGrade,
    required this.qualityScore,
    required this.qualityPassed,
    this.rejectionReasons = const [],
    this.suspectedClinicalCause,
    this.drGrade,
    this.drLabel,
    this.predictionScore,
    this.isReferable,
    this.requiresHumanReview = false,
    this.humanReviewType = 'NONE',
    this.humanReviewReason,
    this.originalImageUrl,
    this.gradcamOverlayUrl,
    this.gradcamTargetLayer,
    this.modelBackend,
    this.actionRecommendation = '',
    this.patientPlainLanguageSummary = '',
    required this.createdAt,
    this.capturedAt,
    this.vesselDensityPct,
    this.microaneurysmCount,
    this.csmeRisk,
    this.minFoveaDistancePx,
    this.errorCode,
    this.schemaVersion,
    this.lesionEvidence = const [],
    this.criteriaEvaluation = const [],
    this.gradingPolicy,
    this.disagreement,
  });

  factory ScreeningResult.fromJson(
    Map<String, dynamic> json,
  ) => ScreeningResult(
    screeningId: json['screening_id'] ?? '',
    patientId: json['patient_id'] ?? '',
    eyeSide: json['eye_side'] ?? 'Unknown',
    cameraProfile: json['camera_profile'] ?? 'Unknown',
    qualityGrade: json['quality_grade'] ?? 'Unknown',
    qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 0.0,
    // NOTE: ungradable (non-GOOD) is fail. BORDERLINE cleared by server-side
    // reassessment arrives as an explicit quality_passed=true from the
    // backend; only fall back to the grade check when the flag is absent.
    qualityPassed:
        json['quality_passed'] as bool? ?? (json['quality_grade'] == 'GOOD'),
    rejectionReasons: json['rejection_reasons'] is List
        ? (json['rejection_reasons'] as List).map((e) => e.toString()).toList()
        : const [],
    suspectedClinicalCause: json['suspected_clinical_cause']?.toString(),
    drGrade: (json['dr_grade'] as num?)?.toInt(),
    drLabel: json['dr_label']?.toString(),
    predictionScore: (json['prediction_score'] as num?)?.toDouble(),
    isReferable: json['is_referable'] as bool?,
    requiresHumanReview: json['requires_human_review'] ?? false,
    humanReviewType: json['human_review_type'] ?? 'NONE',
    humanReviewReason: json['human_review_reason']?.toString(),
    originalImageUrl: json['original_image_url']?.toString(),
    gradcamOverlayUrl: json['gradcam_overlay_url']?.toString(),
    gradcamTargetLayer: json['gradcam_target_layer']?.toString(),
    modelBackend: json['model_backend']?.toString(),
    actionRecommendation: (json['action_recommendation'] ?? '').toString(),
    patientPlainLanguageSummary: (json['patient_plain_language_summary'] ?? '')
        .toString(),
    createdAt: (json['created_at'] ?? '').toString(),
    capturedAt: json['captured_at']?.toString(),
    vesselDensityPct: (json['vessel_density_pct'] as num?)?.toDouble(),
    microaneurysmCount: (json['microaneurysm_count'] as num?)?.toInt(),
    csmeRisk: json['csme_risk']?.toString(),
    minFoveaDistancePx: (json['min_fovea_distance_px'] as num?)?.toDouble(),
    errorCode: json['error_code']?.toString(),
    schemaVersion: json['schema_version']?.toString(),
    lesionEvidence: json['lesion_evidence'] is List
        ? (json['lesion_evidence'] as List)
              .map(
                (e) => LesionEvidenceItem.fromJson(e as Map<String, dynamic>),
              )
              .toList()
        : const [],
    criteriaEvaluation: json['criteria_evaluation'] is List
        ? (json['criteria_evaluation'] as List)
              .map(
                (e) => CriterionEvaluation.fromJson(e as Map<String, dynamic>),
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
