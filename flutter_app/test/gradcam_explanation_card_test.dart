import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:drishti/models/screening_models.dart';
import 'package:drishti/widgets/review/gradcam_explanation_card.dart';

ScreeningAnalysisModel analysis({String? gradcamUrl, String? backend}) =>
    ScreeningAnalysisModel(
      screeningId: 'SCR-TEST-1',
      patientId: 'P-TEST-1',
      eyeSide: 'Right',
      cameraProfile: 'Remidio FOP (Smartphone Handheld)',
      qualityGrade: 'A',
      qualityScore: 0.92,
      qualityPassed: true,
      rejectionReasons: const [],
      drGrade: 2,
      drLabel: 'Moderate NPDR',
      predictionScore: 0.87,
      isReferable: true,
      requiresHumanReview: false,
      originalImageUrl: '',
      gradcamOverlayUrl: gradcamUrl,
      gradcamTargetLayer: gradcamUrl == null ? null : 'block_5_conv_3',
      modelBackend: backend ?? 'tflite-fp32',
      actionRecommendation: 'Refer',
      plainLanguageAdvice: 'Refer to an eye doctor.',
      smsReferralSlip:
          'DRISHTI: Moderate NPDR (Grade 2). Refer. Screening:SCR-TEST-1',
    );

Uint8List _png() {
  final image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(200, 60, 60));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  testWidgets('no gradcam URL renders the explicit unavailable state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GradcamExplanationCard(analysis: analysis())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Explanation unavailable'), findsOneWidget);
    expect(find.text('Model attention (Grad-CAM++)'), findsNothing);
  });

  testWidgets('on-device result explains that no attention data exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GradcamExplanationCard(analysis: analysis())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('graded on-device'), findsOneWidget);
  });

  testWidgets('server result without a heatmap states the honesty rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(analysis: analysis(backend: 'keras')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('did not generate'), findsOneWidget);
  });

  testWidgets('failed gradcam fetch renders the unavailable state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(
            analysis: analysis(gradcamUrl: '/results/SCR-TEST-1/g.png'),
            fetcher: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Explanation unavailable'), findsOneWidget);
    expect(find.text('Model attention (Grad-CAM++)'), findsNothing);
  });

  testWidgets('successful gradcam fetch renders the attention overlay card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(
            analysis: analysis(gradcamUrl: '/results/SCR-TEST-1/g.png'),
            fetcher: (_) async => _png(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Model attention (Grad-CAM++)'), findsOneWidget);
    expect(find.text('Layer: block_5_conv_3'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Explanation unavailable'), findsNothing);
  });

  testWidgets('available card carries the advisory-not-diagnosis disclaimer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(
            analysis: analysis(gradcamUrl: '/results/SCR-TEST-1/g.png'),
            fetcher: (_) async => _png(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Advisory'), findsOneWidget);
  });

  testWidgets('in-memory gradcamOverlayBytes renders 100% on-device card with clinical rationale and second opinion prompt', (
    tester,
  ) async {
    final localModel = ScreeningAnalysisModel(
      screeningId: 'LOC-12345678',
      patientId: 'P-TEST-LOCAL',
      eyeSide: 'Left',
      cameraProfile: 'Smartphone Handheld',
      qualityGrade: 'A',
      qualityScore: 0.95,
      qualityPassed: true,
      rejectionReasons: const [],
      drGrade: 2,
      drLabel: 'Moderate NPDR',
      predictionScore: 0.89,
      isReferable: true,
      requiresHumanReview: false,
      originalImageUrl: '',
      gradcamOverlayBytes: _png(),
      gradcamTargetLayer: 'conv_head.saliency_cam',
      aiExplanationSummary: 'Focal microaneurysm clusters detected in superior arcade.',
      secondOpinionPrompt: '### DRISHTI AI Screening — Clinical Second Opinion Case\n- Predicted: Moderate NPDR',
      actionRecommendation: 'Refer',
      plainLanguageAdvice: 'Refer to specialist.',
      smsReferralSlip: 'SMS SLIP',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(analysis: localModel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Model attention (Grad-CAM++)'), findsOneWidget);
    expect(find.text('100% On-Device'), findsOneWidget);
    expect(find.text('Layer: conv_head.saliency_cam'), findsOneWidget);
    expect(find.text('Clinical Saliency Rationale'), findsOneWidget);
    expect(find.textContaining('Focal microaneurysm clusters detected'), findsOneWidget);
    expect(find.textContaining('Secondary AI Consensus'), findsOneWidget);
    expect(find.text('Copy Case for External AI Second Opinion'), findsOneWidget);

    // Tap copy button and verify snackbar appears
    await tester.tap(find.byKey(const ValueKey('copy_second_opinion_prompt')));
    await tester.pump();
    expect(find.textContaining('Clinical case copied!'), findsOneWidget);
  });
}
