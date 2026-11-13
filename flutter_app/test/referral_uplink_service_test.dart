import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netra_ai_mobile/services/consent_service.dart';
import 'package:netra_ai_mobile/services/deidentify.dart';
import 'package:netra_ai_mobile/services/offline_queue_service.dart';
import 'package:netra_ai_mobile/services/referral_uplink_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const deid = DeidentificationService(deviceSalt: 'test-salt');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    return OfflineQueueService.init(persistence: MemoryQueuePersistence());
  });

  ReferralUplinkService serviceWith(MockClientHandler handler) {
    return ReferralUplinkService(deid: deid, httpClient: MockClient(handler));
  }

  Future<void> grantConsent(String patientId) async {
    await ConsentService().grant(patientId);
  }

  test('refuses to build WITHOUT consent (fail closed)', () async {
    final service = serviceWith((_) async => http.Response('{"ok":1}', 200));
    final result = await service.buildPayload(
      localPatientId: 'PAT-1',
      patientAge: 43,
      patientGender: 'F',
      eyeSide: 'Right',
      localScreeningId: 'LOC-1',
      drGrade: 2,
      drLabel: 'Moderate NPDR',
      confidence: 0.7,
      requiresHumanReview: true,
      consentLanguage: 'en',
    );
    expect(result.isOk, isFalse);
    expect(result.refusal, ReferralBuildRefusal.noConsent);
    expect(result.payload, isNull);
  });

  test('refuses after WITHDRAWN consent', () async {
    await grantConsent('PAT-1');
    await ConsentService().withdraw('PAT-1');
    final service = serviceWith((_) async => http.Response('{"ok":1}', 200));
    final result = await service.buildPayload(
      localPatientId: 'PAT-1',
      patientAge: 43,
      patientGender: 'F',
      eyeSide: 'Right',
      localScreeningId: 'LOC-1',
      drGrade: 2,
      drLabel: 'Moderate NPDR',
      confidence: 0.7,
      requiresHumanReview: true,
      consentLanguage: 'en',
    );
    expect(result.refusal, ReferralBuildRefusal.noConsent);
  });

  test('happy path: payload is de-identified, minimal, lint-clean', () async {
    await grantConsent('PAT-1');
    final service = serviceWith((_) async => http.Response('{"ok":1}', 200));
    final result = await service.buildPayload(
      localPatientId: 'PAT-1',
      patientAge: 43,
      patientGender: 'F',
      eyeSide: 'Right',
      localScreeningId: 'LOC-1',
      drGrade: 2,
      drLabel: 'Moderate NPDR',
      confidence: 0.7,
      requiresHumanReview: true,
      consentLanguage: 'en',
    );

    expect(result.isOk, isTrue);
    final payload = result.payload!;
    // The pseudonym is keyed to the patient on this device.
    expect(payload['pseudonym'], deid.pseudonym('PAT-1'));
    expect(payload['pseudo_screening_id'], deid.pseudonymizeScreening('LOC-1'));
    expect(payload['age_band'], '40-49');
    expect(payload['consent_version'], ConsentService.consentVersion);
    // Nulls dropped; no PHI-bearing keys anywhere.
    expect(payload.containsKey('name'), isFalse);
    expect(payload.containsKey('phone'), isFalse);
    expect(payload.containsKey('village'), isFalse);
    expect(payload['image_base64'], isNull); // no image supplied -> no key
    expect(payload.keys.any((k) => k.startsWith('patient')), isFalse);
  });

  test(
    'image is de-identified into the payload (downscaled, re-encoded)',
    () async {
      await grantConsent('PAT-1');
      final service = serviceWith((_) async => http.Response('{"ok":1}', 200));

      // 1024px source image.
      final big = deidJpeg(1024);
      final result = await service.buildPayload(
        localPatientId: 'PAT-1',
        patientAge: 43,
        patientGender: 'F',
        eyeSide: 'Left',
        localScreeningId: 'LOC-2',
        drGrade: 3,
        drLabel: 'Severe NPDR',
        confidence: 0.8,
        requiresHumanReview: true,
        consentLanguage: 'en',
        imageBytes: big,
      );

      expect(result.isOk, isTrue);
      final b64 = result.payload!['image_base64'] as String;
      final decoded = Uint8List.fromList(base64Decode(b64));
      expect(decoded.length, lessThan(big.length)); // downscaled
      expect(decoded[0], 0xFF); // still JPEG
      expect(decoded[1], 0xD8);
    },
  );

  test(
    'upload posts to /sync/v2 with the API key and reports uploaded',
    () async {
      await grantConsent('PAT-1');
      String? capturedPath;
      String? capturedAuth;
      final service = serviceWith((request) async {
        capturedPath = request.url.path;
        capturedAuth = request.headers['X-API-Key'];
        return http.Response(
          jsonEncode({
            'total_received': 1,
            'total_synced': 1,
            'synced_pseudo_ids': ['SCR-X'],
            'failed_items': [],
          }),
          200,
        );
      });

      final build = await service.buildPayload(
        localPatientId: 'PAT-1',
        patientAge: 43,
        patientGender: 'F',
        eyeSide: 'Right',
        localScreeningId: 'LOC-1',
        drGrade: 2,
        drLabel: 'Moderate NPDR',
        confidence: 0.7,
        requiresHumanReview: true,
        consentLanguage: 'en',
      );
      final result = await service.upload(build.payload!);

      expect(capturedPath, '/sync/v2');
      expect(capturedAuth, isNotNull);
      expect(result.outcome, ReferralOutcome.uploaded);
    },
  );

  test('network failure queues durably; flush uploads and drains', () async {
    await grantConsent('PAT-1');

    // First: offline client -> payload queued.
    final offline = serviceWith((_) async => throw Exception('offline'));
    final build = await offline.buildPayload(
      localPatientId: 'PAT-1',
      patientAge: 43,
      patientGender: 'F',
      eyeSide: 'Right',
      localScreeningId: 'LOC-1',
      drGrade: 2,
      drLabel: 'Moderate NPDR',
      confidence: 0.7,
      requiresHumanReview: true,
      consentLanguage: 'en',
    );
    final r1 = await offline.upload(build.payload!);
    expect(r1.outcome, ReferralOutcome.queued);

    var queuedBefore = await OfflineQueueService.instance.restoreKind(
      OfflineQueueService.kindDeidReferral,
    );
    expect(queuedBefore, hasLength(1));

    // Then: connectivity returns -> flush drains the queue.
    final online = serviceWith(
      (_) async => http.Response(
        jsonEncode({
          'total_received': 1,
          'total_synced': 1,
          'synced_pseudo_ids': ['x'],
          'failed_items': [],
        }),
        200,
      ),
    );
    final flush = await online.flushQueued();
    expect(flush.uploaded, 1);
    expect(flush.stillQueued, 0);

    queuedBefore = await OfflineQueueService.instance.restoreKind(
      OfflineQueueService.kindDeidReferral,
    );
    expect(queuedBefore, isEmpty);
  });

  test(
    'server PHI rejection (422) is reported, never queued for retry',
    () async {
      await grantConsent('PAT-1');
      final service = serviceWith(
        (_) async => http.Response(
          jsonEncode({
            'detail': {
              'error': 'PHI_REJECTED',
              'violations': ['PATTERN:MOBILE'],
            },
          }),
          422,
        ),
      );

      final build = await service.buildPayload(
        localPatientId: 'PAT-1',
        patientAge: 43,
        patientGender: 'F',
        eyeSide: 'Right',
        localScreeningId: 'LOC-1',
        drGrade: 2,
        drLabel: 'Moderate NPDR',
        confidence: 0.7,
        requiresHumanReview: true,
        consentLanguage: 'en',
      );
      final result = await service.upload(build.payload!);
      expect(result.outcome, ReferralOutcome.rejected);

      final queued = await OfflineQueueService.instance.restoreKind(
        OfflineQueueService.kindDeidReferral,
      );
      expect(queued, isEmpty); // not queued — retrying would replay a violation
    },
  );
}

/// Helper: encode a JPEG of the given longest-side size via the deid image
/// pipeline itself (keeps the test dependency-free).
Uint8List deidJpeg(int size) {
  // Minimal valid JPEG via package:image through the service's own
  // deidentifyImage: build a source at 2x the target then downscale.
  final pixels = Uint8List(size * size * 3);
  for (var i = 0; i < pixels.length; i += 3) {
    pixels[i] = 150;
    pixels[i + 1] = 40;
    pixels[i + 2] = 40;
  }
  // Encode raw pixels as a BMP (package:image supports it losslessly),
  // then let deidentifyImage re-encode as JPEG.
  final bmp = encodeBmp(pixels, size, size);
  const deid = DeidentificationService(deviceSalt: 'test-salt');
  return deid.deidentifyImage(bmp, maxDim: size, quality: 90);
}

Uint8List encodeBmp(Uint8List rgb, int width, int height) {
  // BMP 24-bit, bottom-up.
  final rowSize = (width * 3 + 3) & ~3;
  final dataSize = rowSize * height;
  final fileSize = 54 + dataSize;
  final out = Uint8List(fileSize);
  ByteData.view(out.buffer)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, fileSize, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little)
    ..setUint32(34, dataSize, Endian.little);
  var p = 54;
  for (var y = height - 1; y >= 0; y--) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 3;
      out[p++] = rgb[i + 2]; // B
      out[p++] = rgb[i + 1]; // G
      out[p++] = rgb[i]; // R
    }
    p = 54 + (height - 1 - y + 1) * rowSize;
  }
  return out;
}
