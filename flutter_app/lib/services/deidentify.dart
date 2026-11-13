import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;

/// Client-side de-identification module (Ticket C-2, mirrored by
/// src/reporting/deidentify.py on the server half of /sync/v2).
///
/// Contract (docs/PRIVACY.md + DPDP S.6/S.8):
///   - pseudonym: keyed HMAC-SHA256 with a per-device salt that NEVER
///     leaves the device; the mapping is one-way and stable per device.
///   - image: decoded + downscaled + re-encoded, which strips ALL EXIF
///     metadata (GPS, serials, timestamps) by construction.
///   - never transmit: name, phone, ABHA, village. [lintPayload] enforces
///     the whitelist client-side; the server re-checks fail-closed.
class DeidentificationService {
  const DeidentificationService({required this.deviceSalt});

  static const _saltKey = 'netra_deid_device_salt';

  /// App factory: loads (or creates) the device salt from secure storage.
  /// Falls back to a non-persistent salt ONLY when the platform channel is
  /// unavailable (tests/desktop) — the pseudonyms stay self-consistent for
  /// the process lifetime, which is all the referral flow needs in-session.
  static Future<DeidentificationService> fromDevice() async {
    final storage = const FlutterSecureStorage();
    try {
      final existing = await storage.read(key: _saltKey);
      if (existing != null && existing.isNotEmpty) {
        return DeidentificationService(deviceSalt: existing);
      }
      final generated =
          DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
          Object().hashCode.toRadixString(36);
      await storage.write(key: _saltKey, value: generated);
      return DeidentificationService(deviceSalt: generated);
    } catch (_) {
      return DeidentificationService(
        deviceSalt:
            'ephemeral-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      );
    }
  }

  static const referralPayloadWhitelist = {
    'pseudonym',
    'pseudo_screening_id',
    'age_band',
    'gender',
    'eye_side',
    'dr_grade',
    'dr_label',
    'probabilities',
    'confidence',
    'requires_human_review',
    'image_base64',
    'consent_version',
    'captured_at',
  };

  static const _phiFieldHints = {
    'name',
    'patient_name',
    'phone',
    'phone_number',
    'abha',
    'abha_id',
    'aadhaar',
    'village',
    'address',
    'patient_id',
    'screening_id',
  };

  /// Per-device salt. Injected so tests are deterministic; in the app it is
  /// generated once and stored in flutter_secure_storage (Keystore).
  final String deviceSalt;

  /// Stable one-way pseudonym: 'RSV-<8 hex>' derived from
  /// HMAC-SHA256(salt, localPatientId). Same patient maps to the same
  /// pseudonym on this device; different devices map differently.
  String pseudonym(String localPatientId) {
    final key = utf8.encode(deviceSalt);
    final msg = utf8.encode('patient:$localPatientId');
    final digest = Hmac(sha256, key).convert(msg);
    return 'RSV-${digest.toString().substring(0, 8).toUpperCase()}';
  }

  /// Stable one-way pseudonym for a screening capture.
  String pseudonymizeScreening(String localScreeningId) {
    final key = utf8.encode(deviceSalt);
    final msg = utf8.encode('screening:$localScreeningId');
    final digest = Hmac(sha256, key).convert(msg);
    return 'SCR-${digest.toString().substring(0, 8).toUpperCase()}';
  }

  /// Coarse age band (a 43-year-old and a 44-year-old are not
  /// distinguishable in the payload — data minimization).
  String? ageBand(int? age) {
    if (age == null || age < 0 || age > 120) return null;
    final low = (age ~/ 10) * 10;
    return '$low-${low + 9}';
  }

  /// De-identified image: downscaled to <=[maxDim] on the longest side and
  /// re-encoded JPEG at [quality]. Re-encoding drops EXIF/GPS metadata and
  /// shrinks the 2G payload (~200 KB target per the plan).
  ///
  /// Fail closed: ANY decode failure (null, truncated, RangeError inside
  /// the decoder) throws FormatException — never a partial payload.
  Uint8List deidentifyImage(
    Uint8List jpegBytes, {
    int maxDim = 512,
    int quality = 80,
  }) {
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(jpegBytes);
    } on FormatException {
      rethrow;
    } catch (_) {
      // package:image can throw RangeError on truncated streams.
      throw const FormatException('Could not decode image');
    }
    if (decoded == null) {
      throw const FormatException('Could not decode image');
    }
    final longest = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;
    var image = decoded;
    if (longest > maxDim) {
      final scale = maxDim / longest;
      image = img.copyResize(
        decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
    }
    final encoded = img.encodeJpg(image, quality: quality);
    return Uint8List.fromList(encoded);
  }

  /// Client-side PHI linter: returns every key of [payload] that is NOT in
  /// the referral whitelist (or that matches a known PHI hint). The caller
  /// must DROP the payload when this returns non-empty — fail closed, the
  /// same rule the server applies.
  List<String> lintPayload(Map<String, dynamic> payload) {
    final violations = <String>[];
    payload.forEach((key, _) {
      final k = key.toLowerCase();
      if (!referralPayloadWhitelist.contains(k) || _phiFieldHints.contains(k)) {
        violations.add(key);
      }
    });
    return violations;
  }
}
