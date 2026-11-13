import 'screening_models.dart';

/// Operator-facing result-status vocabulary for the screening path
/// (requirements 5.3, 6.1-6.6, 8.5; design "Status state machine").
///
/// The stateborne meaning of each value:
/// - [preliminary]: a clean on-device grade that the screening service has
///   not confirmed. Requires clinician sign-off before being treated as final.
/// - [serviceConfirmed]: the screening service returned a grade that agrees
///   with the on-device grade (equal DR grade).
/// - [serviceDisagreed]: the screening service returned a different grade;
///   both results are preserved for human review.
/// - [serviceProduced]: the server produced the displayed result without any
///   on-device preliminary (device artifact unavailable fall-through).
/// - [unavailable]: no grade was produced on device or by the service.
/// - [withheld]: a grade exists but a terminal error flag (e.g.
///   low-confidence) withholds it from presentation as a finding.
enum ScreeningResultStatus {
  preliminary,
  serviceConfirmed,
  serviceDisagreed,
  serviceProduced,
  unavailable,
  withheld;

  /// Parse-safe mapping used when reading persisted/payload status names.
  /// Unknown or missing names map to null ("status unknown") rather than to
  /// any status value, so a legacy payload can never be mislabelled
  /// (requirement 5.6 discipline applied to the status field).
  static ScreeningResultStatus? tryParse(String? name) {
    for (final status in ScreeningResultStatus.values) {
      if (status.name == name) return status;
    }
    return null;
  }
}

/// Value object recording what the screening service returned when asked to
/// confirm a preliminary on-device result (requirements 5.3, 6.3, 6.6,
/// 6.7; design "Models Layer -> result_status module").
///
/// [agreed] is the only required field: it is the fact that decides the
/// merged status. The server-facing provenance fields stay nullable because
/// the server payload may omit or hide them, and no value is ever guessed
/// for them (requirement 5.4: unknown stays unknown).
class ServiceConfirmation {
  const ServiceConfirmation({
    required this.agreed,
    this.serverBackend,
    this.serverGrade,
    this.serverScreeningId,
  });

  /// Whether the server DR grade equals the preliminary on-device grade.
  final bool agreed;

  /// Backend identity reported by the server result (R5.3), null when the
  /// payload carried none — never substituted with a device-side identity.
  final String? serverBackend;

  /// DR grade returned by the server, null when the payload carried none.
  final int? serverGrade;

  /// Server-side screening identifier of the confirming result.
  final String? serverScreeningId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServiceConfirmation &&
          other.agreed == agreed &&
          other.serverBackend == serverBackend &&
          other.serverGrade == serverGrade &&
          other.serverScreeningId == serverScreeningId;

  @override
  int get hashCode =>
      Object.hash(agreed, serverBackend, serverGrade, serverScreeningId);
}

/// Error codes that mark a quality/decode rejection. These reject the image
/// before any grading exists, so they are not grading results at all and the
/// caller must keep the status null to preserve the existing rejection UI
/// (requirement 4; design "Data Models" invariant (d)).
const _nonGradingErrorCodes = <String>{
  'IMG_INVALID',
  'IMG_NOT_FUNDUS',
  'IMG_UNGRADABLE',
};

/// Pure derivation of the result status for an analysis outcome
/// (design "Models Layer -> result_status module", precedence list).
///
/// Precedence (first match wins):
/// 1. quality/decode rejection (`IMG_INVALID`, `IMG_NOT_FUNDUS`,
///    `IMG_UNGRADABLE`) -> null: not a grading result;
/// 2. a recorded confirmation that agreed -> [ScreeningResultStatus.serviceConfirmed];
/// 3. a recorded confirmation that disagreed -> [ScreeningResultStatus.serviceDisagreed];
/// 4. a clean server-produced result (grade, no error) -> [ScreeningResultStatus.serviceProduced];
/// 5. no grade produced -> [ScreeningResultStatus.unavailable];
/// 6. grade present with an availability/quality terminal error
///    (e.g. AI_LOW_CONFIDENCE) -> [ScreeningResultStatus.withheld];
/// 7. otherwise -> [ScreeningResultStatus.preliminary].
ScreeningResultStatus? deriveResultStatus({
  required int? drGrade,
  String? errorCode,
  ServiceConfirmation? confirmation,
  bool serverProduced = false,
}) {
  if (errorCode != null && _nonGradingErrorCodes.contains(errorCode)) {
    return null;
  }
  if (confirmation != null) {
    return confirmation.agreed
        ? ScreeningResultStatus.serviceConfirmed
        : ScreeningResultStatus.serviceDisagreed;
  }
  if (serverProduced && drGrade != null && errorCode == null) {
    return ScreeningResultStatus.serviceProduced;
  }
  if (drGrade == null) {
    return ScreeningResultStatus.unavailable;
  }
  if (errorCode != null) {
    return ScreeningResultStatus.withheld;
  }
  return ScreeningResultStatus.preliminary;
}

/// Pure merge rule: decide what the screening service's result means for a
/// preliminary on-device grade (requirements 6.3, 6.4, 6.6; design D4/D7).
///
/// Returns null — no confirmation, status must stay preliminary — when the
/// server result is not a usable grade to agree with:
/// - it is the offline fallback ([ScreeningAnalysisModel.isOffline]);
/// - it carries a terminal [ScreeningAnalysisModel.errorCode];
/// - it has no DR grade (including the PENDING_SYNC offline fallback).
///
/// Otherwise the confirmation records agreement by equal DR grade (design
/// "Data Contracts": the server has no agree/disagree concept and referable
/// semantics are deliberately excluded from the comparison) and preserves
/// the server's own backend, grade and screening id.
ServiceConfirmation? buildConfirmation({
  required int preliminaryGrade,
  required ScreeningAnalysisModel serverResult,
}) {
  if (serverResult.isOffline) return null;
  if (serverResult.errorCode != null) return null;
  final serverGrade = serverResult.drGrade;
  if (serverGrade == null) return null;
  return ServiceConfirmation(
    agreed: serverGrade == preliminaryGrade,
    serverBackend: serverResult.modelBackend,
    serverGrade: serverGrade,
    serverScreeningId: serverResult.screeningId,
  );
}
