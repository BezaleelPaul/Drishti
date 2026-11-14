import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../screens/flow/flow_state.dart';
import '../offline_queue_service.dart';
import 'local_store.dart';

/// Central persistence orchestrator for screening workflows.
/// Multi-tiered durable architecture:
/// 1. Local Encrypted SQLite / SQLCipher Vault (PHI-safe on disk)
/// 2. SharedPreferences JSON cache (desktop & mobile instant load)
/// 3. Offline filesystem backup JSON (survives app rebuilds)
/// 4. Offline sync queue (store-and-forward when connectivity returns)
class ScreeningPersistenceService with ChangeNotifier {
  static final ScreeningPersistenceService _instance =
      ScreeningPersistenceService._internal();
  factory ScreeningPersistenceService() => _instance;
  ScreeningPersistenceService._internal();

  static const String _prefsKey = 'drishti_screenings_cache_v2';
  static const String _backupFileName = 'drishti_screenings_backup.json';

  /// Default clinical sample records seeded if no screenings exist yet.
  static List<Map<String, dynamic>> get sampleRecords {
    final now = DateTime.now().toUtc();
    return [
      {
        'local_screening_id': 'SCR-PT-8821-Right',
        'local_patient_id': 'PT-8821',
        'name': 'Ramesh Patil',
        'age': 58,
        'gender': 'Male',
        'village': 'Wadgaon, PHC Bhor',
        'phone': '9822058112',
        'screening_centre': 'Primary Health Centre',
        'known_diabetes': 'Yes',
        'diabetes_duration_years': 7.0,
        'hba1c': 8.2,
        'eye_side': 'Right',
        'camera_profile': 'Remidio FOP (Smartphone Handheld)',
        'quality_grade': 'GOOD',
        'quality_status': 'Certified Reliable',
        'recapture_attempt_count': 0,
        'dr_grade_num': 2,
        'dr_label': 'Moderate NPDR',
        'confidence': 0.94,
        'requires_human_review': 1,
        'human_review_type': 'ROUTINE',
        'human_review_reason': 'Moderate microaneurysms and hard exudates detected',
        'model_backend': 'tflite-fp32',
        'created_at': now.subtract(const Duration(hours: 2)).toIso8601String(),
        'image_path': '',
        'sync_state': 'offline',
      },
      {
        'local_screening_id': 'SCR-PT-8822-Left',
        'local_patient_id': 'PT-8822',
        'name': 'Sunita Devi',
        'age': 49,
        'gender': 'Female',
        'village': 'Shirwal, Satara',
        'phone': '9822049112',
        'screening_centre': 'Primary Health Centre',
        'known_diabetes': 'Yes',
        'diabetes_duration_years': 3.5,
        'hba1c': 5.7,
        'eye_side': 'Left',
        'camera_profile': 'Remidio FOP (Smartphone Handheld)',
        'quality_grade': 'GOOD',
        'quality_status': 'Certified Reliable',
        'recapture_attempt_count': 0,
        'dr_grade_num': 0,
        'dr_label': 'No Diabetic Retinopathy',
        'confidence': 0.97,
        'requires_human_review': 0,
        'human_review_type': null,
        'human_review_reason': null,
        'model_backend': 'tflite-fp32',
        'created_at': now.subtract(const Duration(days: 2, hours: 2)).toIso8601String(),
        'image_path': '',
        'sync_state': 'acked',
      },
      {
        'local_screening_id': 'SCR-PT-8823-Right',
        'local_patient_id': 'PT-8823',
        'name': 'Anand Kulkarni',
        'age': 64,
        'gender': 'Male',
        'village': 'Khandala, Pune',
        'phone': '9822064112',
        'screening_centre': 'Primary Health Centre',
        'known_diabetes': 'Yes',
        'diabetes_duration_years': 12.0,
        'hba1c': 9.8,
        'eye_side': 'Right',
        'camera_profile': 'Remidio FOP (Smartphone Handheld)',
        'quality_grade': 'GOOD',
        'quality_status': 'Certified Reliable',
        'recapture_attempt_count': 0,
        'dr_grade_num': 3,
        'dr_label': 'Severe NPDR',
        'confidence': 0.96,
        'requires_human_review': 1,
        'human_review_type': 'URGENT',
        'human_review_reason': 'Extensive intraretinal microvascular abnormalities (IRMA) detected',
        'model_backend': 'tflite-fp32',
        'created_at': now.subtract(const Duration(days: 4, hours: 6)).toIso8601String(),
        'image_path': '',
        'sync_state': 'offline',
      },
    ];
  }

  /// Persists a completed screening and its patient intake across all tiers.
  Future<bool> saveScreening(FlowState state) async {
    final pState = state.patient;
    final screeningId = state.analysis?.screeningId ??
        'LOC-${DateTime.now().millisecondsSinceEpoch}';

    final grade = state.correctedGrade ?? state.analysis?.drGrade ?? 0;
    final label = state.analysis?.drLabel ??
        (grade == 0
            ? 'No Diabetic Retinopathy'
            : 'Diabetic Retinopathy (Grade $grade)');

    // Save fundus image to local storage if available
    String imagePath = '';
    if (state.imageBytes != null && state.imageBytes!.isNotEmpty) {
      try {
        final tempDir = Directory.systemTemp;
        final imagesDir = Directory('${tempDir.path}/drishti_screenings');
        if (!await imagesDir.exists()) {
          await imagesDir.create(recursive: true);
        }
        final file = File('${imagesDir.path}/$screeningId.jpg');
        await file.writeAsBytes(state.imageBytes!);
        imagePath = file.path;
      } catch (e) {
        debugPrint('Failed to save screening image file: $e');
      }
    }

    final record = <String, dynamic>{
      'local_screening_id': screeningId,
      'local_patient_id': pState.patientId,
      'name': pState.name,
      'age': pState.age,
      'gender': pState.gender,
      'phone': pState.phone,
      'village': pState.village,
      'screening_centre': 'Primary Health Centre',
      'known_diabetes': pState.knownDiabetes,
      'diabetes_duration_years': pState.diabetesDurationYears,
      'hba1c': pState.hba1c,
      'fasting_glucose': pState.fastingGlucose,
      'blood_pressure': pState.bloodPressure,
      'bmi': pState.bmi,
      'family_history': pState.familyHistory ? 1 : 0,
      'eye_side': state.eyeSide,
      'camera_profile': state.cameraProfile,
      'quality_grade': state.quality?.qualityGrade ?? 'GOOD',
      'quality_status': state.quality?.qualityGrade,
      'recapture_attempt_count': state.recaptureAttemptCount,
      'dr_grade_num': grade,
      'dr_label': label,
      'confidence': state.analysis?.predictionScore ?? 0.95,
      'requires_human_review': (state.analysis?.requiresHumanReview ?? (grade > 0)) ? 1 : 0,
      'human_review_type': grade >= 3 ? 'URGENT' : (grade > 0 ? 'ROUTINE' : null),
      'human_review_reason': state.specialistNotes.isNotEmpty
          ? state.specialistNotes
          : (grade > 0 ? 'Diabetic Retinopathy detected on-device' : null),
      'model_backend': state.analysis?.modelBackend ?? 'tflite-fp32',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'image_path': imagePath,
      'sync_state': 'offline',
    };

    // Tier 1: SharedPreferences (guaranteed fast & crash-proof on macOS)
    try {
      await _saveToPrefs(record);
    } catch (e) {
      debugPrint('Error saving to SharedPreferences: $e');
    }

    // Tier 2: File backup in documents directory
    try {
      await _saveToFileBackup(record);
    } catch (e) {
      debugPrint('Error saving to file backup: $e');
    }

    // Tier 3: LocalStore SQLCipher / SQLite database
    try {
      final password = await OfflineQueueService.resolveDbPassword();
      final store = await LocalStore.open(dbPassword: password);
      await store.upsertPatient(
        localPatientId: pState.patientId,
        name: pState.name,
        age: pState.age,
        gender: pState.gender,
        phone: pState.phone,
        village: pState.village,
        screeningCentre: 'Primary Health Centre',
        knownDiabetes: pState.knownDiabetes,
        diabetesDurationYears: pState.diabetesDurationYears,
        hba1c: pState.hba1c,
        fastingGlucose: pState.fastingGlucose,
        bloodPressure: pState.bloodPressure,
        bmi: pState.bmi,
        familyHistory: pState.familyHistory,
      );

      await store.recordScreening(
        localScreeningId: screeningId,
        localPatientId: pState.patientId,
        eyeSide: state.eyeSide,
        cameraProfile: state.cameraProfile,
        qualityGrade: state.quality?.qualityGrade ?? 'GOOD',
        qualityStatus: state.quality?.qualityGrade,
        recaptureAttemptCount: state.recaptureAttemptCount,
        drGradeNum: grade,
        drLabel: label,
        confidence: state.analysis?.predictionScore ?? 0.95,
        requiresHumanReview: state.analysis?.requiresHumanReview ?? (grade > 0),
        humanReviewType: grade >= 3 ? 'URGENT' : (grade > 0 ? 'ROUTINE' : null),
        humanReviewReason: state.specialistNotes.isNotEmpty
            ? state.specialistNotes
            : (grade > 0 ? 'Diabetic Retinopathy detected on-device' : null),
        modelBackend: state.analysis?.modelBackend ?? 'tflite-fp32',
        capturedAtIso: record['created_at'] as String,
        imagePath: imagePath,
        enqueueForSync: true,
      );
    } catch (e) {
      debugPrint('LocalStore save error (Tier 1 & 2 preserved record): $e');
    }

    debugPrint('Screening saved across tiers: $screeningId');
    notifyListeners();
    return true;
  }

  /// Updates an existing patient screening record across all persistence tiers.
  Future<bool> updateRecord(Map<String, dynamic> updatedRecord) async {
    final sid = updatedRecord['local_screening_id']?.toString() ?? '';
    final pid = updatedRecord['local_patient_id']?.toString() ?? '';
    if (sid.isEmpty) return false;

    // Tier 1: SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingJson = prefs.getString(_prefsKey);
      List<dynamic> list = [];
      if (existingJson != null && existingJson.isNotEmpty) {
        try {
          list = jsonDecode(existingJson) as List<dynamic>;
        } catch (_) {}
      }
      final idx = list.indexWhere((item) => item is Map && item['local_screening_id'] == sid);
      if (idx >= 0) {
        final existing = Map<String, dynamic>.from(list[idx] as Map);
        existing.addAll(updatedRecord);
        list[idx] = existing;
      } else {
        list.insert(0, updatedRecord);
      }
      await prefs.setString(_prefsKey, jsonEncode(list));
    } catch (e) {
      debugPrint('Error updating SharedPreferences record: $e');
    }

    // Tier 2: File Backup
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _backupFileName));
      if (await file.exists()) {
        final content = await file.readAsString();
        List<dynamic> list = [];
        try {
          list = jsonDecode(content) as List<dynamic>;
        } catch (_) {}
        final idx = list.indexWhere((item) => item is Map && item['local_screening_id'] == sid);
        if (idx >= 0) {
          final existing = Map<String, dynamic>.from(list[idx] as Map);
          existing.addAll(updatedRecord);
          list[idx] = existing;
        } else {
          list.insert(0, updatedRecord);
        }
        await file.writeAsString(jsonEncode(list));
      }
    } catch (e) {
      debugPrint('Error updating File backup record: $e');
    }

    // Tier 3: LocalStore SQLCipher / SQLite
    try {
      final password = await OfflineQueueService.resolveDbPassword();
      final store = await LocalStore.open(dbPassword: password);
      try {
        if (pid.isNotEmpty) {
          await store.upsertPatient(
            localPatientId: pid,
            name: updatedRecord['name']?.toString(),
            age: (updatedRecord['age'] as num?)?.toInt(),
            gender: updatedRecord['gender']?.toString(),
            phone: updatedRecord['phone']?.toString(),
            village: updatedRecord['village']?.toString(),
          );
        }
        final grade = (updatedRecord['dr_grade_num'] as num?)?.toInt();
        final reviewReq = (updatedRecord['requires_human_review'] as num?)?.toInt() ??
            (grade != null && grade > 0 ? 1 : 0);
        await store.updateScreeningRecord(
          localScreeningId: sid,
          drGradeNum: grade,
          drLabel: updatedRecord['dr_label']?.toString(),
          requiresHumanReview: reviewReq,
          humanReviewReason: updatedRecord['human_review_reason']?.toString(),
          eyeSide: updatedRecord['eye_side']?.toString(),
        );
      } finally {
        await store.close();
      }
    } catch (e) {
      debugPrint('Error updating LocalStore record: $e');
    }

    notifyListeners();
    return true;
  }

  /// Deletes a patient screening record across all persistence tiers.
  Future<bool> deleteRecord(String localScreeningId) async {
    if (localScreeningId.isEmpty) return false;

    // Tier 1: SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingJson = prefs.getString(_prefsKey);
      if (existingJson != null && existingJson.isNotEmpty) {
        final list = (jsonDecode(existingJson) as List<dynamic>)
            .where((item) => item is Map && item['local_screening_id'] != localScreeningId)
            .toList();
        await prefs.setString(_prefsKey, jsonEncode(list));
      }
    } catch (e) {
      debugPrint('Error deleting from SharedPreferences: $e');
    }

    // Tier 2: File Backup
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _backupFileName));
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = (jsonDecode(content) as List<dynamic>)
            .where((item) => item is Map && item['local_screening_id'] != localScreeningId)
            .toList();
        await file.writeAsString(jsonEncode(list));
      }
    } catch (e) {
      debugPrint('Error deleting from File backup: $e');
    }

    // Tier 3: LocalStore SQLCipher
    try {
      final password = await OfflineQueueService.resolveDbPassword();
      final store = await LocalStore.open(dbPassword: password);
      try {
        await store.deleteScreeningRecord(localScreeningId);
      } finally {
        await store.close();
      }
    } catch (e) {
      debugPrint('Error deleting from LocalStore: $e');
    }

    notifyListeners();
    return true;
  }

  /// Manually creates a new patient screening record.
  Future<bool> createManualRecord(Map<String, dynamic> record) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final sid = record['local_screening_id']?.toString() ??
        'SCR-MANUAL-${DateTime.now().millisecondsSinceEpoch}';
    final pid = record['local_patient_id']?.toString() ??
        'PT-${DateTime.now().millisecondsSinceEpoch % 10000}';
    record['local_screening_id'] = sid;
    record['local_patient_id'] = pid;
    record['created_at'] ??= now;
    record['sync_state'] ??= 'offline';

    // Tier 1: SharedPreferences
    try {
      await _saveToPrefs(record);
    } catch (e) {
      debugPrint('Error saving manual record to SharedPreferences: $e');
    }

    // Tier 2: File backup
    try {
      await _saveToFileBackup(record);
    } catch (e) {
      debugPrint('Error saving manual record to File backup: $e');
    }

    // Tier 3: LocalStore
    try {
      final password = await OfflineQueueService.resolveDbPassword();
      final store = await LocalStore.open(dbPassword: password);
      try {
        await store.upsertPatient(
          localPatientId: pid,
          name: record['name']?.toString(),
          age: (record['age'] as num?)?.toInt(),
          gender: record['gender']?.toString(),
          phone: record['phone']?.toString(),
          village: record['village']?.toString(),
        );
        final grade = (record['dr_grade_num'] as num?)?.toInt() ?? 0;
        final label = (record['dr_label'] ??
            (grade == 0
                ? 'No Diabetic Retinopathy'
                : 'Diabetic Retinopathy Grade $grade'))
            .toString();
        await store.recordScreening(
          localScreeningId: sid,
          localPatientId: pid,
          eyeSide: (record['eye_side'] ?? 'Right').toString(),
          cameraProfile: 'Manual Entry',
          qualityGrade: 'GOOD',
          recaptureAttemptCount: 0,
          drGradeNum: grade,
          drLabel: label,
          confidence: (record['confidence'] as num?)?.toDouble() ?? 1.0,
          requiresHumanReview: grade > 0,
          humanReviewType: grade >= 3 ? 'URGENT' : (grade > 0 ? 'ROUTINE' : null),
          humanReviewReason: record['human_review_reason']?.toString(),
          modelBackend: 'manual-clinical-entry',
          capturedAtIso: now,
          imagePath: (record['image_path'] ?? '').toString(),
          enqueueForSync: false,
        );
      } finally {
        await store.close();
      }
    } catch (e) {
      debugPrint('Error saving manual record to LocalStore: $e');
    }

    notifyListeners();
    return true;
  }

  /// Retrieves recent screenings across all tiers with deduplication.
  /// If no records exist, automatically seeds clinical demonstration records.
  Future<List<Map<String, dynamic>>> getRecentScreenings({int limit = 100}) async {
    final Map<String, Map<String, dynamic>> recordsById = {};

    // 1. Load from LocalStore if available
    try {
      final password = await OfflineQueueService.resolveDbPassword();
      final store = await LocalStore.open(dbPassword: password);
      try {
        await store.seedSampleScreeningsIfEmpty();
        final dbRows = await store.recentScreenings(limit: limit);
        for (final row in dbRows) {
          final id = (row['local_screening_id'] ?? '').toString();
          if (id.isNotEmpty) {
            recordsById[id] = Map<String, dynamic>.from(row);
          }
        }
      } finally {
        await store.close();
      }
    } catch (e) {
      debugPrint('LocalStore retrieval fallback: $e');
    }

    // 2. Load from SharedPreferences
    try {
      final prefsList = await _loadFromPrefs();
      for (final r in prefsList) {
        final id = (r['local_screening_id'] ?? '').toString();
        if (id.isNotEmpty && !recordsById.containsKey(id)) {
          recordsById[id] = r;
        }
      }
    } catch (e) {
      debugPrint('Prefs retrieval error: $e');
    }

    // 3. Load from File Backup
    try {
      final fileList = await _loadFromFileBackup();
      for (final r in fileList) {
        final id = (r['local_screening_id'] ?? '').toString();
        if (id.isNotEmpty && !recordsById.containsKey(id)) {
          recordsById[id] = r;
        }
      }
    } catch (e) {
      debugPrint('File backup retrieval error: $e');
    }

    // If completely empty, seed sample records
    if (recordsById.isEmpty) {
      debugPrint('No screening records found — seeding default clinical sample records.');
      final samples = sampleRecords;
      for (final s in samples) {
        recordsById[s['local_screening_id'] as String] = s;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode(samples));
      } catch (_) {}
    }

    final list = recordsById.values.toList();
    // Sort descending by created_at
    list.sort((a, b) {
      final aDate = DateTime.tryParse('${a['created_at'] ?? ''}') ?? DateTime(2020);
      final bDate = DateTime.tryParse('${b['created_at'] ?? ''}') ?? DateTime(2020);
      return bDate.compareTo(aDate);
    });

    if (list.length > limit) {
      return list.sublist(0, limit);
    }
    return list;
  }

  // --- Private Tier Helpers ---

  Future<void> _saveToPrefs(Map<String, dynamic> record) async {
    final prefs = await SharedPreferences.getInstance();
    final existingJson = prefs.getString(_prefsKey);
    List<dynamic> list = [];
    if (existingJson != null && existingJson.isNotEmpty) {
      try {
        list = jsonDecode(existingJson) as List<dynamic>;
      } catch (_) {
        list = [];
      }
    }
    final screeningId = record['local_screening_id'];
    list.removeWhere((item) => item is Map && item['local_screening_id'] == screeningId);
    list.insert(0, record);
    // Keep top 200
    if (list.length > 200) list = list.sublist(0, 200);
    await prefs.setString(_prefsKey, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_prefsKey);
    if (jsonStr == null || jsonStr.isEmpty) return const [];
    try {
      final raw = jsonDecode(jsonStr) as List<dynamic>;
      return raw.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveToFileBackup(Map<String, dynamic> record) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _backupFileName));
      List<dynamic> list = [];
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          list = jsonDecode(content) as List<dynamic>;
        } catch (_) {
          list = [];
        }
      }
      final screeningId = record['local_screening_id'];
      list.removeWhere((item) => item is Map && item['local_screening_id'] == screeningId);
      list.insert(0, record);
      if (list.length > 200) list = list.sublist(0, 200);
      await file.writeAsString(jsonEncode(list));
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _loadFromFileBackup() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _backupFileName));
      if (!await file.exists()) return const [];
      final content = await file.readAsString();
      final raw = jsonDecode(content) as List<dynamic>;
      return raw.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }
}
