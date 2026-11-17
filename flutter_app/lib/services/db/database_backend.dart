import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

/// Selects the correct SQLite engine for the host operating system.
///
/// `sqflite_sqlcipher` ships SQLCipher natives for Android, iOS and macOS.
/// Windows and Linux have no SQLCipher implementation, which previously made
/// the entire database tier fail silently on those platforms and left only the
/// in-memory/JSON tiers active. `sqflite_common_ffi` supplies a native SQLite
/// engine for desktop so the same `LocalStore` schema, queries and migrations
/// run on every OS.
///
/// Encryption is used where the platform provides a native SQLCipher build;
/// desktop stores rely on the OS user-profile boundary (the existing
/// SharedPreferences/JSON tiers are already device-local). Callers can expose
/// [supportsEncryption] in diagnostics instead of assuming parity.
class DatabaseBackend {
  DatabaseBackend._();

  static bool _ffiInitialized = false;

  /// True when the host can open a password-protected SQLCipher database.
  static bool get supportsEncryption =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// Opens a database using the native engine for this platform.
  ///
  /// [password] is honoured only when [supportsEncryption] is true. On desktop
  /// the same schema is opened through SQLite FFI.
  static Future<Database> open({
    required String path,
    required int version,
    String? password,
    OnDatabaseConfigureFn? onConfigure,
    OnDatabaseCreateFn? onCreate,
    OnDatabaseVersionChangeFn? onUpgrade,
    OnDatabaseVersionChangeFn? onDowngrade,
    bool readOnly = false,
    bool singleInstance = true,
  }) async {
    if (supportsEncryption) {
      return cipher.databaseFactory.openDatabase(
        path,
        options: cipher.SqlCipherOpenDatabaseOptions(
          version: version,
          password: password,
          onConfigure: onConfigure,
          onCreate: onCreate,
          onUpgrade: onUpgrade,
          onDowngrade: onDowngrade,
          readOnly: readOnly,
          singleInstance: singleInstance,
        ),
      );
    }

    if (!_ffiInitialized) {
      ffi.sqfliteFfiInit();
      _ffiInitialized = true;
    }
    return ffi.databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: onConfigure,
        onCreate: onCreate,
        onUpgrade: onUpgrade,
        onDowngrade: onDowngrade,
        readOnly: readOnly,
        singleInstance: singleInstance,
      ),
    );
  }

  /// Default on-disk location used by the offline queue.
  ///
  /// Mobile/macOS keep the historical `sqflite` databases directory so
  /// existing queues are not orphaned by this change. Desktop uses the
  /// application-support container (no `sqflite` databases path exists there).
  static Future<String> queueDatabaseDirectory() async {
    if (supportsEncryption) {
      return cipher.getDatabasesPath();
    }
    final support = await _applicationSupportDirectory();
    return support.path;
  }

  static Future<Directory> _applicationSupportDirectory() async {
    // Imported lazily to keep this file free of UI dependencies.
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
