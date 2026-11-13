import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:netra_ai_mobile/models/screening_models.dart';
import 'package:netra_ai_mobile/screens/flow/flow_capture_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_referral_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_register_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_report_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_specialist_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_state.dart';
import 'package:netra_ai_mobile/widgets/orbit/orbit.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner.dart';
import 'package:netra_ai_mobile/widgets/workflow_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues(const {});
  });

  PatientModel patient() => PatientModel(
    patientId: 'P-TEST-1',
    name: 'Test Patient',
    age: 54,
    gender: 'Female',
    phone: '9999999999',
    abhaId: '',
    village: 'Test Village',
    knownDiabetes: 'No',
  );

  // Standard 1x1 transparent PNG for Image.memory.
  Uint8List png1x1() => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  ScreeningAnalysisModel analysis({
    int? drGrade = 2,
    String? drLabel = 'Moderate NPDR',
    String? backend = 'tflite-fp32',
  }) => ScreeningAnalysisModel(
    screeningId: 'SCR-TEST-1',
    patientId: 'P-TEST-1',
    eyeSide: 'Right',
    cameraProfile: 'Remidio FOP (Smartphone Handheld)',
    qualityGrade: 'A',
    qualityScore: 0.92,
    qualityPassed: true,
    rejectionReasons: const [],
    drGrade: drGrade,
    drLabel: drLabel,
    predictionScore: 0.87,
    isReferable: true,
    requiresHumanReview: false,
    originalImageUrl: '',
    modelBackend: backend,
    actionRecommendation: 'Refer to PHC',
    plainLanguageAdvice: 'Please visit the PHC.',
    smsReferralSlip: '',
    isOffline: false,
    errorCode: null,
  );

  void expectDarkChrome(WidgetTester tester) {
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, ScannerHUDTheme.background);
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, ScannerHUDTheme.darkSurface);
    expect(find.byType(WorkflowBar), findsOneWidget);
  }

  group('dark orbit restyle', () {
    testWidgets('register renders dark chrome and blocks an empty submit', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: FlowRegisterScreen()));
      await tester.pump();

      expectDarkChrome(tester);
      expect(find.text('Patient Registration'), findsOneWidget);
      expect(find.text('BASIC INFORMATION'), findsOneWidget);
      expect(find.byType(TextFormField), findsWidgets);

      final submit = find.text('Continue to Eye Screening →');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();

      // Validation fails on empty required fields — no navigation.
      expect(find.byType(FlowCaptureScreen), findsNothing);
    });

    testWidgets(
      'capture swaps the viewfinder to the orbit scanner, dark chrome',
      (tester) async {
        final state = FlowState(patient: patient(), imageBytes: png1x1());

        await tester.pumpWidget(
          MaterialApp(home: FlowCaptureScreen(state: state)),
        );
        await tester.pump();

        expect(find.byType(OrbitScanner), findsOneWidget);
        expect(find.byType(ScannerView), findsNothing);
        expectDarkChrome(tester);
        expect(find.text('Select Eye'), findsOneWidget);

        // Asset load + on-device quality gate are pure Dart — no network.
        // The gate now decodes + assesses on a background isolate (compute);
        // real async does not advance under FakeAsync, so poll for the
        // observable quality result under runAsync, then settle frames.
        await tester.runAsync(() async {
          final end = DateTime.now().add(const Duration(seconds: 10));
          while (DateTime.now().isBefore(end) && state.quality == null) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
        await tester.pumpAndSettle();

        expect(find.byType(OrbitScanner), findsOneWidget);
        expect(find.text('Image Quality Check'), findsOneWidget);
        // Honest viewfinder states only; capture never claims a result.
        expect(find.text('RESULT VERIFIED'), findsNothing);
        expect(find.text('SERVICE CONFIRMED'), findsNothing);
        expect(find.text('INFERENCE RUNNING'), findsNothing);
      },
    );

    testWidgets(
      'specialist decision cards are dark; CHANGE reveals the grade override',
      (tester) async {
        final state = FlowState(patient: patient(), analysis: analysis());

        await tester.pumpWidget(
          MaterialApp(home: FlowSpecialistScreen(state: state)),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expectDarkChrome(tester);
        expect(find.text('Specialist Decision'), findsOneWidget);
        expect(find.text('AI Screening Result'), findsOneWidget);
        expect(find.text('Confirm AI Result'), findsOneWidget);
        expect(find.byType(DropdownButtonFormField<int>), findsNothing);

        final change = find.text('Change Severity');
        await tester.ensureVisible(change);
        await tester.tap(change);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);

        final confirm = find.text('Confirm AI Result');
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      },
    );

    testWidgets(
      'referral renders urgency honestly and continues to the report',
      (tester) async {
        final state = FlowState(patient: patient(), analysis: analysis());

        await tester.pumpWidget(
          MaterialApp(home: FlowReferralScreen(state: state)),
        );
        await tester.pumpAndSettle();

        expectDarkChrome(tester);
        expect(find.text('Referral Required'), findsOneWidget);
        // Grade 2 -> routine 4-week pathway (clinical policy).
        expect(find.textContaining('Routine — within 4 weeks'), findsOneWidget);
        expect(find.text('SERVICE CONFIRMED'), findsNothing);

        final next = find.text('Continue to Final Report →');
        await tester.ensureVisible(next);
        await tester.tap(next);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byType(FlowReportScreen), findsOneWidget);
      },
    );

    testWidgets(
      'report shows the real result — and no grade when none exists',
      (tester) async {
        final graded = FlowState(patient: patient(), analysis: analysis());
        await tester.pumpWidget(
          MaterialApp(home: FlowReportScreen(state: graded)),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expectDarkChrome(tester);
        expect(find.text('DRISHTI Screening Report'), findsOneWidget);
        expect(
          find.text('Demo Report — Not a clinical document'),
          findsOneWidget,
        );
        expect(find.textContaining('Moderate NPDR'), findsOneWidget);
        expect(find.text('SERVICE CONFIRMED'), findsNothing);

        // Ungraded: the AI result row shows the honest awaiting state,
        // never a fabricated label.
        final ungraded = FlowState(patient: patient());
        await tester.pumpWidget(
          MaterialApp(home: FlowReportScreen(state: ungraded)),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('Awaiting specialist verification'), findsOneWidget);
        expect(find.textContaining('Moderate NPDR'), findsNothing);
        expect(find.text('SERVICE CONFIRMED'), findsNothing);
      },
    );
  });
}
