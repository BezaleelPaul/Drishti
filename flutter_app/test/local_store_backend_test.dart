import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:drishti/services/db/database_backend.dart';
import 'package:drishti/services/db/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The SQLCipher plugin is unavailable in the host test runner. The desktop
  // FFI backend is the cross-platform path this release adds, so exercise it
  // directly on Linux/Windows CI hosts.
  final canRun = !DatabaseBackend.supportsEncryption;

  test(
    'LocalStore persists and reopens screenings through the desktop backend',
    () async {
      final temp = await Directory.systemTemp.createTemp('drishti_local_store');
      final dbPath = p.join(temp.path, 'drishti_test.db');

      final store = await LocalStore.openForTest(dbPath, 'test-key');
      await store.upsertPatient(
        localPatientId: 'PT-XPLAT-1',
        name: 'Cross Platform Patient',
        age: 55,
        gender: 'Female',
        village: 'Test Village',
        knownDiabetes: 'Yes',
      );
      await store.recordScreening(
        localScreeningId: 'SCR-XPLAT-1',
        localPatientId: 'PT-XPLAT-1',
        eyeSide: 'Right',
        cameraProfile: 'Test Camera',
        qualityGrade: 'GOOD',
        recaptureAttemptCount: 0,
        drGradeNum: 2,
        drLabel: 'Moderate NPDR',
        confidence: 0.93,
        requiresHumanReview: true,
        capturedAtIso: DateTime.now().toUtc().toIso8601String(),
        imagePath: '',
      );
      await store.close();

      final reopened = await LocalStore.openForTest(dbPath, 'test-key');
      final rows = await reopened.recentScreenings();
      expect(rows, hasLength(1));
      expect(rows.first['local_patient_id'], 'PT-XPLAT-1');
      expect(rows.first['name'], 'Cross Platform Patient');
      expect(rows.first['dr_grade_num'], 2);
      await reopened.close();

      await temp.delete(recursive: true);
    },
    skip: canRun ? false : 'Desktop FFI backend is only exercised on Windows/Linux',
  );
}
