import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drishti/models/screening_models.dart';
import 'package:drishti/screens/doctor_batch_triage_screen.dart';
import 'package:drishti/screens/flow/flow_state.dart';
import 'package:drishti/services/hospital_auth_service.dart';
import 'package:drishti/services/printer/thermal_slip_service.dart';
import 'package:drishti/services/workplace/darkroom_service.dart';
import 'package:drishti/services/workplace/workplace_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DarkroomService.instance.init();
    await WorkplaceAudioService.instance.init();
    await HospitalAuthService.instance.init();
  });

  group('DarkroomService Unit Tests', () {
    test('Initializes with standard HUD mode by default', () {
      final s = DarkroomService.instance;
      expect(s.mode, equals(DarkroomMode.standard));
      expect(s.isDarkroom, isFalse);
      expect(s.background, equals(const Color(0xFF0B132B)));
      expect(s.accent, equals(const Color(0xFF7DF9FF)));
    });

    test('Switches to Ruby darkroom mode and provides scotopic night colors', () async {
      final s = DarkroomService.instance;
      bool notified = false;
      s.addListener(() => notified = true);

      await s.setMode(DarkroomMode.ruby);

      expect(s.mode, equals(DarkroomMode.ruby));
      expect(s.isDarkroom, isTrue);
      expect(notified, isTrue);
      expect(s.background, equals(const Color(0xFF0D0003)));
      expect(s.accent, equals(const Color(0xFFFF2A4B)));
      expect(s.label, contains('Ruby'));
    });

    test('Switches to Amber darkroom mode with warm anti-constriction spectrum', () async {
      final s = DarkroomService.instance;
      await s.setMode(DarkroomMode.amber);

      expect(s.mode, equals(DarkroomMode.amber));
      expect(s.isDarkroom, isTrue);
      expect(s.background, equals(const Color(0xFF0F0B05)));
      expect(s.accent, equals(const Color(0xFFF59E0B)));
      expect(s.label, contains('Amber'));
    });

    test('Cycles sequentially through modes on toggleNext', () async {
      final s = DarkroomService.instance;
      await s.setMode(DarkroomMode.standard);

      final m1 = await s.toggleNext();
      expect(m1, equals(DarkroomMode.ruby));

      final m2 = await s.toggleNext();
      expect(m2, equals(DarkroomMode.amber));

      final m3 = await s.toggleNext();
      expect(m3, equals(DarkroomMode.standard));
    });
  });

  group('WorkplaceAudioService Unit Tests', () {
    test('Toggles audio enabled state and persists setting', () async {
      final a = WorkplaceAudioService.instance;
      expect(a.enabled, isTrue);

      await a.toggle();
      expect(a.enabled, isFalse);

      await a.setEnabled(true);
      expect(a.enabled, isTrue);
    });

    test('Audio cue triggers execute cleanly without throwing', () async {
      final a = WorkplaceAudioService.instance;
      await expectLater(a.playShutterClick(), completes);
      await expectLater(a.playQcSuccess(), completes);
      await expectLater(a.playQcAlert(), completes);
      await expectLater(a.playEyeAdvance(), completes);
      await expectLater(a.playBatchAction(), completes);
    });
  });

  group('ThermalSlipService Unit Tests', () {
    final sampleSlip = CampSlipData(
      tokenNumber: 'TK-0842',
      patientName: 'Ramesh K.',
      patientId: 'ABHA-9912-3341',
      age: 58,
      gender: 'M',
      screeningDate: DateTime(2026, 11, 19, 14, 30),
      facilityName: 'Drishti Camp Thanjavur PHC',
      operatorName: 'Tech S. Kumar',
      odGradeLabel: 'Normal (No DR)',
      osGradeLabel: 'Mild NPDR',
      referralStatus: 'ROUTINE 1-YEAR FOLLOW-UP',
      followUpDate: 'November 2027',
      qrPayload: 'DRISHTI:TOKEN=TK-0842;OD=0;OS=1',
    );

    test('Generates valid ESC/POS byte sequence with token, findings, and paper cut', () {
      final bytes = ThermalSlipService.instance.generateEscPosBytes(sampleSlip);

      // Must start with ESC @ (initialize)
      expect(bytes[0], equals(0x1B));
      expect(bytes[1], equals(0x40));

      // Must contain Double-width/height command GS ! 0x11
      expect(bytes.contains(0x1D), isTrue);

      // Must contain cut command GS V 0
      final len = bytes.length;
      expect(bytes.sublist(len - 3), equals([0x1D, 0x56, 0x00]));

      // Payload contains camp and patient data
      final str = utf8.decode(bytes, allowMalformed: true);
      expect(str, contains('DRISHTI RETINA CAMP'));
      expect(str, contains('TK-0842'));
      expect(str, contains('Ramesh K.'));
      expect(str, contains('OD (Right Eye): Normal (No DR)'));
      expect(str, contains('OS (Left Eye) : Mild NPDR'));
    });

    test('Generates monospace ASCII preview slip', () {
      final text = ThermalSlipService.instance.generateAsciiSlip(sampleSlip);
      expect(text, contains('DRISHTI RETINA CAMP'));
      expect(text, contains('TOKEN NUMBER'));
      expect(text, contains('TK-0842'));
      expect(text, contains('Ramesh K.'));
      expect(text, contains('OD (Right): Normal (No DR)'));
      expect(text, contains('OS (Left) : Mild NPDR'));
      expect(text, contains('ROUTINE 1-YEAR FOLLOW-UP'));
    });
  });

  group('FlowState Dual-Eye Pipeline Tests', () {
    test('Preserves OD and OS captures across sequential screening', () {
      final patient = PatientModel(
        patientId: 'TK-1001',
        abhaId: 'ABHA-1001',
        name: 'Kamala S.',
        age: 62,
        gender: 'Female',
        phone: '9840112233',
        village: 'Alanganallur',
        knownDiabetes: 'Type 2',
      );

      final state = FlowState(
        patient: patient,
        eyeSide: 'Right',
        filename: 'od_scan.jpg',
      );

      // Screen Right Eye (OD)
      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-1',
        patientId: 'TK-1001',
        eyeSide: 'Right',
        cameraProfile: 'Standard',
        qualityGrade: 'GOOD',
        qualityScore: 0.95,
        qualityPassed: true,
        rejectionReasons: [],
        drGrade: 0,
        predictionScore: 0.96,
        isReferable: false,
        requiresHumanReview: false,
        originalImageUrl: '',
        actionRecommendation: 'Annual Recall',
        plainLanguageAdvice: 'Healthy retina',
        smsReferralSlip: '',
      );
      state.saveCurrentEye();

      expect(state.odAnalysis, isNotNull);
      expect(state.odAnalysis!.drGrade, equals(0));
      expect(state.osAnalysis, isNull);
      expect(state.hasBothEyesCaptured, isFalse);

      // Switch to Left Eye (OS)
      state.switchToOtherEye();
      expect(state.eyeSide, equals('Left'));

      // Screen Left Eye (OS)
      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-2',
        patientId: 'TK-1001',
        eyeSide: 'Left',
        cameraProfile: 'Standard',
        qualityGrade: 'GOOD',
        qualityScore: 0.92,
        qualityPassed: true,
        rejectionReasons: [],
        drGrade: 1,
        predictionScore: 0.91,
        isReferable: false,
        requiresHumanReview: true,
        originalImageUrl: '',
        actionRecommendation: '6-Mo Recall',
        plainLanguageAdvice: 'Mild changes',
        smsReferralSlip: '',
      );
      state.saveCurrentEye();

      expect(state.osAnalysis, isNotNull);
      expect(state.osAnalysis!.drGrade, equals(1));
      expect(state.hasBothEyesCaptured, isTrue);
    });
  });

  group('HospitalAuthService Clinical Abstraction Tests', () {
    test('Masks patient ABHA and identifier for non-clinician operators', () async {
      final auth = HospitalAuthService.instance;
      await auth.quickLogin(HospitalRole.imagingTech);

      expect(auth.isTech, isTrue);
      expect(auth.isClinician, isFalse);

      final masked = auth.maskPatientId('ABHA-9821-4412');
      expect(masked, isNot(equals('ABHA-9821-4412')));
      expect(masked, contains('•••'));
      expect(masked.startsWith('ABH'), isTrue);
      expect(masked.endsWith('12'), isTrue);
    });

    test('Reveals full patient identifier for authenticated Clinician', () async {
      final auth = HospitalAuthService.instance;
      await auth.quickLogin(HospitalRole.clinician);

      expect(auth.isClinician, isTrue);
      final raw = auth.maskPatientId('ABHA-9821-4412');
      expect(raw, equals('ABHA-9821-4412'));
    });
  });

  group('DoctorBatchTriageScreen Widget Tests', () {
    testWidgets('Renders batch triage deck header and rapid 1-key buttons', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));

      await tester.pumpWidget(
        MaterialApp(
          home: DoctorBatchTriageScreen(
            initialQueue: [
              {
                'local_screening_id': 'SCR-CAMP-101',
                'local_patient_id': 'ABHA-7721-9901',
                'name': 'Kavitha M.',
                'age': 52,
                'gender': 'Female',
                'eye_side': 'OD (Right)',
                'dr_grade_num': 0,
                'confidence': 0.96,
                'requires_human_review': 1,
                'human_review_reason': 'Routine tele-ophthalmology verification',
                'image_path': '',
              },
            ],
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('HIGH-VELOCITY BATCH TRIAGE DECK'), findsOneWidget);
      expect(find.text('Normal / No DR'), findsWidgets);
      expect(find.text('Mild NPDR Confirmed'), findsWidgets);
      expect(find.text('URGENT VR REFERRAL'), findsWidgets);
      expect(find.textContaining('KEYBOARD SPRINT:'), findsOneWidget);
    });
  });
}
