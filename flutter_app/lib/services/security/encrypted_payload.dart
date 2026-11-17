import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'device_key_store.dart';

/// AES-256-GCM envelope for the local JSON cache and filesystem backup.
///
/// The database is SQLCipher on Apple/mobile and the app-support container is
/// OS-protected on desktop; this codec ensures the secondary persistence tiers
/// never store patient-identifiable JSON in plaintext (the previous behaviour
/// of SharedPreferences and `drishti_screenings_backup.json`).
class EncryptedPayload {
  EncryptedPayload._();

  static const String _prefix = 'DENC1:';
  static final AesGcm _algorithm = AesGcm.with256bits();
  static SecretKey? _key;

  static bool isEncrypted(String value) => value.startsWith(_prefix);

  static Future<String> encrypt(String plaintext) async {
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: await _secretKey(),
      nonce: nonce,
    );
    final combined = <int>[
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
    return '$_prefix${base64UrlEncode(combined)}';
  }

  /// Returns null when the envelope is malformed or the device key changed.
  static Future<String?> decrypt(String payload) async {
    if (!isEncrypted(payload)) return null;
    try {
      final combined = base64Url.decode(payload.substring(_prefix.length));
      if (combined.length < 12 + 16) return null;
      final nonce = combined.sublist(0, 12);
      final mac = Mac(combined.sublist(combined.length - 16));
      final cipherText = combined.sublist(12, combined.length - 16);
      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: await _secretKey(),
      );
      return utf8.decode(clear);
    } catch (e) {
      debugPrint('Encrypted payload could not be opened: $e');
      return null;
    }
  }

  /// Decrypts an encrypted envelope and transparently accepts legacy plaintext
  /// payloads so existing installs migrate on the next write.
  static Future<String?> readOrLegacy(String payload) async {
    if (!isEncrypted(payload)) return payload;
    return decrypt(payload);
  }

  static Future<SecretKey> _secretKey() async {
    final cached = _key;
    if (cached != null) return cached;
    final password = await DeviceKeyStore.instance.password();
    final digest = await Sha256().hash(utf8.encode('drishti-payload-v1:$password'));
    final key = SecretKey(digest.bytes);
    _key = key;
    return key;
  }
}
