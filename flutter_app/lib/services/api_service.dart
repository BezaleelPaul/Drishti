import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import '../models/patient.dart';
import '../models/retinal_markers.dart';
import '../models/screening.dart';
import '../models/screening_models.dart' as ui;
import 'offline_queue_service.dart';

/// Thrown when the review queue rejects the configured API key.
/// Callers must surface this (demo-data banner), never render it as "empty".
class ReviewAuthException implements Exception {
  final String message;
  const ReviewAuthException(this.message);

  @override
  String toString() => message;
}

class ApiService {
  /// Production base URL. Override per deployment via
  /// `--dart-define=DRISHTI_BASE_URL=https://api.example.com`.
  /// HTTPS-only: plaintext http is rejected (see [_requireHttps]),
  /// matching android:usesCleartextTraffic="false" + Network Security
  /// Config. The old `http://localhost:8000` dev default was removed
  /// because scanners flag any plaintext endpoint in the package.
  static const String defaultBaseUrl = String.fromEnvironment(
    'DRISHTI_BASE_URL',
    defaultValue: 'https://drishti-ai-xg6w.onrender.com',
  );

  /// API key for the DRISHTI backend (X-API-Key header).
  /// Dev default matches the backend non-prod key; override per deployment
  /// via `--dart-define=DRISHTI_API_KEY=...` or constructor injection.
  static const String apiKey = String.fromEnvironment(
    'DRISHTI_API_KEY',
    defaultValue: 'dev-operator-key',
  );

  static const Duration _shortTimeout = Duration(seconds: 20);
  static const Duration _inferTimeout = Duration(seconds: 45);
  static const Duration _syncTimeout = Duration(seconds: 90);

  final String baseUrl;
  final String key;

  // Offline queue hot-path mirrors (write-through to OfflineQueueService;
  // rehydrated at app start by restoreQueues, so field-camp captures
  // survive process kills — Ticket B-2).
  static final List<Map<String, dynamic>> offlineQueue = [];
  static final List<Map<String, dynamic>> offlinePatients = [];

  /// Rehydrates the in-memory mirrors from the durable store at startup.
  static Future<void> restoreQueues() async {
    final restored = await OfflineQueueService.instance.restoreAll();
    for (final e in restored.patients) {
      if (!offlinePatients.any((p) => '${p['patient_id']}' == e.id)) {
        offlinePatients.add(e.payload);
      }
    }
    for (final e in restored.screenings) {
      if (!offlineQueue.any((s) => '${s['local_screening_id']}' == e.id)) {
        offlineQueue.add(e.payload);
      }
    }
  }

  ApiService({this.baseUrl = defaultBaseUrl, this.key = apiKey}) {
    _requireHttps(baseUrl);
  }

  /// Test-only instance: skips the HTTPS gate so tests can point at a
  /// local in-memory [HttpServer]. Never wire this into production.
  @visibleForTesting
  ApiService.forTesting({required this.baseUrl, required this.key});

  /// Fail closed on plaintext endpoints. Only `https` (or wss-derived
  /// https) is allowed. Emulator loopback for local dev must be an
  /// explicit opt-in: `--dart-define=DRISHTI_ALLOW_HTTP_LOOPBACK=true`
  /// plus a debug-only Network Security Config overlay — never in release.
  static void _requireHttps(String url) {
    const allowLoopback = bool.fromEnvironment(
      'DRISHTI_ALLOW_HTTP_LOOPBACK',
      defaultValue: false,
    );
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      final isLoopback =
          uri != null &&
          (uri.host == 'localhost' ||
              uri.host == '127.0.0.1' ||
              uri.host == '10.0.2.2');
      if (!(allowLoopback && isLoopback)) {
        throw ArgumentError.value(
          url,
          'baseUrl',
          'HTTPS-only: configure DRISHTI_BASE_URL with an https:// URL. '
              'Plaintext http is blocked by the Network Security Config.',
        );
      }
    }
  }

  Map<String, String> get _headers => {'X-API-Key': key};

  /// Lightweight server reachability probe (drives the Online/Offline badge).
  Future<bool> ping() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/status'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Registers the patient server-side BEFORE any quality/analyze call.
  ///
  /// Returns the server-confirmed patient_id. Throws on HTTP 4xx (caller
  /// must surface the rejection — never proceed silently). Only genuine
  /// connectivity failures queue the patient for later sync and return the
  /// local id.
  ///
  /// Accepts [Patient] (canonical), [ui.PatientModel] (demo intake flow),
  /// or a raw JSON map — all normalized via `toJson()`.
  Future<String> registerPatient(dynamic patient) async {
    final Map<String, dynamic> payload;
    if (patient is Patient) {
      payload = patient.toJson();
    } else if (patient is ui.PatientModel) {
      payload = {
        ...patient.toJson(),
        'screening_centre': 'PHC Shirur Sub-Centre',
      };
    } else if (patient is Map<String, dynamic>) {
      payload = Map<String, dynamic>.from(patient);
    } else {
      // Fallback: try duck-typing toJson().
      try {
        payload = Map<String, dynamic>.from(
          (patient as dynamic).toJson() as Map,
        );
      } catch (_) {
        throw ArgumentError(
          'registerPatient expects Patient, PatientModel or Map',
        );
      }
    }
    return _postPatient(payload, queueOnOffline: true);
  }

  Future<String> _postPatient(
    Map<String, dynamic> payload, {
    required bool queueOnOffline,
  }) async {
    final localId = (payload['patient_id'] ?? '').toString();
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/patients'),
            headers: {'Content-Type': 'application/json', ..._headers},
            body: json.encode(payload),
          )
          .timeout(_shortTimeout);
      if (response.statusCode == 201 || response.statusCode == 200) {
        final body = json.decode(response.body);
        return (body['patient_id'] ?? localId).toString();
      }
      if ((response.statusCode == 400 || response.statusCode == 409) &&
          localId.isNotEmpty) {
        // Possibly already registered (retried sync) — confirm before failing.
        final existing = await http
            .get(
              Uri.parse('$baseUrl/patients/${Uri.encodeComponent(localId)}'),
              headers: _headers,
            )
            .timeout(_shortTimeout);
        if (existing.statusCode == 200) return localId;
      }
      throw Exception(
        'Patient registration rejected: ${response.statusCode} ${response.body}',
      );
    } on SocketException {
      if (queueOnOffline && localId.isNotEmpty) {
        offlinePatients.add(payload);
        await OfflineQueueService.instance.addPatient(payload);
      }
      if (!queueOnOffline) rethrow;
      return localId;
    } on http.ClientException {
      if (queueOnOffline && localId.isNotEmpty) {
        offlinePatients.add(payload);
        await OfflineQueueService.instance.addPatient(payload);
      }
      if (!queueOnOffline) rethrow;
      return localId;
    } on TimeoutException {
      if (queueOnOffline && localId.isNotEmpty) {
        offlinePatients.add(payload);
        await OfflineQueueService.instance.addPatient(payload);
      }
      if (!queueOnOffline) rethrow;
      return localId;
    }
  }

  Map<String, dynamic> _offlineQualityFallback() {
    // Offline: no measurement is possible on-device. Report explicitly as
    // pending server-side gating — never fabricate quality metrics.
    // Keys mirror RetinalQualityResponse from the backend.
    return {
      'quality_grade': 'PENDING_SYNC',
      'quality_score': 0.0,
      'is_reliable': false,
      'rejection_reasons': [
        'No connectivity — image queued for server-side quality gate.',
      ],
      'operator_action':
          'No network. Image saved to offline queue; quality will be checked on sync.',
      'recapture_tips': [],
      'audio_guidance_hindi':
          'नेटवर्क नहीं है। फोटो सहेजी गई है, सिंक पर जांच होगी।',
      'metrics': {},
    };
  }

  Future<Map<String, dynamic>> assessQuality(
    Uint8List imageBytes, {
    String cameraProfile = 'Generic Fundus Camera',
    String? filename,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/retinal/quality');
      var request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_headers);
      request.fields['camera_profile'] = cameraProfile;
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: (filename != null && filename.isNotEmpty)
              ? filename
              : 'retina.jpg',
        ),
      );

      var streamedResponse = await request.send().timeout(_inferTimeout);
      var response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      // Server rejection (400/401/404/413/422/429): surface it — the UI has
      // an honest error state. Never disguise it as "offline".
      throw Exception(
        'Quality check failed: ${response.statusCode} - ${response.body}',
      );
    } on SocketException {
      return _offlineQualityFallback();
    } on http.ClientException {
      return _offlineQualityFallback();
    } on TimeoutException {
      return _offlineQualityFallback();
    }
  }

  ScreeningResult _offlineScreeningFallback({
    required String localId,
    required String patientId,
    required String eyeSide,
    required String cameraProfile,
  }) {
    // Queue offline for later sync. No DR grade is assigned on-device:
    // drGrade stays null so the UI must show "pending analysis", never a diagnosis.
    return ScreeningResult(
      screeningId: localId,
      patientId: patientId,
      eyeSide: eyeSide,
      cameraProfile: cameraProfile,
      qualityGrade: 'PENDING_SYNC',
      qualityScore: 0.0,
      qualityPassed: false,
      rejectionReasons: const [
        'No connectivity — queued for server-side analysis.',
      ],
      requiresHumanReview: true,
      humanReviewType: 'OPERATOR_LEVEL',
      humanReviewReason:
          'Offline capture. No grade assigned on-device; analysis runs on sync.',
      actionRecommendation:
          'Image stored in Offline Queue. Sync at the PHC to receive the AI grade.',
      patientPlainLanguageSummary:
          'Photo saved. The eye check result will be available after syncing.',
      createdAt: DateTime.now().toIso8601String(),
    );
  }

  /// Server reachable but the clinical DR model is unavailable (HTTP 503).
  /// Explicit state: no grade is produced on-device, ever.
  ScreeningResult _aiUnavailableFallback({
    required String localId,
    required String patientId,
    required String eyeSide,
    required String cameraProfile,
  }) {
    return ScreeningResult(
      screeningId: localId,
      patientId: patientId,
      eyeSide: eyeSide,
      cameraProfile: cameraProfile,
      qualityGrade: 'AI_UNAVAILABLE',
      qualityScore: 0.0,
      qualityPassed: false,
      rejectionReasons: const [
        'AI screening service is unavailable right now. No grade was assigned.',
      ],
      requiresHumanReview: true,
      humanReviewType: 'OPERATOR_LEVEL',
      humanReviewReason: 'Clinical model unavailable; result must be retried.',
      actionRecommendation:
          'Retry once the AI service is back online. Do not record a DR grade for this capture.',
      patientPlainLanguageSummary:
          'The eye check could not run because the screening service is offline. Please try again shortly.',
      createdAt: DateTime.now().toIso8601String(),
      errorCode: 'AI_UNAVAILABLE',
    );
  }

  /// The request exceeded the inference deadline. The server may already be
  /// processing this capture, so it is deliberately NOT queued for sync
  /// (a duplicate row would be created) — the operator simply retries.
  ScreeningResult _aiTimeoutFallback({
    required String localId,
    required String patientId,
    required String eyeSide,
    required String cameraProfile,
  }) {
    return ScreeningResult(
      screeningId: localId,
      patientId: patientId,
      eyeSide: eyeSide,
      cameraProfile: cameraProfile,
      qualityGrade: 'AI_TIMEOUT',
      qualityScore: 0.0,
      qualityPassed: false,
      rejectionReasons: const [
        'AI analysis timed out. No grade was assigned for this capture.',
      ],
      requiresHumanReview: true,
      humanReviewType: 'OPERATOR_LEVEL',
      humanReviewReason: 'Inference timed out; retry the screening.',
      actionRecommendation:
          'Retry the screening on a stable connection. Do not record a DR grade for this capture.',
      patientPlainLanguageSummary:
          'The eye check took too long and was not completed. Please retry.',
      createdAt: DateTime.now().toIso8601String(),
      errorCode: 'AI_TIMEOUT',
    );
  }

  /// Demo-UI wrapper: quality gate returning the intake-flow model.
  /// Delegates to [assessQuality] so server truth is shared.
  Future<ui.RetinalQualityModel> checkQuality({
    required Uint8List imageBytes,
    String filename = 'retina.jpg',
    String cameraProfile = 'Generic Fundus Camera',
  }) async {
    final jsonMap = await assessQuality(
      imageBytes,
      cameraProfile: cameraProfile,
      filename: filename,
    );
    return ui.RetinalQualityModel.fromJson(jsonMap);
  }

  /// Upstream diabetes-risk assessment (POST /diabetes-risk).
  /// Falls back to an on-device heuristic when offline so the intake
  /// badge still renders — clearly marked via pathway.
  Future<ui.DiabetesRiskModel> evaluateDiabetesRisk({
    required int age,
    required String gender,
    required double bmi,
    required bool familyHistory,
    double? knownDiabetesYears,
    double? hba1c,
    double? fastingGlucose,
    String physicalActivity = 'Moderate',
    List<String> symptoms = const [],
    String? patientId,
  }) async {
    final payload = {
      'patient_id': patientId,
      'age': age,
      'gender': gender,
      'bmi': bmi,
      'family_history': familyHistory,
      'physical_activity': physicalActivity,
      'symptoms': symptoms,
      'hba1c': hba1c,
      'fasting_glucose': fastingGlucose,
      'known_diabetes_years': knownDiabetesYears,
    };
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/diabetes-risk'),
            headers: {'Content-Type': 'application/json', ..._headers},
            body: json.encode(payload),
          )
          .timeout(_shortTimeout);
      if (response.statusCode == 200) {
        return ui.DiabetesRiskModel.fromJson(
          json.decode(response.body) as Map<String, dynamic>,
        );
      }
      throw Exception('Risk assessment failed: ${response.statusCode}');
    } on SocketException {
      return _offlineRiskFallback(
        age,
        bmi,
        familyHistory,
        knownDiabetesYears,
        hba1c,
      );
    } on http.ClientException {
      return _offlineRiskFallback(
        age,
        bmi,
        familyHistory,
        knownDiabetesYears,
        hba1c,
      );
    } on TimeoutException {
      return _offlineRiskFallback(
        age,
        bmi,
        familyHistory,
        knownDiabetesYears,
        hba1c,
      );
    } catch (_) {
      // Server rejection (HTTP 500, 401, 422, etc.): fall back to the
      // on-device heuristic so the intake flow degrades gracefully instead
      // of crashing. The risk model's pathway will flag it as OFFLINE_HEURISTIC.
      return _offlineRiskFallback(
        age,
        bmi,
        familyHistory,
        knownDiabetesYears,
        hba1c,
      );
    }
  }

  ui.DiabetesRiskModel _offlineRiskFallback(
    int age,
    double bmi,
    bool familyHistory,
    double? knownDiabetesYears,
    double? hba1c,
  ) {
    // Offline heuristic — never presented as a diagnosis.
    double score = 20;
    if (age >= 45) score += 15;
    if (age >= 60) score += 10;
    if (bmi >= 25) score += 15;
    if (bmi >= 30) score += 10;
    if (familyHistory) score += 10;
    if ((knownDiabetesYears ?? 0) >= 5) score += 15;
    if (hba1c != null && hba1c >= 6.5) score += 20;
    if (score > 100) score = 100;
    final level = score >= 60 ? 'HIGH' : (score >= 35 ? 'MODERATE' : 'LOW');
    return ui.DiabetesRiskModel(
      riskScore: score,
      riskLevel: level,
      pathway: 'OFFLINE_HEURISTIC',
      riskSource: 'heuristic',
      clinicalRationale: const [
        'Offline estimate — confirm with lab HbA1c and server risk engine.',
      ],
      actionRecommendation: level == 'HIGH'
          ? 'Retinal imaging indicated for Diabetic Retinopathy screening.'
          : 'Routine monitoring; repeat screening annually.',
      patientFriendlyGuidance: level == 'HIGH'
          ? 'Some risk factors were noted. An eye check and sugar test are advised.'
          : 'Risk looks low today. Keep up healthy habits and recheck yearly.',
    );
  }

  /// Doctor review queue (GET /review/pending). Returns [] when offline
  /// or on unexpected responses so callers fall back to demo data.
  /// Throws [ReviewAuthException] on 401/403: the endpoint requires a
  /// doctor/admin key, and an operator key must NOT look like an empty queue.
  Future<List<Map<String, dynamic>>> getPendingReviews({
    int limit = 100,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/review/pending?limit=$limit'),
            headers: _headers,
          )
          .timeout(_shortTimeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw ReviewAuthException(
          'Doctor API key required (server: ${response.statusCode}). '
          'Showing demo cases — not live queue data.',
        );
      }
      if (response.statusCode == 200) {
        final body = json.decode(response.body) as Map<String, dynamic>;
        final items = body['items'];
        if (items is List) {
          return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      }
      return [];
    } on ReviewAuthException {
      rethrow;
    } catch (_) {
      return [];
    }
  }

  /// Advisory marker data for one review case (GET
  /// /review/{id}/markers). Simple contract: non-null = parsed markers,
  /// null = unavailable for ANY reason (offline, server error, bad key,
  /// unparseable body). Never throws: this is advisory context and loading
  /// it must never delay or block the doctor's sign-off path.
  Future<RetinalMarkers?> getReviewMarkers(String reviewId) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              '$baseUrl/review/${Uri.encodeComponent(reviewId)}/markers',
            ),
            headers: _headers,
          )
          .timeout(_shortTimeout);
      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        if (body is Map<String, dynamic>) {
          return RetinalMarkers.fromJson(body);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the reviewer-visible fundus image. [imageUrlPath] is the
  /// server-relative path the pending-reviews payload carries (e.g.
  /// `/results/SCR-1/SCR-1_orig.jpg`); an already-absolute http(s) URL is
  /// used as-is. Returns null on any non-200, empty input, timeout or
  /// network error — the viewer renders an honest failure state.
  Future<Uint8List?> fetchReviewImage(String imageUrlPath) async {
    final path = imageUrlPath.trim();
    if (path.isEmpty) return null;
    try {
      final Uri uri;
      if (path.startsWith('http://') || path.startsWith('https://')) {
        uri = Uri.parse(path);
      } else {
        final base = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;
        uri = Uri.parse(path.startsWith('/') ? '$base$path' : '$base/$path');
      }
      final response = await http
          .get(uri, headers: _headers)
          .timeout(_shortTimeout);
      if (response.statusCode == 200) return response.bodyBytes;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Live PHC dashboard feed (GET /screenings): recent screenings with
  /// patient names plus tile counters. Returns null when offline or on
  /// unexpected responses so callers fall back to labeled demo fixtures.
  Future<Map<String, dynamic>?> getDashboardScreenings({int limit = 6}) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/screenings?limit=$limit'), headers: _headers)
          .timeout(_shortTimeout);
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Submits a specialist verdict (POST /review/{id}).
  /// Maps demo-flow 'CONFIRMED' to the backend 'CONFIRM' allowlist.
  Future<Map<String, dynamic>> submitDoctorDecision({
    required String reviewId,
    required String doctorName,
    required String decision,
    String clinicalNotes = '',
    String referralUrgency = 'Within 30 Days',
    int followUpDays = 30,
    int? gradeOverride,
  }) async {
    final normalized = decision.trim().toUpperCase() == 'CONFIRMED'
        ? 'CONFIRM'
        : decision.trim().toUpperCase();
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/review/$reviewId'),
            headers: {'Content-Type': 'application/json', ..._headers},
            body: json.encode({
              'doctor_name': doctorName,
              'decision': normalized,
              'grade_override': gradeOverride,
              'clinical_notes': clinicalNotes,
              'referral_urgency': referralUrgency,
              'follow_up_days': followUpDays,
            }),
          )
          .timeout(_shortTimeout);
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return {'ok': false, 'status': response.statusCode};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<ScreeningResult> analyzeRetina({
    required Uint8List imageBytes,
    required String patientId,
    String eyeSide = 'Right',
    String cameraProfile = 'Generic Fundus Camera',
    String? filename,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/retinal/analyze');
      var request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_headers);
      request.fields['patient_id'] = patientId;
      request.fields['eye_side'] = eyeSide;
      request.fields['camera_profile'] = cameraProfile;
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: (filename != null && filename.isNotEmpty)
              ? filename
              : 'retina.jpg',
        ),
      );

      var streamedResponse = await request.send().timeout(_inferTimeout);
      var response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode == 200) {
        return ScreeningResult.fromJson(json.decode(response.body));
      }
      if (response.statusCode == 503) {
        // Clinical DR model unavailable (fail-closed server side). Never
        // substitute an on-device guess for a missing model.
        return _aiUnavailableFallback(
          localId: 'UNAV-${DateTime.now().millisecondsSinceEpoch}',
          patientId: patientId,
          eyeSide: eyeSide,
          cameraProfile: cameraProfile,
        );
      }
      // Server rejection (unknown patient 404, bad eye_side 422, bad key
      // 401...): surface it, never mislabel as offline.
      throw Exception('Analysis failed: ${response.statusCode}');
    } on SocketException {
      final localId = 'LOC-${DateTime.now().millisecondsSinceEpoch}';
      final entry = {
        'local_screening_id': localId,
        'patient_id': patientId,
        'eye_side': eyeSide,
        'camera_profile': cameraProfile,
        'image_base64': base64Encode(imageBytes),
        'timestamp': DateTime.now().toIso8601String(),
      };
      offlineQueue.add(entry);
      await OfflineQueueService.instance.addScreening(entry);
      return _offlineScreeningFallback(
        localId: localId,
        patientId: patientId,
        eyeSide: eyeSide,
        cameraProfile: cameraProfile,
      );
    } on http.ClientException {
      final localId = 'LOC-${DateTime.now().millisecondsSinceEpoch}';
      final entry = {
        'local_screening_id': localId,
        'patient_id': patientId,
        'eye_side': eyeSide,
        'camera_profile': cameraProfile,
        'image_base64': base64Encode(imageBytes),
        'timestamp': DateTime.now().toIso8601String(),
      };
      offlineQueue.add(entry);
      await OfflineQueueService.instance.addScreening(entry);
      return _offlineScreeningFallback(
        localId: localId,
        patientId: patientId,
        eyeSide: eyeSide,
        cameraProfile: cameraProfile,
      );
    } on TimeoutException {
      // Deliberately NOT queued: the server may already be processing this
      // capture, and syncing it again would create a duplicate screening.
      return _aiTimeoutFallback(
        localId: 'TMO-${DateTime.now().millisecondsSinceEpoch}',
        patientId: patientId,
        eyeSide: eyeSide,
        cameraProfile: cameraProfile,
      );
    }
  }

  /// Full intake-flow analysis returning the demo-UI model
  /// ([ui.ScreeningAnalysisModel]) with SMS slip + biomarker map.
  /// Shares the same endpoint/offline queue as [analyzeRetina].
  Future<ui.ScreeningAnalysisModel> analyzeRetinaFull({
    required Uint8List imageBytes,
    required String patientId,
    String eyeSide = 'Right',
    String cameraProfile = 'Generic Fundus Camera',
    String? filename,
  }) async {
    try {
      final result = await analyzeRetina(
        imageBytes: imageBytes,
        patientId: patientId,
        eyeSide: eyeSide,
        cameraProfile: cameraProfile,
        filename: filename,
      );
      final grade = result.drGrade;
      final isOffline = result.qualityGrade == 'PENDING_SYNC';
      // A terminal error code means no result exists: the payload must be
      // rendered as a failure/uncertain state, never as clinical metrics.
      final hasErrorCode = result.errorCode != null;
      final isFromFallback =
          hasErrorCode ||
          result.modelBackend == 'simulated' ||
          result.microaneurysmCount == null ||
          result.vesselDensityPct == null ||
          result.csmeRisk == null ||
          result.predictionScore == null ||
          result.isReferable == null;
      return ui.ScreeningAnalysisModel(
        screeningId: result.screeningId,
        patientId: result.patientId,
        eyeSide: result.eyeSide,
        cameraProfile: result.cameraProfile,
        qualityGrade: result.qualityGrade,
        qualityScore: result.qualityScore,
        qualityPassed: result.qualityPassed,
        rejectionReasons: result.rejectionReasons,
        drGrade: result.drGrade,
        drLabel: result.drLabel,
        predictionScore: result.predictionScore,
        isReferable: result.isReferable,
        requiresHumanReview: result.requiresHumanReview,
        humanReviewType: result.humanReviewType,
        humanReviewReason: result.humanReviewReason,
        originalImageUrl: result.originalImageUrl ?? '',
        gradcamOverlayUrl: result.gradcamOverlayUrl,
        gradcamTargetLayer: result.gradcamTargetLayer,
        modelBackend: result.modelBackend,
        actionRecommendation: result.actionRecommendation,
        plainLanguageAdvice: result.patientPlainLanguageSummary,
        smsReferralSlip: hasErrorCode
            ? 'DRISHTI: no result assigned (${result.errorCode}). '
                  '${result.actionRecommendation} Screening:${result.screeningId}'
            : 'DRISHTI: ${result.drLabel ?? 'Screening complete'} (Grade ${grade ?? '-'}). '
                  '${result.actionRecommendation} Screening:${result.screeningId}',
        biomarkers: {
          'microaneurysm_count': result.microaneurysmCount,
          'vessel_density_pct': result.vesselDensityPct,
          'csme_risk': result.csmeRisk,
          'min_fovea_distance_px': result.minFoveaDistancePx,
        },
        criteriaEvaluation: result.criteriaEvaluation,
        gradingPolicy: result.gradingPolicy,
        disagreement: result.disagreement,
        isOffline: isOffline,
        isFromFallback: isFromFallback,
        errorCode: result.errorCode,
      );
    } catch (e) {
      // analyzeRetina only throws on server rejection — surface it.
      // Offline queueing already returned a fallback inside analyzeRetina.
      rethrow;
    }
  }

  Future<Map<String, dynamic>> syncOfflineBatch() async {
    if (offlineQueue.isEmpty && offlinePatients.isEmpty) {
      return {
        'total_received': 0,
        'total_synced': 0,
        'failed_items': [],
        'message': 'No offline screenings queued.',
      };
    }

    // 1. Register queued patients first — /sync rejects unknown patient_ids.
    int patientsSynced = 0;
    final failedPatients = <Map<String, dynamic>>[];
    for (final p in List<Map<String, dynamic>>.of(offlinePatients)) {
      try {
        await _postPatient(p, queueOnOffline: false);
        offlinePatients.remove(p);
        await OfflineQueueService.instance.removePatient('${p['patient_id']}');
        patientsSynced++;
      } catch (e) {
        failedPatients.add({
          'patient_id': p['patient_id'],
          'error': e.toString(),
        });
      }
    }

    // 2. Drop corrupt queue entries locally (backend would 422 them; keeping
    // them would block the queue forever). Counted, never silent.
    int droppedCorrupt = 0;
    final items = <Map<String, dynamic>>[];
    for (final item in List<Map<String, dynamic>>.of(offlineQueue)) {
      final b64 = (item['image_base64'] ?? '').toString();
      final lid = (item['local_screening_id'] ?? '').toString();
      final pid = (item['patient_id'] ?? '').toString();
      if (b64.isEmpty || lid.isEmpty || pid.isEmpty) {
        offlineQueue.remove(item);
        await OfflineQueueService.instance.removeScreening(lid);
        droppedCorrupt++;
        continue;
      }
      items.add({
        'local_screening_id': lid,
        'patient_id': pid,
        'eye_side': (item['eye_side'] ?? 'Right').toString(),
        'camera_profile': (item['camera_profile'] ?? 'Generic Fundus Camera')
            .toString(),
        'image_base64': b64,
        'timestamp': (item['timestamp'] ?? item['captured_at'] ?? '')
            .toString(),
      });
    }

    if (items.isEmpty) {
      return {
        'total_received': 0,
        'total_synced': 0,
        'failed_items': [],
        'patients_synced': patientsSynced,
        'failed_patients': failedPatients,
        'dropped_corrupt': droppedCorrupt,
        'message': droppedCorrupt > 0
            ? 'No valid images to sync; $droppedCorrupt corrupt queue entr(y/ies) discarded.'
            : 'No valid images to sync.',
      };
    }

    // 3. POST /sync in backend-accepted chunks (max 5 per request:
    // each item costs a full multi-second inference server-side).
    int totalReceived = 0;
    int totalSynced = 0;
    final failedItems = <dynamic>[];
    final syncedIds = <String>{};
    try {
      for (var i = 0; i < items.length; i += 5) {
        final chunk = items.sublist(
          i,
          i + 5 > items.length ? items.length : i + 5,
        );
        final payload = {
          'screening_centre': 'PHC Shirur Sub-Centre',
          'operator_name': 'ASHA Sunita Bai',
          'screenings': chunk,
        };
        final response = await http
            .post(
              Uri.parse('$baseUrl/sync'),
              headers: {'Content-Type': 'application/json', ..._headers},
              body: json.encode(payload),
            )
            .timeout(_syncTimeout);
        if (response.statusCode != 200) {
          throw Exception('Sync error: ${response.statusCode}');
        }
        final result = json.decode(response.body) as Map<String, dynamic>;
        totalReceived += (result['total_received'] as num?)?.toInt() ?? 0;
        totalSynced += (result['total_synced'] as num?)?.toInt() ?? 0;
        final chunkFailed = result['failed_items'];
        if (chunkFailed is List) failedItems.addAll(chunkFailed);
        final chunkSynced = result['synced_screening_ids'];
        if (chunkSynced is List) {
          syncedIds.addAll(chunkSynced.map((e) => e.toString()));
        }
      }
      // Remove ONLY server-confirmed items — failed items stay queued.
      final syncedSet = syncedIds;
      offlineQueue.removeWhere(
        (q) => syncedSet.contains('${q['local_screening_id']}'),
      );
      await OfflineQueueService.instance.removeSyncedScreenings(syncedSet);
      return {
        'total_received': totalReceived,
        'total_synced': totalSynced,
        'failed_items': failedItems,
        'patients_synced': patientsSynced,
        'failed_patients': failedPatients,
        'dropped_corrupt': droppedCorrupt,
      };
    } on SocketException catch (e) {
      return {
        'error': 'Still offline — nothing uploaded. $e',
        'total_received': 0,
        'total_synced': 0,
        'failed_items': failedItems,
        'patients_synced': patientsSynced,
        'failed_patients': failedPatients,
        'dropped_corrupt': droppedCorrupt,
      };
    } on http.ClientException catch (e) {
      return {
        'error': 'Connection failed — nothing uploaded. $e',
        'total_received': 0,
        'total_synced': 0,
        'failed_items': failedItems,
        'patients_synced': patientsSynced,
        'failed_patients': failedPatients,
        'dropped_corrupt': droppedCorrupt,
      };
    } on TimeoutException catch (e) {
      return {
        'error': 'Sync timed out — retry at the PHC. $e',
        'total_received': totalReceived,
        'total_synced': totalSynced,
        'failed_items': failedItems,
        'patients_synced': patientsSynced,
        'failed_patients': failedPatients,
        'dropped_corrupt': droppedCorrupt,
      };
    }
  }
}
