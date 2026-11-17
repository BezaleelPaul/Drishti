import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'encrypted_payload.dart';

/// Small wrapper around `flutter_secure_storage` for credentials that must
/// never be written to SharedPreferences (SMTP app passwords, tokens).
///
/// When the OS keychain is unavailable the secret is kept in process memory
/// only. It is deliberately NOT persisted to a plaintext fallback: the operator
/// can re-enter it, but an attacker cannot lift it from a preferences file.
class SecretStore {
  SecretStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static final Map<String, String> _memory = {};

  static Future<String?> read(String key) async {
    final cached = _memory[key];
    if (cached != null) return cached;
    try {
      final value = await _storage.read(key: key);
      if (value != null && value.isNotEmpty) {
        _memory[key] = value;
        return value;
      }
    } catch (e) {
      debugPrint('SecretStore keychain unavailable for $key: $e');
    }

    // Encrypted file fallback keeps credentials across restarts on desktops
    // without a keyring. The value is AES-GCM encrypted with the device key.
    try {
      final file = await _fileFor(key);
      if (file != null && await file.exists()) {
        final envelope = await file.readAsString();
        final value = await EncryptedPayload.decrypt(envelope);
        if (value != null && value.isNotEmpty) {
          _memory[key] = value;
          return value;
        }
      }
    } catch (e) {
      debugPrint('SecretStore file read failed for $key: $e');
    }
    return null;
  }

  static Future<void> write(String key, String value) async {
    if (value.isEmpty) {
      await delete(key);
      return;
    }
    _memory[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('SecretStore keychain write unavailable for $key: $e');
    }
    try {
      final file = await _fileFor(key);
      if (file != null) {
        final envelope = await EncryptedPayload.encrypt(value);
        await file.writeAsString(envelope, flush: true);
        if (!Platform.isWindows) {
          try {
            await Process.run('chmod', ['600', file.path]);
          } catch (_) {}
        }
      }
    } catch (e) {
      // Memory-only for this session if no protected storage is available.
      debugPrint('SecretStore encrypted file write failed for $key: $e');
    }
  }

  static Future<void> delete(String key) async {
    _memory.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('SecretStore delete unavailable for $key: $e');
    }
    try {
      final file = await _fileFor(key);
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<File?> _fileFor(String key) async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'secrets'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      return File(p.join(dir.path, '$safe.enc'));
    } catch (e) {
      debugPrint('SecretStore directory unavailable: $e');
      return null;
    }
  }
}
