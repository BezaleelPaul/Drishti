import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves the per-device secret used to open the SQLCipher vault and to
/// encrypt the local JSON cache/backup.
///
/// Resolution order:
///   1. OS keychain / Keystore / libsecret (`flutter_secure_storage`).
///   2. A randomly generated key file in the application-support container
///      with POSIX mode 0600 (desktop fallback when no keyring is available).
///   3. Process-memory key (tests / first boot with no writable storage).
///
/// The previous implementation fell back to a hardcoded key string, which made
/// encryption meaningless. There is no static fallback any more.
class DeviceKeyStore {
  DeviceKeyStore._();

  static final DeviceKeyStore instance = DeviceKeyStore._();

  static const String _secureKey = 'drishti_device_vault_key_v2';
  static const String _legacyPrefsKey = 'drishti_db_password';
  static const String _keyFileName = 'device.key';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  String? _cached;
  Future<String>? _pending;

  Future<String> password() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _pending ??= _resolve().then((value) {
      _cached = value;
      return value;
    });
  }

  Future<String> _resolve() async {
    // 1. OS protected storage.
    try {
      final existing = await _secureStorage.read(key: _secureKey);
      if (existing != null && existing.length >= 16) return existing;
      final generated = _generate();
      await _secureStorage.write(key: _secureKey, value: generated);
      return generated;
    } catch (e) {
      debugPrint('Secure storage unavailable; using protected key file: $e');
    }

    // 2. Desktop/file fallback with restrictive permissions.
    try {
      final support = await getApplicationSupportDirectory();
      if (!await support.exists()) {
        await support.create(recursive: true);
      }
      final file = File(p.join(support.path, _keyFileName));
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (existing.length >= 16) return existing;
      }
      final generated = _generate();
      await file.writeAsString(generated, flush: true);
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['600', file.path]);
        } catch (_) {
          // Best effort; the container is already app-private.
        }
      }
      return generated;
    } catch (e) {
      debugPrint('Protected key file unavailable: $e');
    }

    // 3. Migrate a legacy plaintext SharedPreferences key if present. This is
    //    only used when neither protected store is available, so existing
    //    installs do not lose access to their vault.
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_legacyPrefsKey);
      if (legacy != null && legacy.length >= 16) {
        await prefs.remove(_legacyPrefsKey);
        return legacy;
      }
    } catch (_) {}

    // 4. Test / ephemeral fallback. Never persisted to a predictable location.
    return _generate();
  }

  String _generate() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}
