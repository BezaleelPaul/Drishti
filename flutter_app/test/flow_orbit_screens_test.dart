import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:netra_ai_mobile/models/screening_models.dart';
import 'package:netra_ai_mobile/screens/flow/flow_analysis_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_result_screen.dart';
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

  // Standard 1x1 transparent PNG for Image.memory / Flame decoding.
  Uint8List png1x1() => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  ScreeningAnalysisModel analysis({
    int? drGrade = 2,
    String? drLabel = 'Moderate NPDR',
    String? backend = 'tflite-fp32',
    bool offline = false,
    String? errorCode,
    List<String> rejectionReasons = const [],
    bool qualityPassed = true,
    String qualityGrade = 'A',
    bool? isReferable = true,
    double? predictionScore = 0.87,
  }) => ScreeningAnalysisModel(
    screeningId: 'SCR-TEST-1',
    patientId: 'P-TEST-1',
    eyeSide: 'Right',
    cameraProfile: 'Remidio FOP (Smartphone Handheld)',
    qualityGrade: qualityGrade,
    qualityScore: 0.92,
    qualityPassed: qualityPassed,
    rejectionReasons: rejectionReasons,
    drGrade: drGrade,
    drLabel: drLabel,
    predictionScore: predictionScore,
    isReferable: isReferable,
    requiresHumanReview: false,
    originalImageUrl: '',
    modelBackend: backend,
    actionRecommendation: 'Refer to PHC',
    plainLanguageAdvice: 'Please visit the PHC.',
    smsReferralSlip: '',
    isOffline: offline,
    errorCode: errorCode,
  );

  group('FlowAnalysisScreen orbit integration', () {
    testWidgets(
      'failure state renders honest error card, never a backend label',
      (tester) async {
        final state = FlowState(patient: patient()); // imageBytes stays null

        await tester.pumpWidget(
          MaterialApp(home: FlowAnalysisScreen(state: state)),
        );
        await tester.pump();

        expect(find.byType(OrbitScanner), findsOneWidget);
        expect(find.byType(WorkflowBar), findsOneWidget);
        expect(find.text('ANALYSIS FAILED'), findsOneWidget);
        expect(find.textContaining('Analysis unavailable'), findsOneWidget);
        expect(find.byKey(const Key('orbit_cancel')), findsOneWidget);
        // No result exists: the verified-backend chip must not appear.
        expect(find.textContaining('BACKEND'), findsNothing);
        // Never an unearned confirmation.
        expect(find.text('SERVICE CONFIRMED'), findsNothing);

        // Let the 700ms periodic step timer run its course and self-cancel
        // on the error path (5 steps + cancel tick = >4200ms).
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }

        expect(find.byType(FlowAnalysisScreen), findsOneWidget);
        expect(find.text('ANALYSIS FAILED'), findsOneWidget);
      },
    );

    testWidgets('orbit cancel control pops the analysis route', (tester) async {
      final state = FlowState(patient: patient());

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open_analysis'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FlowAnalysisScreen(state: state),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open_analysis')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(FlowAnalysisScreen), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('orbit_cancel')));
      await tester.tap(find.byKey(const Key('orbit_cancel')));
      // Settle the pop transition; the step timer self-cancels on the error
      // path, so this terminates.
      await tester.pumpAndSettle();

      expect(find.byType(FlowAnalysisScreen), findsNothing);
    });
  });

  group('FlowResultScreen honest rendering', () {
    testWidgets('graded result: preliminary chip, on-device provenance, '
        'explicit unavailable explanation, no confirmed/synthetic labels', (
      tester,
    ) async {
      final state = FlowState(
        patient: patient(),
        imageBytes: png1x1(),
        analysis: analysis(),
      );

      await tester.pumpWidget(
        MaterialApp(home: FlowResultScreen(state: state)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(FlowResultScreen), findsOneWidget);
      // Dark orbit palette applied.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, ScannerHUDTheme.background);

      // Preliminary status chip, never a confirmed one.
      expect(find.text('PRELIMINARY'), findsOneWidget);
      expect(find.text('SERVICE CONFIRMED'), findsNothing);

      // Provenance: backend identity line uses the real modelBackend.
      expect(find.textContaining('on-device'), findsWidgets);
      expect(find.textContaining('AI Detected'), findsWidgets);

      // R1: synthetic heatmap gone; explicit unavailable state instead.
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Explanation unavailable'), findsOneWidget);
      expect(
        find.text('Model attention — not clinical evidence'),
        findsNothing,
      );
      expect(find.text('RESULT VERIFIED'), findsNothing);

      // Real fundus view remains, honestly labeled.
      expect(find.byType(ScannerView), findsOneWidget);
      expect(find.text('ORIGINAL FUNDUS'), findsOneWidget);
      expect(find.text('Original Fundus Image'), findsOneWidget);

      // No offline chip for an online result.
      expect(find.text('OFFLINE — PENDING SYNC'), findsNothing);
    });

    testWidgets(
      'rejected image: shows rejection reasons and assigns no grade chip',
      (tester) async {
        final state = FlowState(
          patient: patient(),
          analysis: analysis(
            drGrade: null,
            drLabel: null,
            backend: null,
            qualityPassed: false,
            qualityGrade: 'C',
            errorCode: 'IMG_UNGRADABLE',
            rejectionReasons: ['Image too blurry', 'Field of view < 40%'],
            isReferable: null,
            predictionScore: null,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(home: FlowResultScreen(state: state)),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.textContaining('Rejected — no DR grade assigned'),
          findsOneWidget,
        );
        expect(find.textContaining('Image too blurry'), findsOneWidget);
        expect(find.textContaining('Field of view < 40%'), findsOneWidget);

        // No grade means no preliminary "result" chip and no AI Detected line.
        expect(find.text('PRELIMINARY'), findsNothing);
        expect(find.textContaining('AI Detected'), findsNothing);
        expect(find.text('SERVICE CONFIRMED'), findsNothing);

        // Honest explanation state even for rejected images.
        expect(find.text('Explanation unavailable'), findsOneWidget);
      },
    );

    testWidgets('offline queued result shows the offline chip', (tester) async {
      final state = FlowState(
        patient: patient(),
        analysis: analysis(
          drGrade: null,
          drLabel: null,
          backend: null,
          qualityGrade: 'PENDING_SYNC',
          offline: true,
          isReferable: null,
          predictionScore: null,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: FlowResultScreen(state: state)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('OFFLINE — PENDING SYNC'), findsOneWidget);
      expect(find.text('PRELIMINARY'), findsNothing);
      expect(find.text('SERVICE CONFIRMED'), findsNothing);
    });

    testWidgets('proceed button navigates to the specialist review screen', (
      tester,
    ) async {
      final state = FlowState(patient: patient(), analysis: analysis());

      await tester.pumpWidget(
        MaterialApp(home: FlowResultScreen(state: state)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final proceed = find.text('Proceed to Specialist Review →');
      await tester.ensureVisible(proceed);
      await tester.tap(proceed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(FlowSpecialistScreen), findsOneWidget);
      // Note: the previous route stays mounted under the pushed route
      // (standard Navigator behavior), so only the new screen is asserted.
    });
  });
}
