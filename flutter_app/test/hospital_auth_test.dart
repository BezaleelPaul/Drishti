import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drishti/screens/auth/hospital_login_screen.dart';
import 'package:drishti/services/hospital_auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HospitalAuthService Unit Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await HospitalAuthService.instance.init();
    });

    test('Initializes with default session or saved preferences', () {
      final auth = HospitalAuthService.instance;
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session, isNotNull);
      expect(auth.activeHospital, isNotEmpty);
    });

    test('Authenticates as Camera Operator / Imaging Tech', () async {
      final auth = HospitalAuthService.instance;
      final success = await auth.login(
        hospital: 'District Hospital Bhor',
        staffName: 'Ramesh Tech',
        staffId: 'TECH-104',
        role: HospitalRole.imagingTech,
      );

      expect(success, isTrue);
      expect(auth.isTech, isTrue);
      expect(auth.isClinician, isFalse);
      expect(auth.session?.hospitalName, 'District Hospital Bhor');
      expect(auth.session?.staffId, 'TECH-104');
    });

    test('Authenticates as Hospital Clinician / Doctor with PIN', () async {
      final auth = HospitalAuthService.instance;
      final success = await auth.login(
        hospital: 'Aravind Eye Hospital',
        staffName: 'Dr. Sharma',
        staffId: 'DOC-88',
        role: HospitalRole.clinician,
        pin: '1234',
      );

      expect(success, isTrue);
      expect(auth.isClinician, isTrue);
      expect(auth.isTech, isFalse);
      expect(auth.session?.staffName, 'Dr. Sharma');
    });

    test('Rejects Doctor login when PIN is incorrect', () async {
      final auth = HospitalAuthService.instance;
      final success = await auth.login(
        hospital: 'Aravind Eye Hospital',
        staffName: 'Dr. Sharma',
        staffId: 'DOC-88',
        role: HospitalRole.clinician,
        pin: '9999',
      );

      expect(success, isFalse);
    });

    test('Quick login sets designated role and facility', () async {
      final auth = HospitalAuthService.instance;
      await auth.quickLogin(HospitalRole.imagingTech);
      expect(auth.isTech, isTrue);
      expect(auth.session?.role, HospitalRole.imagingTech);

      await auth.quickLogin(HospitalRole.clinician);
      expect(auth.isClinician, isTrue);
      expect(auth.session?.role, HospitalRole.clinician);
    });

    test('Logout clears session', () async {
      final auth = HospitalAuthService.instance;
      await auth.logout();
      expect(auth.isLoggedIn, isFalse);
      expect(auth.session, isNull);
    });

    test('Role-based data hiding and masking for Camera Operator vs Clinician Doctor', () async {
      final auth = HospitalAuthService.instance;

      // 1. Tech / Camera Operator role
      await auth.quickLogin(HospitalRole.imagingTech);
      expect(auth.isTech, isTrue);
      expect(auth.isClinician, isFalse);
      expect(auth.canViewClinicalDiagnosis, isFalse);
      expect(auth.canSignAndExportReports, isFalse);
      expect(auth.canDispatchReferrals, isFalse);

      // Verify PII masking
      expect(auth.maskPatientName('Suresh Ramesh Patel'), 'S. Patel');
      expect(auth.maskPatientName('Pooja'), 'P***');
      expect(auth.maskPhone('+91 98765 43210'), contains('•••'));
      expect(auth.maskVillage('Khed Taluka'), 'Sector Protected');

      // Verify diagnosis abstraction
      final techSummary = auth.getDiagnosticSummary(
        drGrade: 3,
        rawLabel: 'Severe NPDR',
        reason: 'Microaneurysms in 4 quadrants',
      );
      expect(techSummary, contains('Capture Verified'));
      expect(techSummary, isNot(contains('Severe NPDR')));

      // 2. Clinician / Doctor role
      await auth.quickLogin(HospitalRole.clinician);
      expect(auth.isClinician, isTrue);
      expect(auth.isTech, isFalse);
      expect(auth.canViewClinicalDiagnosis, isTrue);
      expect(auth.canSignAndExportReports, isTrue);
      expect(auth.canDispatchReferrals, isTrue);

      // Verify unmasked clinical data
      expect(auth.maskPatientName('Suresh Ramesh Patel'), 'Suresh Ramesh Patel');
      expect(auth.maskPhone('+91 98765 43210'), '+91 98765 43210');
      expect(auth.maskVillage('Khed Taluka'), 'Khed Taluka');

      // Verify unmasked diagnosis
      final docSummary = auth.getDiagnosticSummary(
        drGrade: 3,
        rawLabel: 'Severe NPDR',
        reason: 'Microaneurysms in 4 quadrants',
      );
      expect(docSummary, contains('Grade 3: Severe NPDR'));
      expect(docSummary, contains('Microaneurysms in 4 quadrants'));
    });
  });

  group('HospitalLoginScreen Widget Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await HospitalAuthService.instance.logout();
    });

    testWidgets('Renders role selection cards and facility fields', (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: HospitalLoginScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('DRISHTI CLINICAL WORKSPACE'), findsOneWidget);
      expect(find.text('SELECT YOUR HOSPITAL ROLE'), findsOneWidget);
      expect(find.text('Camera Operator'), findsOneWidget);
      expect(find.text('Hospital Doctor'), findsOneWidget);
      expect(find.text('ENTER AS CAMERA OPERATOR'), findsOneWidget);
    });

    testWidgets('Switching role card updates action button and reveals PIN for Doctor', (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: HospitalLoginScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Doctor Card
      await tester.tap(find.text('Hospital Doctor'));
      await tester.pumpAndSettle();

      expect(find.text('ENTER AS HOSPITAL DOCTOR'), findsOneWidget);
      expect(find.text('CLINICIAN SECURITY PIN (DISHA/HIPAA)'), findsOneWidget);

      // Tap Camera Tech Card
      await tester.tap(find.text('Camera Operator'));
      await tester.pumpAndSettle();

      expect(find.text('ENTER AS CAMERA OPERATOR'), findsOneWidget);
      expect(find.text('CLINICIAN SECURITY PIN (DISHA/HIPAA)'), findsNothing);
    });
  });
}
