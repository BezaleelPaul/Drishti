import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Encrypted local store (Ticket B-1). All PHI lives here and NEVER leaves
/// the device without the consent flow (docs/PRIVACY.md contract).
///
/// Kill/restart invariants (tested by integration_test/offline_restart_test):
///   1. screening INSERT + sync_queue enqueue happen in ONE transaction;
///   2. a screening may only transition to acked after its receipt row
///      exists (receipt-before-delete);
///   3. in-flight queue rows are re-derived from persisted state at boot.
class LocalStore {
  LocalStore._(this._db);

  static const int _schemaVersion = 1;
  static const String _dbName = 'netra_ai.db';

  final Database _db;
  static LocalStore? _instance;

  static Future<LocalStore> open({required String dbPassword}) async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    final db = await openDatabase(
      path,
      password: dbPassword,
      version: _schemaVersion,
      onConfigure: (d) async {
        await d.execute('PRAGMA journal_mode=WAL');
        await d.execute('PRAGMA foreign_keys=ON');
        await d.execute('PRAGMA busy_timeout=30000');
        await d.execute('PRAGMA synchronous=NORMAL');
      },
      onCreate: _createSchema,
      onUpgrade: _migrate,
    );
    _instance = LocalStore._(db);
    return _instance!;
  }

  /// Test seam: open against an explicit path (in-memory for widget tests).
  static Future<LocalStore> openForTest(String path, String dbPassword) async {
    final db = await openDatabase(
      path,
      password: dbPassword,
      version: _schemaVersion,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: _createSchema,
      onUpgrade: _migrate,
    );
    return LocalStore._(db);
  }

  Future<void> close() async {
    await _db.close();
    _instance = null;
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE device_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE patients (
        local_patient_id TEXT PRIMARY KEY,
        pseudonym TEXT NOT NULL,
        name TEXT NOT NULL,
        age INTEGER,
        gender TEXT,
        phone TEXT,
        village TEXT,
        screening_centre TEXT,
        known_diabetes TEXT DEFAULT 'Unknown',
        diabetes_duration_years REAL,
        hba1c REAL,
        fasting_glucose REAL,
        blood_pressure TEXT,
        bmi REAL,
        family_history INTEGER DEFAULT 0,
        physical_activity TEXT DEFAULT 'Moderate',
        symptoms_json TEXT DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at_seq INTEGER NOT NULL,
        sync_eligibility TEXT NOT NULL DEFAULT 'never'
      )
    ''');
    await db.execute('''
      CREATE TABLE screenings (
        local_screening_id TEXT PRIMARY KEY,
        local_patient_id TEXT NOT NULL REFERENCES patients(local_patient_id),
        eye_side TEXT NOT NULL CHECK (eye_side IN ('Right','Left')),
        camera_profile TEXT NOT NULL,
        quality_grade TEXT NOT NULL CHECK (quality_grade IN ('GOOD','BORDERLINE','BAD')),
        quality_status TEXT,
        rejection_reasons TEXT,
        error_code TEXT,
        recapture_attempt_count INTEGER NOT NULL DEFAULT 0,
        reassessment_outcome TEXT,
        dr_grade_num INTEGER CHECK (dr_grade_num IS NULL OR dr_grade_num BETWEEN 0 AND 4),
        dr_label TEXT,
        prob_vector TEXT,
        confidence REAL,
        top2_margin REAL,
        requires_human_review INTEGER NOT NULL DEFAULT 0,
        human_review_type TEXT,
        human_review_reason TEXT,
        model_backend TEXT NOT NULL DEFAULT 'tflite-fp32',
        model_sha256 TEXT,
        inference_time_ms REAL,
        quality_metrics_json TEXT,
        created_at TEXT NOT NULL,
        captured_at TEXT NOT NULL,
        image_path TEXT NOT NULL,
        updated_at_seq INTEGER NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'local_only'
          CHECK (sync_state IN ('local_only','queued','syncing','sync_failed',
                                'acked','review_received'))
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_queue (
        queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_screening_id TEXT NOT NULL UNIQUE REFERENCES screenings(local_screening_id),
        state TEXT NOT NULL CHECK (state IN ('PENDING','IN_FLIGHT','RETRY_WAIT',
                                             'DEAD_LETTER','RECEIPT_PENDING')),
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_receipts (
        local_screening_id TEXT PRIMARY KEY,
        server_screening_id TEXT NOT NULL,
        acked_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE consent_records (
        consent_id TEXT PRIMARY KEY,
        local_patient_id TEXT NOT NULL REFERENCES patients(local_patient_id),
        consent_version TEXT NOT NULL,
        language TEXT,
        granted_at TEXT NOT NULL,
        withdrawn_at TEXT,
        evidence_hash TEXT,
        sync_allowed INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE audit_log_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor TEXT,
        action TEXT NOT NULL,
        resource TEXT,
        detail TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_screenings_patient ON screenings(local_patient_id, created_at)',
    );
    await db.execute(
      'CREATE INDEX idx_screenings_sync ON screenings(sync_state, updated_at_seq)',
    );
    await db.execute(
      'CREATE INDEX idx_queue_next ON sync_queue(next_attempt_at, state)',
    );
  }

  static Future<void> _migrate(Database db, int oldV, int newV) async {
    // Idempotent column-add migration pattern, mirroring api/database.py.
    // v1 is the first shipped schema; future columns append here.
  }

  // ------------------------------------------------------------------
  // Screenings
  // ------------------------------------------------------------------

  /// Atomically records a completed screening and enqueues it (invariant 1).
  Future<void> recordScreening({
    required String localScreeningId,
    required String localPatientId,
    required String eyeSide,
    required String cameraProfile,
    required String qualityGrade,
    String? qualityStatus,
    List<String>? rejectionReasons,
    String? errorCode,
    required int recaptureAttemptCount,
    String? reassessmentOutcome,
    int? drGradeNum,
    String? drLabel,
    List<double>? probabilities,
    double? confidence,
    double? top2Margin,
    required bool requiresHumanReview,
    String? humanReviewType,
    String? humanReviewReason,
    String modelBackend = 'tflite-fp32',
    String? modelSha256,
    double? inferenceTimeMs,
    String? qualityMetricsJson,
    required String capturedAtIso,
    required String imagePath,
    bool enqueueForSync = false,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await txn.insert('screenings', {
        'local_screening_id': localScreeningId,
        'local_patient_id': localPatientId,
        'eye_side': eyeSide,
        'camera_profile': cameraProfile,
        'quality_grade': qualityGrade,
        'quality_status': qualityStatus,
        'rejection_reasons': rejectionReasons?.join(' | '),
        'error_code': errorCode,
        'recapture_attempt_count': recaptureAttemptCount,
        'reassessment_outcome': reassessmentOutcome,
        'dr_grade_num': drGradeNum,
        'dr_label': drLabel,
        'prob_vector': probabilities?.join(','),
        'confidence': confidence,
        'top2_margin': top2Margin,
        'requires_human_review': requiresHumanReview ? 1 : 0,
        'human_review_type': humanReviewType,
        'human_review_reason': humanReviewReason,
        'model_backend': modelBackend,
        'model_sha256': modelSha256,
        'inference_time_ms': inferenceTimeMs,
        'quality_metrics_json': qualityMetricsJson,
        'created_at': now,
        'captured_at': capturedAtIso,
        'image_path': imagePath,
        'updated_at_seq': DateTime.now().microsecondsSinceEpoch,
        'sync_state': enqueueForSync ? 'queued' : 'local_only',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (enqueueForSync) {
        await txn.insert('sync_queue', {
          'local_screening_id': localScreeningId,
          'state': 'PENDING',
          'attempts': 0,
          'created_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await txn.insert('audit_log_local', {
        'action': 'screening_recorded',
        'resource': localScreeningId,
        'detail': 'grade=${drGradeNum ?? "none"} review=$requiresHumanReview',
        'created_at': now,
      });
    });
  }

  Future<List<Map<String, Object?>>> pendingSyncBatch({int limit = 3}) async {
    return _db.query(
      'sync_queue',
      where: "state IN ('PENDING','RETRY_WAIT')",
      orderBy: 'queue_id',
      limit: limit,
    );
  }

  Future<void> markQueueState(
    String localScreeningId,
    String state, {
    String? lastError,
  }) async {
    await _db.update(
      'sync_queue',
      {
        'state': state,
        'last_error': lastError,
        'next_attempt_at': state == 'RETRY_WAIT'
            ? DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 2))
                  .toIso8601String()
            : null,
      },
      where: 'local_screening_id = ?',
      whereArgs: [localScreeningId],
    );
  }

  /// Receipt-before-delete (invariant 2): the receipt row is written first;
  /// only afterwards does the caller delete the local image asset and flip
  /// sync_state to acked.
  Future<void> recordReceipt(
    String localScreeningId,
    String serverScreeningId,
  ) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await txn.insert('sync_receipts', {
        'local_screening_id': localScreeningId,
        'server_screening_id': serverScreeningId,
        'acked_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        'screenings',
        {
          'sync_state': 'acked',
          'updated_at_seq': DateTime.now().microsecondsSinceEpoch,
        },
        where: 'local_screening_id = ?',
        whereArgs: [localScreeningId],
      );
      await txn.delete(
        'sync_queue',
        where: 'local_screening_id = ?',
        whereArgs: [localScreeningId],
      );
      await txn.insert('audit_log_local', {
        'action': 'sync_acked',
        'resource': localScreeningId,
        'detail': serverScreeningId,
        'created_at': now,
      });
    });
  }

  /// Deletes the local image asset for an acked screening (image never
  /// leaves the device; after ACK it is no longer needed locally).
  Future<void> deleteImageAfterAck(String localScreeningId) async {
    final rows = await _db.query(
      'screenings',
      columns: ['image_path'],
      where: 'local_screening_id = ? AND sync_state = ?',
      whereArgs: [localScreeningId, 'acked'],
    );
    for (final row in rows) {
      final path = row['image_path'] as String?;
      if (path != null) {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      }
    }
  }

  Future<List<Map<String, Object?>>> screeningsForPatient(
    String localPatientId,
  ) async {
    return _db.query(
      'screenings',
      where: 'local_patient_id = ?',
      whereArgs: [localPatientId],
      orderBy: 'created_at DESC',
    );
  }

  /// Most recent screenings across ALL patients (offline dashboard / history
  /// feed). Joins the patient row so the UI shows the truthful patient name
  /// stored on this device — never a fabricated default.
  Future<List<Map<String, Object?>>> recentScreenings({int limit = 6}) async {
    return _db.rawQuery(
      '''
      SELECT s.local_screening_id AS local_screening_id,
             s.local_patient_id AS local_patient_id,
             p.name AS name,
             p.village AS village,
             s.dr_grade_num AS dr_grade_num,
             s.dr_label AS dr_label,
             s.error_code AS error_code,
             s.requires_human_review AS requires_human_review,
             s.quality_grade AS quality_grade,
             s.sync_state AS sync_state,
             s.created_at AS created_at,
             s.eye_side AS eye_side
      FROM screenings s
      JOIN patients p ON p.local_patient_id = s.local_patient_id
      ORDER BY s.created_at DESC
      LIMIT ?
    ''',
      [limit],
    );
  }

  Future<Map<String, Object?>?> getMeta(String key) async {
    final rows = await _db.query(
      'device_meta',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> setMeta(String key, String value) async {
    await _db.insert('device_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// On-device retention purge (Ticket C-5, mirrors api/retention.py).
  ///
  /// Deletes ACKED screenings (data the server has confirmed) older than
  /// [retentionDays], together with their image files. UNSYNCED data is
  /// NEVER purged — that would break the field-camp zero-data-loss
  /// guarantee. Patients and consent records are never deleted here
  /// (erasure goes through the consent-withdrawal flow instead).
  Future<int> purgeExpiredData({int retentionDays = 90}) async {
    if (retentionDays <= 0) return 0;
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: retentionDays))
        .toIso8601String();
    final now = DateTime.now().toUtc().toIso8601String();

    // Collect victims first (files are deleted after the row deletion).
    final rows = await _db.query(
      'screenings',
      columns: ['local_screening_id', 'image_path'],
      where: "sync_state = 'acked' AND created_at < ?",
      whereArgs: [cutoff],
    );
    if (rows.isEmpty) return 0;
    final ids = rows.map((r) => '${r['local_screening_id']}').toList();
    final paths = rows
        .map((r) => r['image_path'] as String?)
        .whereType<String>()
        .toList();

    await _db.transaction((txn) async {
      final q = List.filled(ids.length, '?').join(',');
      await txn.delete(
        'screenings',
        where: 'local_screening_id IN ($q)',
        whereArgs: ids,
      );
      await txn.insert('audit_log_local', {
        'action': 'retention_purge',
        'resource': 'screenings',
        'detail': 'count=${ids.length} window_days=$retentionDays',
        'created_at': now,
      });
    });

    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      } on FileSystemException {
        // Best-effort file cleanup; the DB row (the PHI record) is gone.
      }
    }
    return ids.length;
  }
}
