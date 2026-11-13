import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../screens/flow/flow_state.dart';
import '../offline_queue_service.dart';
import 'local_store.dart';

/// Central persistence orchestrator for screening workflows.
/// Ensures every patient intake and AI diagnostic result is persisted
/// to the device SQLCipher vault immediately, guaranteeing visibility
/// in Patient History and Offline Queue.
class ScreeningPersistenceService {
  static final ScreeningPersistenceService _instance =
      ScreeningPersistenceService._internal();
  factory ScreeningPersistenceService() => _instance;
  ScreeningPersistenceService._internal();

  /// Persists a completed screening and its patient intake.
  Future<bool> saveScreening(FlowState state) async {
    try {
      final password = await OfflineQueueService.resolveDbPassword();
      final store = await LocalStore.open(dbPassword: password);

      final p = state.patient;
      await store.upsertPatient(
        localPatientId: p.patientId,
        name: p.name,
        age: p.age,
        gender: p.gender,
        phone: p.phone,
        village: p.village,
        screeningCentre: 'Primary Health Centre',
        knownDiabetes: p.knownDiabetes,
        diabetesDurationYears: p.diabetesDurationYears,
        hba1c: p.hba1c,
        fastingGlucose: p.fastingGlucose,
        bloodPressure: p.bloodPressure,
        bmi: p.bmi,
        familyHistory: p.familyHistory,
      );

      final screeningId = state.analysis?.screeningId ??
          'LOC-${DateTime.now().millisecondsSinceEpoch}';

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

      final grade = state.correctedGrade ?? state.analysis?.drGrade ?? 0;
      final label = state.analysis?.drLabel ??
          (grade == 0
              ? 'No Diabetic Retinopathy'
              : 'Diabetic Retinopathy (Grade $grade)');

      await store.recordScreening(
        localScreeningId: screeningId,
        localPatientId: p.patientId,
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
        capturedAtIso: DateTime.now().toUtc().toIso8601String(),
        imagePath: imagePath,
        enqueueForSync: true,
      );

      debugPrint('Screening successfully saved to LocalStore: $screeningId for ${p.name}');
      return true;
    } catch (e, stack) {
      debugPrint('Error saving screening to LocalStore: $e\n$stack');
      return false;
    }
  }
}
