import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

    test('generateReportPdf embeds explicit gradcamOverlayBytes', () async {
      final img.Image testImage = img.Image(width: 32, height: 32);
      img.fill(testImage, color: img.ColorRgb8(200, 50, 50));
      final testPng = Uint8List.fromList(img.encodePng(testImage));

      final patient = PatientModel(
        patientId: 'PT-1001',
        name: 'Sunita Devi',
        age: 52,
        gender: 'Female',
        phone: '9845012345',
        abhaId: 'ABHA-1234',
        village: 'Ramanagara PHC',
        knownDiabetes: 'Yes',
      );

      final state = FlowState(patient: patient);
      state.imageBytes = testPng;
      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-HEATMAP-TEST',
        patientId: 'PT-1001',
        eyeSide: 'Left',
        cameraProfile: 'Forus 3nethra classic',
        qualityGrade: 'GOOD',
        qualityScore: 0.98,
        qualityPassed: true,
        rejectionReasons: const [],
        drGrade: 3,
        drLabel: 'Severe Non-Proliferative DR',
        predictionScore: 0.965,
        isReferable: true,
        requiresHumanReview: true,
        originalImageUrl: 'local',
        gradcamOverlayBytes: testPng,
        actionRecommendation: 'Urgent specialist ophthalmology consultation required within 48-72 hours.',
        plainLanguageAdvice: 'Extensive microvascular anomalies identified.',
        smsReferralSlip: 'SMS SLIP',
      );

      final pdfBytes = await ClinicalPdfGenerator.generateReportPdf(state);
      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(2000));
      expect(String.fromCharCodes(pdfBytes.take(5)), '%PDF-');
    });

    test('generateReportPdf synthesizes heatmap on-device when gradcamOverlayBytes is null', () async {
      final img.Image testImage = img.Image(width: 32, height: 32);
      img.fill(testImage, color: img.ColorRgb8(180, 40, 40));
      final testPng = Uint8List.fromList(img.encodePng(testImage));

      final patient = PatientModel(
        patientId: 'PT-1002',
        name: 'Rajesh Kumar',
        age: 60,
        gender: 'Male',
        phone: '9845099999',
        abhaId: 'ABHA-5678',
        village: 'Mandya PHC',
        knownDiabetes: 'Yes',
      );

      final state = FlowState(patient: patient);
      state.imageBytes = testPng;
      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-AUTO-HEATMAP',
        patientId: 'PT-1002',
        eyeSide: 'Right',
        cameraProfile: 'Remidio FOP (Smartphone Handheld)',
        qualityGrade: 'GOOD',
        qualityScore: 0.92,
        qualityPassed: true,
        rejectionReasons: const [],
        drGrade: 2,
        drLabel: 'Moderate Non-Proliferative DR',
        predictionScore: 0.89,
        isReferable: true,
        requiresHumanReview: true,
        originalImageUrl: 'local',
        gradcamOverlayBytes: null,
        actionRecommendation: 'Referral to secondary eye hospital within 2-4 weeks.',
        plainLanguageAdvice: 'Microaneurysms detected in macula.',
        smsReferralSlip: 'SMS SLIP',
      );

      final pdfBytes = await ClinicalPdfGenerator.generateReportPdf(state);
      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(2000));
      expect(String.fromCharCodes(pdfBytes.take(5)), '%PDF-');
    });
  });
}
