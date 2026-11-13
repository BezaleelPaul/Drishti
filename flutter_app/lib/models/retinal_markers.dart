class MarkerCircle {
  final int x;
  final int y;
  final int r;

  MarkerCircle({required this.x, required this.y, required this.r});

  factory MarkerCircle.fromJson(Map<String, dynamic> json) => MarkerCircle(
    x: (json['x'] as num?)?.toInt() ?? 0,
    y: (json['y'] as num?)?.toInt() ?? 0,
    r: (json['r'] as num?)?.toInt() ?? 0,
  );
}

class MarkerPoint {
  final int x;
  final int y;

  MarkerPoint({required this.x, required this.y});

  factory MarkerPoint.fromJson(Map<String, dynamic> json) => MarkerPoint(
    x: (json['x'] as num?)?.toInt() ?? 0,
    y: (json['y'] as num?)?.toInt() ?? 0,
  );
}

/// Evidence-linked extension (schema_version 1.0).
///
/// One classical-CV lesion candidate with its identity, detection status,
/// and links to the grading criteria it supports. Every field is optional
/// at parse time: legacy payloads (pre-1.0) carry none of this, and a
/// missing field means "not provided", never "negative".
class LesionEvidenceItem {
  static const String typeMaCandidate = 'microaneurysm_candidate';
  static const String typeExudateCandidate = 'exudate_candidate';
  static const String typeHemorrhageCandidate = 'hemorrhage_candidate';
  static const String typeUnknown = 'unknown';

  static const String statusDetected = 'detected';
  static const String statusIndeterminate = 'indeterminate';
  static const String statusNotEvaluated = 'not_evaluated';
  static const String statusFailed = 'failed';
  static const String statusUnknown = 'unknown';

  final String lesionId;

  /// Controlled value; unknown server values degrade to [typeUnknown]
  /// (never a crash, never a fabricated type).
  final String lesionType;
  final String detectionStatus;
  final int x;
  final int y;
  final int radius;

  /// Criterion ids from the versioned grading policy this evidence supports.
  final List<String> criterionLinks;
  final List<String> evidenceNotes;
  final String detectorId;
  final String detectorVersion;
  final int imageWidth;
  final int imageHeight;

  const LesionEvidenceItem({
    required this.lesionId,
    required this.lesionType,
    required this.detectionStatus,
    required this.x,
    required this.y,
    required this.radius,
    this.criterionLinks = const [],
    this.evidenceNotes = const [],
    this.detectorId = '',
    this.detectorVersion = '',
    this.imageWidth = 0,
    this.imageHeight = 0,
  });

  bool get typeKnown => lesionType != typeUnknown;
  bool get statusKnown => detectionStatus != statusUnknown;

  /// A detected candidate within source-image bounds.
  bool get geometryValid =>
      x >= 0 &&
      y >= 0 &&
      radius >= 0 &&
      (imageWidth == 0 || x < imageWidth) &&
      (imageHeight == 0 || y < imageHeight);

  factory LesionEvidenceItem.fromJson(Map<String, dynamic> json) {
    final type = json['lesion_type'];
    final status = json['detection_status'];
    return LesionEvidenceItem(
      lesionId: (json['lesion_id'] ?? '').toString(),
      lesionType: _parseLesionType(type is String ? type : null),
      detectionStatus: _parseDetectionStatus(status is String ? status : null),
      x: (json['x'] as num?)?.toInt() ?? 0,
      y: (json['y'] as num?)?.toInt() ?? 0,
      radius: (json['radius'] as num?)?.toInt() ?? 0,
      criterionLinks: _stringList(json['criterion_links']),
      evidenceNotes: _stringList(json['evidence_notes']),
      detectorId: (json['detector_id'] ?? '').toString(),
      detectorVersion: (json['detector_version'] ?? '').toString(),
      imageWidth: (json['image_width'] as num?)?.toInt() ?? 0,
      imageHeight: (json['image_height'] as num?)?.toInt() ?? 0,
    );
  }

  static String _parseLesionType(String? raw) {
    switch (raw) {
      case typeMaCandidate:
        return typeMaCandidate;
      case typeExudateCandidate:
        return typeExudateCandidate;
      case typeHemorrhageCandidate:
        return typeHemorrhageCandidate;
      case null:
        return typeUnknown;
      default:
        return typeUnknown;
    }
  }

  static String _parseDetectionStatus(String? raw) {
    switch (raw) {
      case statusDetected:
        return statusDetected;
      case statusIndeterminate:
        return statusIndeterminate;
      case statusNotEvaluated:
        return statusNotEvaluated;
      case statusFailed:
        return statusFailed;
      case null:
        return statusUnknown;
      default:
        return statusUnknown;
    }
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).toList(growable: false);
  }
}

/// One versioned grading-criterion evaluation linked to evidence ids.
class CriterionEvaluation {
  static const String satisfied = 'satisfied';
  static const String notMet = 'not_met';
  static const String indeterminate = 'indeterminate';
  static const String notEvaluated = 'not_evaluated';
  static const String unknown = 'unknown';

  final String criterionId;
  final String status;
  final List<String> supportingEvidenceIds;
  final List<String> contradictingEvidenceIds;
  final List<String> reasonCodes;
  final String explanationKey;

  const CriterionEvaluation({
    required this.criterionId,
    required this.status,
    this.supportingEvidenceIds = const [],
    this.contradictingEvidenceIds = const [],
    this.reasonCodes = const [],
    this.explanationKey = '',
  });

  bool get statusKnown => status != unknown;

  factory CriterionEvaluation.fromJson(Map<String, dynamic> json) =>
      CriterionEvaluation(
        criterionId: (json['criterion_id'] ?? '').toString(),
        status: _parseStatus(
          json['status'] is String ? json['status'] as String : null,
        ),
        supportingEvidenceIds: _stringList(json['supporting_evidence_ids']),
        contradictingEvidenceIds: _stringList(
          json['contradicting_evidence_ids'],
        ),
        reasonCodes: _stringList(json['reason_codes']),
        explanationKey: (json['explanation_key'] ?? '').toString(),
      );

  static String _parseStatus(String? raw) {
    switch (raw) {
      case satisfied:
        return satisfied;
      case notMet:
        return notMet;
      case indeterminate:
        return indeterminate;
      case notEvaluated:
        return notEvaluated;
      case null:
        return unknown;
      default:
        return unknown;
    }
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).toList(growable: false);
  }
}

/// Which versioned policy produced the criteria evaluation.
class GradingPolicyInfo {
  final String policyId;
  final String policyVersion;
  final String framework;

  const GradingPolicyInfo({
    required this.policyId,
    required this.policyVersion,
    required this.framework,
  });

  factory GradingPolicyInfo.fromJson(Map<String, dynamic> json) =>
      GradingPolicyInfo(
        policyId: (json['policy_id'] ?? '').toString(),
        policyVersion: (json['policy_version'] ?? '').toString(),
        framework: (json['framework'] ?? '').toString(),
      );
}

/// Deterministic CNN-vs-evidence reconciliation result.
class DisagreementInfo {
  static const String match = 'match';
  static const String adjacent = 'adjacent';
  static const String conflict = 'conflict';
  static const String notAsserted = 'not_asserted';
  static const String incomplete = 'incomplete';
  static const String modelUnavailable = 'model_unavailable';
  static const String unknown = 'unknown';

  final String status;
  final List<String> reasonCodes;
  final bool reviewRequired;
  final int? cnnGrade;
  final int? evidenceImpliedGrade;
  final String explanationKey;
  final String policyId;
  final String policyVersion;

  const DisagreementInfo({
    required this.status,
    required this.reasonCodes,
    required this.reviewRequired,
    this.cnnGrade,
    this.evidenceImpliedGrade,
    required this.explanationKey,
    required this.policyId,
    required this.policyVersion,
  });

  factory DisagreementInfo.fromJson(Map<String, dynamic> json) =>
      DisagreementInfo(
        status: _parseStatus(
          json['status'] is String ? json['status'] as String : null,
        ),
        reasonCodes: _stringList(json['reason_codes']),
        reviewRequired: json['review_required'] as bool? ?? false,
        cnnGrade: (json['cnn_grade'] as num?)?.toInt(),
        evidenceImpliedGrade: (json['evidence_implied_grade'] as num?)?.toInt(),
        explanationKey: (json['explanation_key'] ?? '').toString(),
        policyId: (json['policy_id'] ?? '').toString(),
        policyVersion: (json['policy_version'] ?? '').toString(),
      );

  static String _parseStatus(String? raw) {
    switch (raw) {
      case match:
        return match;
      case adjacent:
        return adjacent;
      case conflict:
        return conflict;
      case notAsserted:
        return notAsserted;
      case incomplete:
        return incomplete;
      case modelUnavailable:
        return modelUnavailable;
      case null:
        return unknown;
      default:
        return unknown;
    }
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).toList(growable: false);
  }
}

class RetinalMarkers {
  static const String classicalCvSource = 'classical_cv_segmentation';

  final String reviewId;
  // Honesty invariant: available=false (could not compute) is a DIFFERENT
  // state from available=true with an empty maCandidates list (healthy
  // retina, no lesion candidates). Never conflate the two.
  final bool available;
  final String? reason;
  // Provenance pinned to classical CV segmentation — never model attention,
  // Grad-CAM, or a diagnosis (Req 2.2). Not settable by callers; fromJson
  // rejects any other value.
  final String source;
  final int width;
  final int height;
  final MarkerCircle? opticDisc;
  final MarkerPoint? fovea;
  // Coordinates only — no vessel/exudate mask data in this payload. Always
  // present; explicitly empty when there are no candidates (never null).
  final List<MarkerCircle> maCandidates;

  // ---- Evidence-linked extension (schema_version 1.0) ---------------------
  // Optional: legacy payloads and the on-device path carry none of these.
  // Absence means "not provided by this payload", never a negative result.
  final String schemaVersion;
  final List<LesionEvidenceItem> lesionEvidence;
  final List<CriterionEvaluation> criteriaEvaluation;
  final GradingPolicyInfo? gradingPolicy;
  final DisagreementInfo? disagreement;

  RetinalMarkers({
    required this.reviewId,
    required this.available,
    this.reason,
    this.width = 0,
    this.height = 0,
    this.opticDisc,
    this.fovea,
    this.maCandidates = const [],
    this.schemaVersion = '',
    this.lesionEvidence = const [],
    this.criteriaEvaluation = const [],
    this.gradingPolicy,
    this.disagreement,
  }) : source = classicalCvSource;

  /// True when this payload carries the evidence-linked extension.
  bool get hasEvidenceExtension => schemaVersion == '1.0';

  factory RetinalMarkers.fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    if (source != null && source != classicalCvSource) {
      throw FormatException('Unsupported marker source: $source');
    }
    return RetinalMarkers(
      reviewId: (json['review_id'] ?? '').toString(),
      available: json['available'] as bool? ?? false,
      reason: json['reason']?.toString(),
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      opticDisc: json['optic_disc'] == null
          ? null
          : MarkerCircle.fromJson(json['optic_disc'] as Map<String, dynamic>),
      fovea: json['fovea'] == null
          ? null
          : MarkerPoint.fromJson(json['fovea'] as Map<String, dynamic>),
      maCandidates: json['ma_candidates'] is List
          ? (json['ma_candidates'] as List)
                .map((e) => MarkerCircle.fromJson(e as Map<String, dynamic>))
                .toList()
          : const [],
      schemaVersion: (json['schema_version'] ?? '').toString(),
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
}
