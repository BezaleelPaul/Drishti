import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_service.dart';
import 'consent_service.dart';
import 'deidentify.dart';
import 'offline_queue_service.dart';

/// Consent-gated de-identified referral uplink (Ticket D-2).
///
/// End-to-end privacy chain, every link enforced in code:
///   1. Consent: no payload is EVER built without a granted, non-withdrawn
///      consent record for the current version (fail closed).
///   2. De-identification: pseudonym + pseudo screening id from the
///      per-device HMAC salt; image downscaled + EXIF-stripped; age banded.
///   3. Client-side PHI lint: any whitelist violation drops the payload
///      BEFORE it reaches the network (the server re-checks fail-closed).
///   4. Transport: POST /sync/v2 over HTTPS (the ApiService constructor
///      rejects plaintext endpoints).
///   5. Store-and-forward: on network failure the payload persists to the
///      encrypted offline queue and flushes on the next sync window.
class ReferralUplinkService {
  ReferralUplinkService({
    DeidentificationService? deid,
    ConsentService? consent,
    http.Client? httpClient,
  }) : _deid = deid,
       _consent = consent ?? ConsentService(),
       _client = httpClient;

  static const _uplinkTimeout = Duration(seconds: 90);

  final DeidentificationService? _deid;
  final ConsentService _consent;
  final http.Client? _client;

  http.Client _effectiveClient() => _client ?? http.Client();

  /// Surfaces the per-device pseudonym for a patient (UI display only —
  /// lets the operator SEE the privacy guarantee before consenting).
  String? pseudonymFor(String localPatientId) =>
      _deid?.pseudonym(localPatientId);

  /// Loads (or creates) the device-keyed de-identification service.
  static Future<ReferralUplinkService> create({http.Client? httpClient}) async {
    return ReferralUplinkService(
      deid: await DeidentificationService.fromDevice(),
      httpClient: httpClient,
    );
  }

  /// Builds the de-identified payload, or explains why the uplink is
  /// refused. [imageBytes] may be null (score-only over-read).
  Future<ReferralBuildResult> buildPayload({
    required String localPatientId,
    required int? patientAge,
    required String? patientGender,
    required String eyeSide,
    required String localScreeningId,
    required int? drGrade,
    required String? drLabel,
    required double? confidence,
    required bool requiresHumanReview,
    required String? consentLanguage,
    Uint8List? imageBytes,
  }) async {
    // 1. Consent gate — fail closed.
    final record = await _consent.get(localPatientId);
    if (record == null || !record.isSyncAllowed) {
      return const ReferralBuildResult.refused(ReferralBuildRefusal.noConsent);
    }

    final deid = _deid;
    if (deid == null) {
      return const ReferralBuildResult.refused(
        ReferralBuildRefusal.deidUnavailable,
      );
    }

    // 2. De-identification.
    final payload = <String, dynamic>{
      'pseudonym': deid.pseudonym(localPatientId),
      'pseudo_screening_id': deid.pseudonymizeScreening(localScreeningId),
      'age_band': deid.ageBand(patientAge),
      'gender': patientGender,
      'eye_side': eyeSide,
      'dr_grade': drGrade,
      'dr_label': drLabel,
      'probabilities': null,
      'confidence': confidence,
      'requires_human_review': requiresHumanReview,
      'image_base64': null,
      'consent_version': record.version,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
    };

    if (imageBytes != null) {
      try {
        final clean = deid.deidentifyImage(imageBytes);
        payload['image_base64'] = base64Encode(clean);
      } on FormatException {
        // A corrupt image must not block the score-only over-read.
        payload['image_base64'] = null;
      }
    }

    // 3. Client-side PHI lint — drop BEFORE the network, fail closed.
    final violations = deid.lintPayload(payload);
    if (violations.isNotEmpty) {
      return ReferralBuildResult.refused(
        ReferralBuildRefusal.phiLint,
        violations: violations,
      );
    }

    // Drop null optionals so the wire format stays minimal.
    payload.removeWhere((_, v) => v == null);
    return ReferralBuildResult.ok(payload);
  }

  /// Uploads one payload to /sync/v2. Returns a typed outcome; network
  /// failures queue the payload durably for the next sync window.
  Future<ReferralUploadResult> upload(Map<String, dynamic> payload) async {
    try {
      final response = await _effectiveClient()
          .post(
            Uri.parse('${ApiService.defaultBaseUrl}/sync/v2'),
            headers: {
              'Content-Type': 'application/json',
              'X-API-Key': ApiService.apiKey,
            },
            body: jsonEncode({
              'screenings': [payload],
            }),
          )
          .timeout(_uplinkTimeout);

      if (response.statusCode == 200) {
        return const ReferralUploadResult.uploaded();
      }
      if (response.statusCode == 422) {
        // Server-side PHI rejection: this must never happen for a payload
        // the client linter passed — treat as a hard incident, DO NOT
        // queue for retry (retrying would replay the violation).
        return ReferralUploadResult.rejected(body: response.body);
      }
      return ReferralUploadResult.rejected(body: 'HTTP ${response.statusCode}');
    } on Exception catch (_) {
      // SocketException / ClientException / TimeoutException: offline or
      // flaky rural link — store-and-forward keeps the consent promise
      // (the data will reach the doctor) without losing durability.
      await _queueForLater(payload);
      return const ReferralUploadResult.queued();
    }
  }

  Future<void> _queueForLater(Map<String, dynamic> payload) async {
    final id = '${payload['pseudo_screening_id'] ?? ''}';
    if (id.isEmpty) return;
    await OfflineQueueService.instance.put(
      OfflineQueueService.kindDeidReferral,
      id,
      payload,
    );
  }

  /// Flushes every queued de-identified referral (connectivity window or
  /// app start). Removes ONLY server-confirmed entries; 422-rejected
  /// payloads are dropped from the queue AND reported (retrying a
  /// linter-passed payload that the server rejects means the two linters
  /// disagree — that is an incident, not a retry).
  Future<ReferralFlushResult> flushQueued() async {
    final entries = await OfflineQueueService.instance.restoreKind(
      OfflineQueueService.kindDeidReferral,
    );
    var uploaded = 0;
    var queued = 0;
    var rejected = 0;
    for (final entry in entries) {
      final result = await upload(entry.payload);
      switch (result.outcome) {
        case ReferralOutcome.uploaded:
          await OfflineQueueService.instance.remove(
            OfflineQueueService.kindDeidReferral,
            entry.id,
          );
          uploaded++;
        case ReferralOutcome.queued:
          queued++;
        case ReferralOutcome.rejected:
          await OfflineQueueService.instance.remove(
            OfflineQueueService.kindDeidReferral,
            entry.id,
          );
          rejected++;
      }
    }
    return ReferralFlushResult(
      uploaded: uploaded,
      stillQueued: queued,
      rejected: rejected,
    );
  }
}

enum ReferralBuildRefusal { noConsent, deidUnavailable, phiLint }

class ReferralBuildResult {
  const ReferralBuildResult.ok(this.payload)
    : refusal = null,
      violations = const [];

  const ReferralBuildResult.refused(this.refusal, {this.violations = const []})
    : payload = null;

  final Map<String, dynamic>? payload;
  final ReferralBuildRefusal? refusal;
  final List<String> violations;

  bool get isOk => payload != null && refusal == null;
}

enum ReferralOutcome { uploaded, queued, rejected }

class ReferralUploadResult {
  const ReferralUploadResult.uploaded()
    : outcome = ReferralOutcome.uploaded,
      body = null;
  const ReferralUploadResult.queued()
    : outcome = ReferralOutcome.queued,
      body = null;
  const ReferralUploadResult.rejected({required this.body})
    : outcome = ReferralOutcome.rejected;

  final ReferralOutcome outcome;
  final String? body;
}

class ReferralFlushResult {
  const ReferralFlushResult({
    required this.uploaded,
    required this.stillQueued,
    required this.rejected,
  });

  final int uploaded;
  final int stillQueued;
  final int rejected;
}
