import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drishti/models/screening_models.dart';
import 'package:drishti/services/smtp/smtp_service.dart';
import 'package:drishti/screens/flow/flow_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SmtpService & SmtpConfig Tests', () {
    test('Default config has sensible defaults', () {
      final config = SmtpConfig();
      expect(config.smtpHost, 'smtp.gmail.com');
      expect(config.smtpPort, 465);
      expect(config.useSsl, isTrue);
      expect(config.autoSendOnDr, isTrue);
      expect(config.minSeverityGrade, 1);
      expect(config.isConfigured, isFalse);
    });

    test('isConfigured is true only when all essential fields are present', () {
      final config = SmtpConfig(
        senderEmail: 'clinic@drishti.ai',
        senderPassword: 'app-password-1234',
        smtpHost: 'smtp.gmail.com',
        specialistEmail: 'specialist@hospital.org',
      );
      expect(config.isConfigured, isTrue);
    });

    test('loadConfig and saveConfig persist to SharedPreferences', () async {
      final service = SmtpService();
      final config = SmtpConfig(
        senderEmail: 'dr.sharma@health.gov.in',
        senderPassword: 'secretpassword',
        smtpHost: 'smtp.office365.com',
        smtpPort: 587,
        useSsl: false,
        specialistEmail: 'retina.specialist@aiims.edu',
        senderName: 'District Clinic A',
        autoSendOnDr: true,
        minSeverityGrade: 2,
      );

      await service.saveConfig(config);
      final loaded = await service.loadConfig();

      expect(loaded.senderEmail, 'dr.sharma@health.gov.in');
      expect(loaded.smtpHost, 'smtp.office365.com');
      expect(loaded.smtpPort, 587);
      expect(loaded.useSsl, isFalse);
      expect(loaded.specialistEmail, 'retina.specialist@aiims.edu');
      expect(loaded.senderName, 'District Clinic A');
      expect(loaded.minSeverityGrade, 2);
    });

    test('handleScreeningCompleted skips when DR grade is below threshold', () async {
      final service = SmtpService();
      await service.saveConfig(SmtpConfig(
        senderEmail: 'test@example.com',
        senderPassword: 'test',
        smtpHost: 'smtp.example.com',
        specialistEmail: 'specialist@example.com',
        autoSendOnDr: true,
        minSeverityGrade: 2,
      ));

      final patient = PatientModel(
        patientId: 'PT-101',
        name: 'Ramesh Kumar',
        age: 52,
        gender: 'Male',
        phone: '9876543210',
        abhaId: 'ABHA-1234',
        village: 'Rampur',
        knownDiabetes: 'Yes',
      );
      final state = FlowState(patient: patient);
      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-001',
        patientId: 'PT-101',
        eyeSide: 'Right',
        cameraProfile: 'Standard',
        qualityGrade: 'GOOD',
        qualityScore: 0.98,
        qualityPassed: true,
        rejectionReasons: const [],
        drGrade: 1, // Below threshold 2
        drLabel: 'Mild Non-Proliferative DR',
        predictionScore: 0.88,
        isReferable: false,
        requiresHumanReview: true,
        originalImageUrl: 'local',
        actionRecommendation: 'Repeat screening in 6 months',
        plainLanguageAdvice: 'Consult physician',
        smsReferralSlip: 'SMS SLIP',
      );

      final res = await service.handleScreeningCompleted(state);
      expect(res, isNotNull);
      expect(res.success, isFalse);
      expect(res.message, contains('below notification threshold'));
    });

    test('handleScreeningCompleted skips when autoSendOnDr is false', () async {
      final service = SmtpService();
      await service.saveConfig(SmtpConfig(
        senderEmail: 'test@example.com',
        senderPassword: 'test',
        smtpHost: 'smtp.example.com',
        specialistEmail: 'specialist@example.com',
        autoSendOnDr: false,
        minSeverityGrade: 1,
      ));

      final patient = PatientModel(
        patientId: 'PT-102',
        name: 'Sita Devi',
        age: 60,
        gender: 'Female',
        phone: '9876543211',
        abhaId: 'ABHA-5678',
        village: 'Kalyanpur',
        knownDiabetes: 'Yes',
      );
      final state = FlowState(patient: patient);
      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-002',
        patientId: 'PT-102',
        eyeSide: 'Left',
        cameraProfile: 'Standard',
        qualityGrade: 'GOOD',
        qualityScore: 0.95,
        qualityPassed: true,
        rejectionReasons: const [],
        drGrade: 2,
        drLabel: 'Moderate NPDR',
        predictionScore: 0.92,
        isReferable: true,
        requiresHumanReview: true,
        originalImageUrl: 'local',
        actionRecommendation: 'Referral to specialist',
        plainLanguageAdvice: 'Consult specialist',
        smsReferralSlip: 'SMS SLIP',
      );

      final res = await service.handleScreeningCompleted(state);
      expect(res.success, isFalse);
      expect(res.message, contains('Automated specialist dispatch disabled'));
    });

    test('handleScreeningCompleted warns if SMTP is not configured', () async {
      final service = SmtpService();
      await service.saveConfig(SmtpConfig(
        senderEmail: '', // Not configured
        senderPassword: '',
        specialistEmail: '',
        autoSendOnDr: true,
        minSeverityGrade: 1,
      ));

      final patient = PatientModel(
        patientId: 'PT-103',
        name: 'Amit Patel',
        age: 45,
        gender: 'Male',
        phone: '9876543212',
        abhaId: 'ABHA-9012',
        village: 'Navsari',
        knownDiabetes: 'Yes',
      );
      final state = FlowState(patient: patient);
      state.analysis = ScreeningAnalysisModel(
        screeningId: 'SCR-003',
        patientId: 'PT-103',
        eyeSide: 'Right',
        cameraProfile: 'Standard',
        qualityGrade: 'GOOD',
        qualityScore: 0.99,
        qualityPassed: true,
        rejectionReasons: const [],
        drGrade: 3,
        drLabel: 'Severe NPDR',
        predictionScore: 0.96,
        isReferable: true,
        requiresHumanReview: true,
        originalImageUrl: 'local',
        actionRecommendation: 'Urgent referral',
        plainLanguageAdvice: 'Urgent care',
        smsReferralSlip: 'SMS SLIP',
      );

      final res = await service.handleScreeningCompleted(state);
      expect(res.success, isFalse);
      expect(res.message, contains('not configured'));
    });

    test('sendTestEmail validates missing credentials and recipients', () async {
      final service = SmtpService();
      await service.saveConfig(SmtpConfig(senderEmail: '', senderPassword: ''));

      var res = await service.sendTestEmail(testRecipient: '');
      expect(res.success, isFalse);
      expect(res.message, contains('must be filled before testing'));

      await service.saveConfig(SmtpConfig(
        senderEmail: 'clinic@drishti.org',
        senderPassword: 'password123',
        specialistEmail: '',
      ));
      res = await service.sendTestEmail(testRecipient: '');
      expect(res.success, isFalse);
      expect(res.message, contains('valid recipient email address'));
    });
  });
}
