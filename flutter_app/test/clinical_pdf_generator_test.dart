import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:drishti/models/screening_models.dart';
import 'package:drishti/screens/flow/flow_state.dart';
import 'package:drishti/services/pdf/clinical_pdf_generator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClinicalPdfGenerator Tests', () {
    test('generateReportPdf creates valid PDF bytes with header and metadata', () async {
      final patient = PatientModel(
        patientId: 'PT-9988',
        name: 'Aarav Sharma',
        age: 46,
        gender: 'Male',
        phone: '9876543210',
        abhaId: 'ABHA-9988-7766',
        village: 'Kolar PHC',
        knownDiabetes: 'Yes',
        diabetesDurationYears: 7,
        hba1c: 8.4,
        fastingGlucose: 168.0,
        bloodPressure: '135/85',
        bmi: 26.2,
      );

      final state = FlowState(patient: patient);
      state.eyeSide = 'Right';
      state.cameraProfile = 'Remidio FOP (Smartphone Handheld)';
      state.specialistNotes = 'Confirmed Grade 2 Moderate NPDR. Laser photocoagulation review recommended.';
      // 1x1 dummy jpeg byte sequence
      state.imageBytes = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
        0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
        0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
        0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
        0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
        0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
        0x00, 0x7B, 0x40, 0xFF, 0xD9,
      ]);

      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-2026-TEST',
        patientId: 'PT-9988',
        eyeSide: 'Right',
        cameraProfile: 'Remidio FOP (Smartphone Handheld)',
        qualityGrade: 'GOOD',
        qualityScore: 0.96,
        qualityPassed: true,
        rejectionReasons: const [],
        drGrade: 2,
        drLabel: 'Moderate Non-Proliferative DR',
        predictionScore: 0.942,
        isReferable: true,
        requiresHumanReview: true,
        originalImageUrl: 'local',
        actionRecommendation: 'Referral to secondary eye hospital within 2-4 weeks.',
        plainLanguageAdvice: 'Retinal microvascular pathology detected consistent with Grade 2 DR.',
        smsReferralSlip: 'SMS SLIP',
      );

      final pdfBytes = await ClinicalPdfGenerator.generateReportPdf(state);
      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(1000));

      // PDF Magic Header Check (%PDF-)
      final header = String.fromCharCodes(pdfBytes.take(5));
      expect(header, '%PDF-');
    });
  });
}
