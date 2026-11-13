import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Persistence contract for the offline screening queue (Ticket B-2).
/// Implementations must be kill-safe: every mutation is durable on return.
abstract class QueuePersistence {
  Future<void> put(String kind, String id, Map<String, dynamic> payload);
  Future<List<QueueEntry>> all();
  Future<void> delete(String kind, String id);
  Future<void> deleteMany(String kind, Iterable<String> ids);
}

class QueueEntry {
  const QueueEntry({
    required this.kind,
    required this.id,
    required this.payload,
  });
  final String kind;
  final String id;
  final Map<String, dynamic> payload;
}

/// In-memory fallback (pre-init buffering and unit tests). NOT kill-safe —
/// the service reports [OfflineQueueService.isPersisted] so the UI can show
/// an honest banner when durability is unavailable.
class MemoryQueuePersistence implements QueuePersistence {
  static const _sep = '\u001f'; // ASCII unit separator: never in ids
  final Map<String, Map<String, dynamic>> _store = {};

  String _key(String kind, String id) => '$kind$_sep$id';

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> payload) async {
    _store[_key(kind, id)] = Map<String, dynamic>.from(payload);
  }

  @override
  Future<List<QueueEntry>> all() async {
    final out = <QueueEntry>[];
    _store.forEach((k, v) {
      final i = k.indexOf(_sep);
      if (i < 0) return; // defensive: never crash on a malformed key
      out.add(
        QueueEntry(kind: k.substring(0, i), id: k.substring(i + 1), payload: v),
      );
    });
    return out;
  }

  @override
  Future<void> delete(String kind, String id) async {
    _store.remove(_key(kind, id));
  }

  @override
  Future<void> deleteMany(String kind, Iterable<String> ids) async {
    for (final id in ids) {
      _store.remove(_key(kind, id));
    }
  }
}

/// SQLCipher-backed persistence: the queue (including image payloads)
/// survives process kills and restarts. The DB key never leaves the device
/// (Android Keystore via flutter_secure_storage).
class SqliteQueuePersistence implements QueuePersistence {
  SqliteQueuePersistence._(this._db);

  static const _dbName = 'netra_queue.db';
  final Database _db;

  static Future<SqliteQueuePersistence> open(String password) async {
    final db = await openDatabase(
      _dbName,
      password: password,
      version: 1,
      onConfigure: (d) async {
        await d.execute('PRAGMA journal_mode=WAL');
        await d.execute('PRAGMA synchronous=NORMAL');
        await d.execute('PRAGMA busy_timeout=30000');
      },
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE queue (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (kind, id)
          )
        ''');
      },
    );
    return SqliteQueuePersistence._(db);
  }

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> payload) async {
    await _db.insert('queue', {
      'kind': kind,
      'id': id,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<QueueEntry>> all() async {
    final rows = await _db.query('queue', orderBy: 'created_at');
    return rows
        .map(
          (r) => QueueEntry(
            kind: r['kind'] as String,
            id: r['id'] as String,
            payload: jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  @override
  Future<void> delete(String kind, String id) async {
    await _db.delete(
      'queue',
      where: 'kind = ? AND id = ?',
      whereArgs: [kind, id],
    );
  }

  @override
  Future<void> deleteMany(String kind, Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    // Parameterized IN clause in chunks (SQLite default 999 host params).
    for (var i = 0; i < list.length; i += 100) {
      final chunk = list.sublist(
        i,
        i + 100 > list.length ? list.length : i + 100,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _db.delete(
        'queue',
        where: 'kind = ? AND id IN ($placeholders)',
        whereArgs: [kind, ...chunk],
      );
    }
  }
}

/// Write-through offline queue. The in-memory lists on ApiService stay the
/// hot path (existing screens keep working); every mutation is mirrored to
/// [QueuePersistence] and rehydrated at app start, so field-camp captures
/// survive process kills (the B-2 kill/restart invariant).
class OfflineQueueService {
  OfflineQueueService._(this._persistence);

  static OfflineQueueService? _instance;
  static OfflineQueueService get instance =>
      _instance ??= OfflineQueueService._(MemoryQueuePersistence());

  final QueuePersistence _persistence;
  bool isPersisted = false;

  /// Kind tags for the queue families.
  static const kindScreening = 'screening';
  static const kindPatient = 'patient';

  /// Store-and-forward kind for consented de-identified referral payloads
  /// (Ticket D-2): persisted when the doctor console is unreachable, flushed
  /// by the next successful connectivity window.
  static const kindDeidReferral = 'deid_referral';

  /// Generic passthroughs for additional queue families.
  Future<void> put(String kind, String id, Map<String, dynamic> payload) =>
      _persistence.put(kind, id, payload);

  Future<void> remove(String kind, String id) => _persistence.delete(kind, id);

  /// Rehydrates persisted entries of ONE kind at app start.
  Future<List<QueueEntry>> restoreKind(String kind) async {
    final entries = await _persistence.all();
    return entries.where((e) => e.kind == kind).toList();
  }

  static const _dbPasswordKey = 'netra_db_password';

  /// Resolves (or creates) the shared device DB password from secure
  /// storage. Used by BOTH SQLCipher stores (offline queue + screening
  /// store) so every local database is openable across restarts with the
  /// same Keystore-backed key.
  static Future<String> resolveDbPassword() async {
    final storage = const FlutterSecureStorage();
    final existing = await storage.read(key: _dbPasswordKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated =
        DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
        Object().hashCode.toRadixString(36) +
        DateTime.now().toUtc().toIso8601String();
    await storage.write(key: _dbPasswordKey, value: generated);
    return generated;
  }

  /// Opens the durable store. [password] is required for SQLCipher; when
  /// unavailable (tests, desktop platform channels missing) the service
  /// degrades to memory-only with isPersisted=false — the app still works,
  /// it just reports that durability is unavailable.
  static Future<void> init({
    QueuePersistence? persistence,
    String? dbPassword,
  }) async {
    if (persistence != null) {
      _instance = OfflineQueueService._(persistence);
      _instance!.isPersisted = persistence is! MemoryQueuePersistence;
      return;
    }
    try {
      final pw = dbPassword ?? await resolveDbPassword();
      if (pw.isEmpty) throw StateError('no db password');
      final store = await SqliteQueuePersistence.open(pw);
      _instance = OfflineQueueService._(store);
      _instance!.isPersisted = true;
    } catch (_) {
      // Degrade honestly to memory-only.
      _instance = OfflineQueueService._(MemoryQueuePersistence());
      _instance!.isPersisted = false;
    }
  }

  Future<void> addScreening(Map<String, dynamic> payload) async {
    final id = '${payload['local_screening_id'] ?? ''}';
    if (id.isEmpty) return;
    await _persistence.put(kindScreening, id, payload);
  }

  Future<void> addPatient(Map<String, dynamic> payload) async {
    final id = '${payload['patient_id'] ?? ''}';
    if (id.isEmpty) return;
    await _persistence.put(kindPatient, id, payload);
  }

  Future<void> removeScreening(String localScreeningId) =>
      _persistence.delete(kindScreening, localScreeningId);

  Future<void> removePatient(String patientId) =>
      _persistence.delete(kindPatient, patientId);

  Future<void> removeSyncedScreenings(Iterable<String> ids) =>
      _persistence.deleteMany(kindScreening, ids);

  /// Rehydrates persisted entries at app start (main.dart).
  Future<({List<QueueEntry> screenings, List<QueueEntry> patients})>
  restoreAll() async {
    final entries = await _persistence.all();
    return (
      screenings: entries.where((e) => e.kind == kindScreening).toList(),
      patients: entries.where((e) => e.kind == kindPatient).toList(),
    );
  }
}
